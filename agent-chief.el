;;; agent-chief.el --- Chief-of-staff loop for AI agents -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/agent
;; Version: 0.1
;; Package-Requires: ((emacs "30.0") (agent "0.1"))

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A small, inspectable chief-of-staff loop.  Emacs owns schedule,
;; context, state, and notifications; Claude Code or Codex only
;; evaluates whether to contact the user on each tick.

;;; Code:

(require 'agent)
(require 'cl-lib)
(require 'json)
(require 'subr-x)

(declare-function agent-claude--run-prompt "agent-claude" (prompt &rest kwargs))
(declare-function agent-codex--run-prompt "agent-codex" (prompt &rest kwargs))
(declare-function alert "alert")

;;;; Customization

(defgroup agent-chief ()
  "Chief-of-staff loop powered by Claude Code or Codex."
  :group 'agent)

(defcustom agent-chief-backend 'codex
  "Backend used by `agent-chief-tick'."
  :type '(choice (const :tag "Codex" codex)
                 (const :tag "Claude Code" claude-code))
  :group 'agent-chief)

(defcustom agent-chief-interval 1800
  "Number of seconds between chief-of-staff ticks."
  :type 'integer
  :group 'agent-chief)

(defcustom agent-chief-directory user-emacs-directory
  "Working directory used for non-interactive agent runs."
  :type 'directory
  :group 'agent-chief)

(defcustom agent-chief-state-file
  (expand-file-name "agent-chief/state.org"
                    (or (getenv "XDG_STATE_HOME")
                        (expand-file-name ".local/state" "~")))
  "Org file where the chief-of-staff loop stores auditable state."
  :type 'file
  :group 'agent-chief)

(defcustom agent-chief-context-functions nil
  "Functions that return context strings for `agent-chief-tick'.
Each function is called with no arguments.  Nil and empty strings
are ignored.  Functions should be deterministic and should not
perform externally visible actions."
  :type 'hook
  :group 'agent-chief)

(defcustom agent-chief-state-max-chars 12000
  "Maximum number of state-file characters included in each tick."
  :type 'integer
  :group 'agent-chief)

(defcustom agent-chief-max-turns 3
  "Maximum Claude turns used by `agent-chief-tick'."
  :type 'integer
  :group 'agent-chief)

(defcustom agent-chief-notify-function #'agent-chief-notify
  "Function called with TITLE and MESSAGE when the chief contacts you."
  :type 'function
  :group 'agent-chief)

(defcustom agent-chief-system-prompt
  (concat
   "You are Pablo's chief-of-staff agent. Your job is to decide whether "
   "to contact him now based only on the supplied auditable context. Be "
   "selective: contact him only when a timely nudge would help him stay "
   "on track, avoid missing a commitment, or recover from drift. Never "
   "invent obligations. Never claim to have checked a source that was not "
   "included in the prompt. Return exactly one JSON object and no prose.")
  "Standing instruction prepended to each chief-of-staff tick."
  :type 'string
  :group 'agent-chief)

(defvar agent-chief--timer nil
  "Timer object for the active chief-of-staff loop.")

(defvar agent-chief--running nil
  "Non-nil while a chief-of-staff tick is in progress.")

(defvar agent-chief--last-result nil
  "Last raw result plist returned by the selected backend.")

(defvar agent-chief--last-decision nil
  "Last parsed decision plist returned by the model.")

;;;; Commands

;;;###autoload
(defun agent-chief-start (&optional no-immediate)
  "Start the chief-of-staff loop.
With prefix argument NO-IMMEDIATE, wait `agent-chief-interval'
seconds before the first tick."
  (interactive "P")
  (when (timerp agent-chief--timer)
    (cancel-timer agent-chief--timer))
  (setq agent-chief--timer
        (run-at-time (if no-immediate agent-chief-interval 0)
                     agent-chief-interval
                     #'agent-chief-tick))
  (message "Agent chief started; interval %ss" agent-chief-interval))

;;;###autoload
(defun agent-chief-stop ()
  "Stop the chief-of-staff loop."
  (interactive)
  (when (timerp agent-chief--timer)
    (cancel-timer agent-chief--timer))
  (setq agent-chief--timer nil)
  (message "Agent chief stopped"))

;;;###autoload
(defun agent-chief-tick ()
  "Run one chief-of-staff check."
  (interactive)
  (if agent-chief--running
      (message "Agent chief tick skipped; previous tick still running")
    (setq agent-chief--running t)
    (agent-chief--run-backend
     (agent-chief--build-prompt)
     (lambda (result)
       (setq agent-chief--running nil)
       (agent-chief--handle-result result)))))

;;;###autoload
(defun agent-chief-open-state ()
  "Open `agent-chief-state-file'."
  (interactive)
  (find-file agent-chief-state-file))

;;;###autoload
(defun agent-chief-add-note (note)
  "Append NOTE to `agent-chief-state-file'."
  (interactive "sChief note: ")
  (agent-chief--append-state-heading "Manual note" note)
  (message "Agent chief note saved"))

;;;###autoload
(defun agent-chief-set-day-plan (plan)
  "Append today's PLAN to `agent-chief-state-file'."
  (interactive "sPlan for today: ")
  (agent-chief--append-state-heading
   (format "Plan %s" (format-time-string "%Y-%m-%d"))
   plan)
  (message "Agent chief day plan saved"))

;;;; Prompt construction

(defun agent-chief--build-prompt ()
  "Build the prompt for one chief-of-staff tick."
  (string-join
   (delq nil
         (list agent-chief-system-prompt
               (agent-chief--response-contract)
               (agent-chief--time-context)
               (agent-chief--state-context)
               (agent-chief--extra-context)))
   "\n\n"))

(defun agent-chief--response-contract ()
  "Return the JSON response contract for the chief-of-staff model."
  (concat
   "Return exactly this JSON shape:\n"
   "{\"notify\":true|false,"
   "\"title\":\"short notification title\","
   "\"message\":\"concise message to Pablo\","
   "\"state_update\":\"optional durable note or empty string\"}\n"
   "Use notify=false when no contact is warranted. Keep message under 700 "
   "characters. Put only auditable durable observations in state_update."))

(defun agent-chief--time-context ()
  "Return current time context for the chief-of-staff model."
  (format "Current time: %s\nTime zone: %s"
          (format-time-string "%Y-%m-%d %A %H:%M:%S %Z")
          (or (getenv "TZ") "local Emacs time zone")))

(defun agent-chief--state-context ()
  "Return state-file context for the chief-of-staff model."
  (format "State file: %s\n\n%s"
          agent-chief-state-file
          (or (agent-chief--read-state-file)
              "(state file is empty or missing)")))

(defun agent-chief--extra-context ()
  "Return configured context snippets for the chief-of-staff model."
  (let ((snippets (agent-chief--context-snippets)))
    (when snippets
      (concat "Additional context:\n\n"
              (string-join snippets "\n\n")))))

(defun agent-chief--context-snippets ()
  "Return nonempty snippets from `agent-chief-context-functions'."
  (cl-loop for fn in agent-chief-context-functions
           for value = (funcall fn)
           when (and (stringp value) (not (string-empty-p (string-trim value))))
           collect (string-trim value)))

(defun agent-chief--read-state-file ()
  "Return a truncated copy of `agent-chief-state-file', or nil."
  (when (file-readable-p agent-chief-state-file)
    (with-temp-buffer
      (insert-file-contents agent-chief-state-file)
      (let ((text (buffer-string)))
        (if (> (length text) agent-chief-state-max-chars)
            (concat "(truncated to most recent "
                    (number-to-string agent-chief-state-max-chars)
                    " characters)\n"
                    (substring text (- (length text)
                                       agent-chief-state-max-chars)))
          text)))))

;;;; Backend dispatch

(defun agent-chief--run-backend (prompt callback)
  "Run PROMPT through `agent-chief-backend' and call CALLBACK."
  (pcase agent-chief-backend
    ('codex
     (require 'agent-codex)
     (agent-codex--run-prompt
      prompt
      :dir agent-chief-directory
      :callback callback))
    ('claude-code
     (require 'agent-claude)
     (agent-claude--run-prompt
      prompt
      :dir agent-chief-directory
      :max-turns agent-chief-max-turns
      :callback callback))
    (_
     (setq agent-chief--running nil)
     (user-error "Unsupported agent-chief backend: %S"
                 agent-chief-backend))))

;;;; Result handling

(defun agent-chief--handle-result (result)
  "Handle backend RESULT from one chief-of-staff tick."
  (setq agent-chief--last-result result)
  (if (not (zerop (or (plist-get result :exit-code) 1)))
      (message "Agent chief backend failed: %s"
               (or (plist-get result :text) "(no output)"))
    (condition-case err
        (agent-chief--handle-decision
         (agent-chief--parse-decision (plist-get result :text)))
      (error
       (message "Agent chief could not parse backend output: %s"
                (error-message-string err))))))

(defun agent-chief--handle-decision (decision)
  "Apply parsed chief-of-staff DECISION."
  (setq agent-chief--last-decision decision)
  (when-let* ((state-update (plist-get decision :state_update)))
    (unless (string-empty-p (string-trim state-update))
      (agent-chief--append-state-heading "Model state update" state-update)))
  (when (agent-chief--truthy-p (plist-get decision :notify))
    (funcall agent-chief-notify-function
             (or (plist-get decision :title) "Chief of staff")
             (or (plist-get decision :message) ""))))

(defun agent-chief--parse-decision (text)
  "Parse a JSON decision object from TEXT."
  (let* ((json-object (agent-chief--extract-json text))
         (decision (json-parse-string json-object :object-type 'plist)))
    (unless (plist-member decision :notify)
      (error "Missing notify field"))
    decision))

(defun agent-chief--extract-json (text)
  "Extract the first JSON object from TEXT."
  (unless (stringp text)
    (error "Backend returned no text"))
  (let ((start (string-match-p "{" text))
        (end (cl-position ?} text :from-end t)))
    (unless (and start end (< start end))
      (error "No JSON object found"))
    (substring text start (1+ end))))

(defun agent-chief--truthy-p (value)
  "Return non-nil when VALUE is a JSON truthy value."
  (and value (not (eq value :false))))

;;;; State and notifications

(defun agent-chief--append-state-heading (heading body)
  "Append HEADING and BODY to `agent-chief-state-file'."
  (make-directory (file-name-directory agent-chief-state-file) t)
  (let ((timestamp (format-time-string "[%Y-%m-%d %a %H:%M]")))
    (with-temp-buffer
      (when (file-readable-p agent-chief-state-file)
        (insert-file-contents agent-chief-state-file)
        (goto-char (point-max))
        (unless (bolp) (insert "\n")))
      (insert (format "* %s %s\n\n%s\n" heading timestamp body))
      (write-region (point-min) (point-max) agent-chief-state-file nil
                    'silent))))

(defun agent-chief-notify (title message)
  "Notify the user with TITLE and MESSAGE."
  (message "%s: %s" title message)
  (when (and (require 'alert nil t) (fboundp 'alert))
    (alert message :title title)))

;;;; Provide

(provide 'agent-chief)
;;; agent-chief.el ends here
