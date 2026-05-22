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
;; state, and notifications.  In the default mode, Claude Code or
;; Codex runs as an ordinary long-lived session that receives periodic
;; heartbeat prompts and remains available for conversation.

;;; Code:

(require 'agent)
(require 'cl-lib)
(require 'json)
(require 'subr-x)

(declare-function agent-claude--run-prompt "agent-claude" (prompt &rest kwargs))
(declare-function agent-codex--run-prompt "agent-codex" (prompt &rest kwargs))
(declare-function claude-code--directory "claude-code" ())
(declare-function claude-code--prompt-for-instance-name
                  "claude-code" (dir existing-instance-names &optional force-prompt))
(declare-function codex--directory "codex" ())
(declare-function codex--prompt-for-instance-name
                  "codex" (dir existing-instance-names &optional force-prompt))
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

(defcustom agent-chief-mode 'session
  "Chief-of-staff execution mode.
When this is `session', `agent-chief-tick' submits heartbeat
prompts to a long-lived Claude Code or Codex session.  When this
is `stateless', each tick uses a one-shot non-interactive backend
call and parses a JSON decision."
  :type '(choice (const :tag "Interactive session" session)
                 (const :tag "Stateless one-shot" stateless))
  :group 'agent-chief)

(defcustom agent-chief-interval 1800
  "Number of seconds between chief-of-staff ticks."
  :type 'integer
  :group 'agent-chief)

(defcustom agent-chief-directory
  (let ((epoch-directory "/Users/pablostafforini/My Drive/Epoch/"))
    (if (file-directory-p epoch-directory)
        epoch-directory
      user-emacs-directory))
  "Working directory used for chief-of-staff agent sessions."
  :type 'directory
  :group 'agent-chief)

(defcustom agent-chief-session-instance-name "chief"
  "Instance name used for the interactive chief-of-staff session."
  :type 'string
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

(defcustom agent-chief-record-model-state-updates nil
  "When non-nil, append stateless model state updates to the state file.
This is disabled by default because periodic model observations are
not durable user-approved memory.  Plans and notes should normally
enter the state file through `agent-chief-set-day-plan' and
`agent-chief-add-note'."
  :type 'boolean
  :group 'agent-chief)

(defconst agent-chief--legacy-json-system-prompt
  (concat
   "You are Pablo's chief-of-staff agent. Your job is to decide whether "
   "to contact him now based only on the supplied auditable context. Be "
   "selective: contact him only when a timely nudge would help him stay "
   "on track, avoid missing a commitment, or recover from drift. Never "
   "invent obligations. Never claim to have checked a source that was not "
   "included in the prompt. Return exactly one JSON object and no prose.")
  "Old default prompt that incorrectly leaked the stateless JSON contract.")

(defconst agent-chief--default-system-prompt
  (concat
   "You are Pablo's chief-of-staff agent. Your job is to help him follow "
   "the plan he deliberately gives you. Be selective: contact him only "
   "when a timely nudge would help him stay on track, avoid missing a "
   "commitment, or recover from drift. Never invent obligations. Never "
   "claim to have checked a source that was not included in the prompt.")
  "Default standing instruction for chief-of-staff sessions and ticks.")

(defcustom agent-chief-system-prompt agent-chief--default-system-prompt
  "Standing instruction for chief-of-staff sessions and ticks."
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

(defvar agent-chief-session-buffer nil
  "Active chief-of-staff session buffer, or nil.")

(defvar agent-chief--last-session-response nil
  "Last heartbeat response extracted from the chief session.")

(defvar-local agent-chief--session-start-marker nil
  "Marker for the start of the pending heartbeat response.")

(defvar-local agent-chief--session-p nil
  "Non-nil when this buffer is the chief-of-staff session.")

(defvar-local agent-chief--session-awaiting-heartbeat nil
  "Non-nil while this chief session is answering a heartbeat.")

(defvar-local agent-chief--session-backend nil
  "Backend symbol for this chief-of-staff session.")

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
(defun agent-chief-start-session ()
  "Start or reuse the interactive chief-of-staff session.
The session itself asks for today's plan so the user can reply
conversationally in the agent buffer."
  (interactive)
  (let ((buffer (agent-chief--ensure-session)))
    (agent-chief--clear-session-heartbeat-state buffer)
    (agent-chief--submit-to-session
     (agent-chief--session-introduction)
     buffer)
    (agent-chief-start t)
    (pop-to-buffer buffer)))

;;;###autoload
(defun agent-chief-stop ()
  "Stop the chief-of-staff loop."
  (interactive)
  (when (timerp agent-chief--timer)
    (cancel-timer agent-chief--timer))
  (setq agent-chief--timer nil)
  (setq agent-chief--running nil)
  (when-let* ((buffer (agent-chief--session-buffer)))
    (agent-chief--clear-session-heartbeat-state buffer))
  (message "Agent chief stopped"))

;;;###autoload
(defun agent-chief-tick ()
  "Run one chief-of-staff check."
  (interactive)
  (pcase agent-chief-mode
    ('session (agent-chief-session-heartbeat))
    ('stateless (agent-chief-stateless-tick))
    (_ (user-error "Unsupported agent-chief mode: %S" agent-chief-mode))))

;;;###autoload
(defun agent-chief-stateless-tick ()
  "Run one stateless chief-of-staff check."
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
(defun agent-chief-session-heartbeat ()
  "Submit one heartbeat to the interactive chief-of-staff session."
  (interactive)
  (if agent-chief--running
      (message "Agent chief heartbeat skipped; previous heartbeat still running")
    (let ((buffer (agent-chief--ensure-session)))
      (setq agent-chief--running t)
      (with-current-buffer buffer
        (setq agent-chief--session-awaiting-heartbeat t)
        (setq agent-chief--session-start-marker (copy-marker (point-max) t)))
      (agent-chief--submit-to-session
       (agent-chief--session-heartbeat-prompt)
       buffer))))

;;;###autoload
(defun agent-chief-switch-to-session ()
  "Switch to the active chief-of-staff session."
  (interactive)
  (let ((buffer (agent-chief--session-buffer)))
    (unless buffer
      (user-error "No active chief-of-staff session"))
    (pop-to-buffer buffer)))

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
  (when (agent-chief--session-buffer)
    (agent-chief--submit-to-session
     (format "[Chief-of-staff note]\n\n%s" note)))
  (message "Agent chief note saved"))

;;;###autoload
(defun agent-chief-set-day-plan (plan)
  "Append today's PLAN to `agent-chief-state-file'."
  (interactive "sPlan for today: ")
  (agent-chief--append-state-heading
   (format "Plan %s" (format-time-string "%Y-%m-%d"))
   plan)
  (when (agent-chief--session-buffer)
    (agent-chief--submit-to-session
     (format "[Chief-of-staff day plan]\n\n%s" plan)))
  (message "Agent chief day plan saved"))

;;;; Interactive session

(defun agent-chief--ensure-session ()
  "Return a live chief-of-staff session buffer, starting one if needed."
  (or (agent-chief--session-buffer)
      (agent-chief--start-session-buffer)))

(defun agent-chief--session-buffer ()
  "Return the live chief-of-staff session buffer, or nil."
  (when (buffer-live-p agent-chief-session-buffer)
    agent-chief-session-buffer))

(defun agent-chief--clear-session-heartbeat-state (&optional buffer)
  "Clear pending heartbeat state for BUFFER and the global running flag."
  (setq agent-chief--running nil)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq agent-chief--session-awaiting-heartbeat nil)
      (setq agent-chief--session-start-marker nil))))

(defun agent-chief--start-session-buffer ()
  "Start and return a chief-of-staff session buffer."
  (agent-chief--require-backend)
  (or (agent-chief--find-session-buffer)
      (progn
        (agent-chief--call-backend-start)
        (or (agent-chief--find-session-buffer)
            (user-error "Could not find started chief-of-staff session")))))

(defun agent-chief--require-backend ()
  "Load the configured chief backend."
  (pcase agent-chief-backend
    ('codex (require 'agent-codex))
    ('claude-code (require 'agent-claude))
    (_ (user-error "Unsupported agent-chief backend: %S"
                   agent-chief-backend))))

(defun agent-chief--find-session-buffer ()
  "Return the chief-of-staff session buffer for the configured backend."
  (let ((buffer (cl-find-if
                 #'agent-chief--session-buffer-p
                 (agent-chief--backend-buffers))))
    (when buffer
      (agent-chief--mark-session-buffer buffer))
    buffer))

(defun agent-chief--backend-buffers ()
  "Return buffers for `agent-chief-backend' in `agent-chief-directory'."
  (when-let* ((fn (agent--backend-get agent-chief-backend
                                      :find-buffers-for-dir)))
    (funcall fn (file-name-as-directory
                 (file-truename
                  (expand-file-name agent-chief-directory))))))

(defun agent-chief--session-buffer-p (buffer)
  "Return non-nil when BUFFER is the configured chief session."
  (and (buffer-live-p buffer)
       (equal (agent-chief--buffer-instance buffer)
              agent-chief-session-instance-name)))

(defun agent-chief--buffer-instance (buffer)
  "Return BUFFER's backend instance name."
  (when-let* ((fn (agent--backend-get agent-chief-backend
                                      :extract-instance-name)))
    (funcall fn (buffer-name buffer))))

(defun agent-chief--mark-session-buffer (buffer)
  "Mark BUFFER as the active chief-of-staff session."
  (setq agent-chief-session-buffer buffer)
  (with-current-buffer buffer
    (setq-local agent-chief--session-p t)
    (setq-local agent-chief--session-backend agent-chief-backend))
  buffer)

(defun agent-chief--call-backend-start ()
  "Start a backend session in `agent-chief-directory' with chief instance."
  (pcase agent-chief-backend
    ('codex (agent-chief--call-codex-start))
    ('claude-code (agent-chief--call-claude-start))))

(defun agent-chief--call-codex-start ()
  "Start a Codex chief-of-staff session."
  (let ((dir (file-name-as-directory
              (file-truename
               (expand-file-name agent-chief-directory))))
        (instance agent-chief-session-instance-name))
    (cl-letf (((symbol-function 'codex--directory) (lambda () dir))
              ((symbol-function 'codex--prompt-for-instance-name)
               (lambda (_dir _existing _force) instance)))
      (funcall (agent--backend-get 'codex :start) nil nil nil t))))

(defun agent-chief--call-claude-start ()
  "Start a Claude Code chief-of-staff session."
  (let ((dir (file-name-as-directory
              (file-truename
               (expand-file-name agent-chief-directory))))
        (instance agent-chief-session-instance-name))
    (cl-letf (((symbol-function 'claude-code--directory) (lambda () dir))
              ((symbol-function 'claude-code--prompt-for-instance-name)
               (lambda (_dir _existing _force) instance)))
      (funcall (agent--backend-get 'claude-code :start) nil nil nil t))))

(defun agent-chief--submit-to-session (prompt &optional buffer)
  "Submit PROMPT to the chief-of-staff session BUFFER."
  (let* ((target (or buffer (agent-chief--session-buffer)
                     (agent-chief--ensure-session)))
         (backend (buffer-local-value 'agent-chief--session-backend target))
         (submit (agent--backend-get backend :submit-command)))
    (unless submit
      (user-error "Backend %S cannot submit chief prompts" backend))
    (funcall submit prompt target)))

(defun agent-chief--session-introduction ()
  "Return the initial prompt for an interactive chief session."
  (string-join
   (list
    "Start chief-of-staff mode for this session."
    "Ask me for today's plan in one short, normal sentence. Reply conversationally."
    "After I answer, briefly restate the plan and use it for later heartbeat checks in this conversation.")
   "\n\n"))

(defun agent-chief--session-heartbeat-prompt ()
  "Return the heartbeat prompt for the interactive chief session."
  (agent-chief--normalize-system-prompt)
  (string-join
   (delq nil
         (list
          agent-chief-system-prompt
          (format "[Chief-of-staff heartbeat: %s]"
                  (format-time-string "%Y-%m-%d %A %H:%M:%S %Z"))
          "Review the current day plan, explicit state, and this conversation."
          "If Pablo should be nudged now, respond with `Nudge: ` followed by one concise message."
          "If no nudge is warranted, respond exactly `No nudge.`"
          "Do not invent obligations; use only supplied state and conversation context."
          (agent-chief--state-context)
          (agent-chief--extra-context)))
   "\n\n"))

(defun agent-chief--handle-backend-event (message)
  "Handle backend MESSAGE for chief-of-staff session notifications."
  (when (eq (plist-get message :type) 'notification)
    (when-let* ((buffer-name (plist-get message :buffer-name))
                (buffer (get-buffer buffer-name)))
      (when (eq buffer (agent-chief--session-buffer))
        (agent-chief--handle-session-ready buffer))))
  nil)

(defun agent-chief--handle-session-ready (buffer)
  "Handle BUFFER becoming ready after a heartbeat."
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'agent-chief--session-awaiting-heartbeat
                                 buffer))
    (with-current-buffer buffer
      (setq agent-chief--session-awaiting-heartbeat nil)
      (setq agent-chief--running nil)
      (let* ((text (agent-chief--session-response-text buffer))
             (reply (agent-chief--extract-session-reply text)))
        (setq agent-chief--last-session-response reply)
        (pcase (car reply)
          ('no-nudge nil)
          ('nudge
           (funcall agent-chief-notify-function
                    "Chief of staff"
                    (cdr reply)))
          (_
           (funcall agent-chief-notify-function
                    "Chief of staff"
                    (agent-chief--truncate-message text))))))))

(defun agent-chief--session-response-text (buffer)
  "Return text inserted in BUFFER since the pending heartbeat started."
  (with-current-buffer buffer
    (let ((start (if (markerp agent-chief--session-start-marker)
                     (marker-position agent-chief--session-start-marker)
                   (point-min))))
      (buffer-substring-no-properties start (point-max)))))

(defun agent-chief--extract-session-reply (text)
  "Return a cons describing the chief heartbeat reply in TEXT."
  (let ((nudge-pos (agent-chief--last-match-position
                    "\\(?:CHIEF_NUDGE\\|Nudge\\):[ \t]*\\([^\n\r]+\\)" text))
        (quiet-pos (or (agent-chief--last-match-position "CHIEF_NO_NUDGE" text)
                       (agent-chief--last-match-position "\\bNo nudge\\." text))))
    (cond
     ((and quiet-pos (or (not nudge-pos) (> quiet-pos nudge-pos)))
      (cons 'no-nudge nil))
     (nudge-pos
      (string-match "\\(?:CHIEF_NUDGE\\|Nudge\\):[ \t]*\\([^\n\r]+\\)"
                    text nudge-pos)
      (cons 'nudge (string-trim (match-string 1 text))))
     (t
      (cons 'unknown (string-trim text))))))

(defun agent-chief--last-match-position (regexp text)
  "Return the last match position for REGEXP in TEXT, or nil."
  (let ((pos 0)
        last)
    (while (setq pos (string-match regexp text pos))
      (setq last pos)
      (setq pos (match-end 0)))
    last))

(defun agent-chief--truncate-message (text)
  "Return TEXT shortened for notification display."
  (truncate-string-to-width (string-trim text) 700 nil nil "..."))

;;;; Prompt construction

(defun agent-chief--build-prompt ()
  "Build the prompt for one chief-of-staff tick."
  (agent-chief--normalize-system-prompt)
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
   "characters. Leave state_update empty unless explicitly asked to draft "
   "a durable state note."))

(defun agent-chief--normalize-system-prompt ()
  "Replace stale JSON-oriented default prompt values in live sessions."
  (when (equal agent-chief-system-prompt
               agent-chief--legacy-json-system-prompt)
    (setq agent-chief-system-prompt agent-chief--default-system-prompt)))

(defun agent-chief--time-context ()
  "Return current time context for the chief-of-staff model."
  (format "Current time: %s\nTime zone: %s"
          (format-time-string "%Y-%m-%d %A %H:%M:%S %Z")
          (or (getenv "TZ") "local Emacs time zone")))

(defun agent-chief--state-context ()
  "Return state-file context for the chief-of-staff model."
  (format (concat
           "State file: %s\n"
           "Only a Plan heading dated today is current; older Plan headings "
           "are historical, not active obligations unless restated today.\n\n%s")
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
  (when-let* ((state-update (and agent-chief-record-model-state-updates
                                 (plist-get decision :state_update))))
    (unless (or (not (stringp state-update))
                (string-empty-p (string-trim state-update)))
      (agent-chief--append-state-heading "Model state update" state-update)))
  (when (agent-chief--truthy-p (plist-get decision :notify))
    (funcall agent-chief-notify-function
             (or (plist-get decision :title) "Chief of staff")
             (or (plist-get decision :message) ""))))

(defun agent-chief--parse-decision (text)
  "Parse a JSON decision object from TEXT."
  (let* ((json-object (agent-chief--extract-decision-json text))
         (decision (json-parse-string json-object :object-type 'plist)))
    (unless (plist-member decision :notify)
      (error "Missing notify field"))
    decision))

(defun agent-chief--extract-decision-json (text)
  "Extract the last valid decision JSON object from TEXT."
  (unless (stringp text)
    (error "Backend returned no text"))
  (or (car (last (agent-chief--valid-decision-json-objects text)))
      (error "No valid decision JSON object found")))

(defun agent-chief--valid-decision-json-objects (text)
  "Return valid decision JSON object strings found in TEXT."
  (let ((objects nil)
        (pos 0))
    (while (setq pos (string-match-p "{" text pos))
      (when-let* ((object (agent-chief--balanced-json-object text pos)))
        (when (agent-chief--decision-json-p object)
          (push object objects)))
      (setq pos (1+ pos)))
    (nreverse objects)))

(defun agent-chief--balanced-json-object (text start)
  "Return the balanced JSON object in TEXT starting at START."
  (let ((pos start)
        (depth 0)
        (in-string nil)
        (escape nil)
        (done nil))
    (while (and (< pos (length text)) (not done))
      (let ((char (aref text pos)))
        (cond
         (escape
          (setq escape nil))
         ((and in-string (= char ?\\))
          (setq escape t))
         ((= char ?\")
          (setq in-string (not in-string)))
         ((not in-string)
          (cond
           ((= char ?{)
            (setq depth (1+ depth)))
           ((= char ?})
            (setq depth (1- depth))
            (when (zerop depth)
              (setq done t)))))))
      (setq pos (1+ pos)))
    (when done
      (substring text start pos))))

(defun agent-chief--decision-json-p (object)
  "Return non-nil when OBJECT parses as a chief decision."
  (condition-case nil
      (let ((decision (json-parse-string object :object-type 'plist)))
        (plist-member decision :notify))
    (error nil)))

(defalias 'agent-chief--extract-json #'agent-chief--extract-decision-json)

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

(with-eval-after-load 'agent-codex
  (add-hook 'codex-event-hook #'agent-chief--handle-backend-event))

(with-eval-after-load 'agent-claude
  (add-hook 'claude-code-event-hook #'agent-chief--handle-backend-event))

;;;; Provide

(provide 'agent-chief)
;;; agent-chief.el ends here
