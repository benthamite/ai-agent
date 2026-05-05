;;; ai-agent-codex.el --- Extensions for codex -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/ai-agent
;; Version: 0.1
;; Package-Requires: ((codex "0.1") (ai-agent "0.1"))

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

;; Extensions for `codex'.

;;; Code:

(require 'codex)
(eval-and-compile (require 'ai-agent))
(require 'subr-x)
(require 'transient)

;;;; Variables

(defgroup ai-agent-codex ()
  "Extensions for `codex'."
  :group 'codex)

(defcustom ai-agent-codex-handoff-file "/tmp/codex-handoff.md"
  "Path to the handoff file written by the handoff skill."
  :type 'file
  :group 'ai-agent-codex)

(defcustom ai-agent-codex-skill-directories nil
  "Additional directories to scan for Codex skills.
Searched in addition to the standard locations."
  :type '(repeat directory)
  :group 'ai-agent-codex)

(defcustom ai-agent-codex-audit-skills
  '("/code-audit" "/design-audit" "/interpretability-audit")
  "Skills to run when performing a project audit."
  :type '(repeat string)
  :group 'ai-agent-codex)

(defcustom ai-agent-codex-audit-project-directories nil
  "Directories available for selection in `ai-agent-codex-audit-project'."
  :type '(repeat directory)
  :group 'ai-agent-codex)

(defcustom ai-agent-codex-debug-backtrace-model 'gemini-flash-lite-latest
  "GPtel model for identifying candidate packages from a backtrace."
  :type 'symbol
  :group 'ai-agent-codex)

(defcustom ai-agent-codex-debug-backtrace-backend "Gemini"
  "GPtel backend name for backtrace analysis."
  :type 'string
  :group 'ai-agent-codex)

(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-use-tools)
(defvar gptel--known-backends)
(declare-function ai-agent-svg-icon "ai-agent" (svg-data &optional face))
(declare-function debug-save-backtrace "init" ())
(declare-function gptel-request "gptel")
(declare-function elpaca-get "elpaca")
(declare-function elpaca-source-dir "elpaca")
(declare-function find-library-name "find-func")
(declare-function paths-dir-downloads "paths")
(defvar paths-dir-downloads)

;;;; Backend registration

(defconst ai-agent-codex-icon-svg
  "<svg fill=\"currentColor\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z\"/></svg>"
  "SVG path data for the OpenAI logo (knot icon).
Source: SVG Repo (CC0).")

(ai-agent-register-backend 'codex
  (list :buffer-p #'codex--buffer-p
        :find-all-buffers #'codex--find-all-codex-buffers
        :find-buffers-for-dir #'codex--find-codex-buffers-for-directory
        :directory (lambda (buf) (with-current-buffer buf (codex--directory)))
        :extract-directory #'codex--extract-directory-from-buffer-name
        :extract-instance-name #'codex--extract-instance-name-from-buffer-name
        :send-command (lambda (cmd &optional _buf) (codex--do-send-command cmd))
        :start #'codex--start
        :start-new #'codex
        :program "codex"
        :send-return (lambda (&optional _buf)
                       (codex--term-send-return codex-terminal-backend))
        :icon (lambda (&optional face) (let ((svg (ai-agent-svg-icon ai-agent-codex-icon-svg face)))
                                        (if (string-empty-p svg) "CX" svg)))
        :label "Codex"
        :discover-skills #'ai-agent-codex--discover-skills
        :handoff #'ai-agent-codex-handoff
        :run-skill #'ai-agent-codex-run-skill
        :audit-project #'ai-agent-codex-audit-project
        :debug-backtrace #'ai-agent-codex-debug-backtrace
        :setup-kill-on-exit #'ai-agent-codex-setup-kill-on-exit
        :exit #'ai-agent-codex-exit
        :restart #'ai-agent-codex-restart
        :sync-theme #'ai-agent-codex--sync-theme))

;;;; Functions

;;;;; Mode line

(declare-function doom-modeline-set-modeline "doom-modeline-core")

(defvar-local ai-agent-codex--start-time nil
  "Time when this Codex session started.")

(defvar ai-agent-codex--config-model-cache nil
  "Cached model lookup as (MTIME . MODEL) for `~/.codex/config.toml'.")

(defun ai-agent-codex--parse-config-model (config)
  "Return the model string declared in CONFIG, or nil."
  (with-temp-buffer
    (insert-file-contents config)
    (goto-char (point-min))
    (when (re-search-forward "^model *= *\"\\([^\"]+\\)\"" nil t)
      (match-string 1))))

(defun ai-agent-codex--read-config-model ()
  "Read the model from `~/.codex/config.toml'.
Cached by file modification time so the doom-modeline ai-session
segment does not perform disk I/O on every redisplay."
  (let* ((config (expand-file-name "~/.codex/config.toml"))
         (mtime (file-attribute-modification-time (file-attributes config))))
    (cond
     ((null mtime) nil)
     ((and ai-agent-codex--config-model-cache
           (equal mtime (car ai-agent-codex--config-model-cache)))
      (cdr ai-agent-codex--config-model-cache))
     (t
      (let ((model (ai-agent-codex--parse-config-model config)))
        (setq ai-agent-codex--config-model-cache (cons mtime model))
        model)))))

(defun ai-agent-codex-set-modeline ()
  "Set the doom-modeline to the `ai-session' modeline for this buffer.
Also records the session start time."
  (when (codex--buffer-p (current-buffer))
    (setq ai-agent-codex--start-time (current-time))
    (doom-modeline-set-modeline 'ai-session)))

(defun ai-agent-codex-status-model ()
  "Return the model name for the current Codex session."
  (ai-agent-codex--read-config-model))

(defun ai-agent-codex-status-duration-ms ()
  "Return session duration in milliseconds, or nil."
  (when ai-agent-codex--start-time
    (truncate (* 1000 (float-time
                       (time-subtract (current-time)
                                      ai-agent-codex--start-time))))))

;;;;; Theme sync

(defun ai-agent-codex--sync-theme (theme)
  "Update Codex persistent theme configuration to THEME.
THEME is either \"light\" or \"dark\".  Return non-nil when the
config file changed."
  (ai-agent-codex--sync-theme-to-config theme))

(defun ai-agent-codex--sync-theme-to-config (&optional theme)
  "Update `tui.theme' in `codex-hooks-config-path' to THEME.
When THEME is nil, use the current Emacs AI theme.  Only writes
the file when the theme value actually changes."
  (let* ((theme (or theme (ai-agent--theme)))
         (config-file (expand-file-name codex-hooks-config-path))
         (new-line (format "theme = \"%s\"" theme)))
    (make-directory (file-name-directory config-file) t)
    (with-temp-buffer
      (when (file-exists-p config-file)
        (insert-file-contents config-file))
      (let ((original (buffer-string))
            (found nil))
        (goto-char (point-min))
        (when (re-search-forward "^\\[tui\\]" nil t)
          (let ((section-end (save-excursion
                               (if (re-search-forward "^\\[" nil t)
                                   (line-beginning-position)
                                 (point-max)))))
            (when (re-search-forward "^theme *= *\"[^\"]*\"" section-end t)
              (replace-match new-line)
              (setq found t))))
        (unless found
          (goto-char (point-min))
          (if (re-search-forward "^\\[tui\\]" nil t)
              (progn
                (end-of-line)
                (insert "\n" new-line))
            (goto-char (point-max))
            (unless (or (bobp) (bolp)) (insert "\n"))
            (unless (bobp) (insert "\n"))
            (insert "[tui]\n" new-line "\n")))
        (unless (equal original (buffer-string))
          (write-region (point-min) (point-max) config-file nil 'silent)
          t)))))

(defun ai-agent-codex--sync-theme-before-start (&rest _)
  "Persist the shared AI theme before starting a Codex process."
  (ai-agent-sync-theme-now)
  nil)

;;;;; Notification handling

(defun ai-agent-codex--handle-notification (message)
  "Handle a notification event from Codex CLI.
MESSAGE is a plist with :type, :buffer-name, :json-data, and :args.
The :type field is a string from the hook wrapper (e.g. \"Stop\")."
  (let ((hook-type (plist-get message :type)))
    (when (member hook-type '("Stop" "Notification" "SessionStart"))
      (when-let* ((buf (get-buffer (plist-get message :buffer-name))))
        (with-current-buffer buf
          (let ((name (ai-agent--session-name (buffer-name))))
            (pcase hook-type
              ("Stop"
               (setq ai-agent--waiting-for-input (current-time))
               (ai-agent-notify
                "Codex ready"
                (format "%s: waiting for your response" name))
               (ai-agent--scroll-to-bottom buf))
              ("Notification"
               (ai-agent-notify
                "Codex"
                (format "%s: needs your attention" name)))))))))
  nil)

;;;;; Skill runner

(defun ai-agent-codex--discover-skills ()
  "Discover available Codex skills.
Scans the standard Codex skill directories and any custom ones
from `ai-agent-codex-skill-directories'."
  (let ((skills (make-hash-table :test #'equal))
        (dirs (append
               ;; Standard Codex skill locations
               (list (expand-file-name "skills"
                                       (or (getenv "CODEX_HOME") "~/.codex")))
               ;; Project-local
               (when-let* ((proj (project-current)))
                 (list (expand-file-name ".agents/skills" (project-root proj))))
               ;; Custom
               ai-agent-codex-skill-directories)))
    (dolist (dir dirs)
      (when (file-directory-p dir)
        (dolist (file (file-expand-wildcards
                       (expand-file-name "*/SKILL.md" dir)))
          (when-let* ((meta (ai-agent-codex--parse-skill-frontmatter file))
                      (name (plist-get meta :name)))
            (puthash name (append meta (list :path file :source dir))
                     skills)))))
    (let (result)
      (maphash (lambda (_name skill) (push skill result)) skills)
      (sort result (lambda (a b)
                     (string< (plist-get a :name) (plist-get b :name)))))))

(defun ai-agent-codex--parse-skill-frontmatter (file)
  "Parse YAML frontmatter from skill FILE and return a plist."
  (ai-agent-parse-skill-frontmatter file))

;;;###autoload
(defun ai-agent-codex-run-skill (skill-name &optional arguments)
  "Run Codex skill SKILL-NAME with optional ARGUMENTS.
Sends the skill invocation to the active Codex session."
  (interactive
   (let* ((skills (ai-agent-codex--discover-skills))
          (_ (unless skills (user-error "No skills found")))
          (name (completing-read
                 "Skill: "
                 (mapcar (lambda (s) (plist-get s :name)) skills)
                 nil t))
          (args (read-string (format "Arguments for %s: " name))))
     (list name (unless (string-empty-p args) args))))
  (let* ((prompt (if arguments
                     (format "/%s %s" skill-name arguments)
                   (format "/%s" skill-name)))
         (buf (or (and (codex--buffer-p (current-buffer))
                       (current-buffer))
                  (codex--get-or-prompt-for-buffer)
                  (user-error "No running Codex session"))))
    (with-current-buffer buf
      (codex--do-send-command prompt))
    (display-buffer buf)))

;;;;; Project audit

;;;###autoload
(defun ai-agent-codex-audit-project ()
  "Run a comprehensive audit of a project via Codex.
Sequentially sends each skill in `ai-agent-codex-audit-skills'
to a Codex session."
  (interactive)
  (let* ((dir (ai-agent-codex--read-audit-directory))
         (skills ai-agent-codex-audit-skills))
    (when (yes-or-no-p
           (format "Run %d audit(s) on %s?" (length skills) dir))
      (let ((buf (or (car (codex--find-codex-buffers-for-directory dir))
                     (let ((default-directory dir))
                       (codex)
                       (car (codex--find-codex-buffers-for-directory dir))))))
        (unless buf
          (user-error "Failed to create Codex session for %s" dir))
        (dolist (skill skills)
          (with-current-buffer buf
            (codex--do-send-command (format "%s --accept" skill))))))))

(defun ai-agent-codex--read-audit-directory ()
  "Prompt for a project directory with completion."
  (let* ((candidates (mapcar #'abbreviate-file-name
                             ai-agent-codex-audit-project-directories))
         (input (completing-read "Project directory: " candidates nil nil))
         (dir (file-truename (expand-file-name input))))
    (unless (file-directory-p dir)
      (user-error "Not a directory: %s" dir))
    (unless (member dir (mapcar #'file-truename
                                ai-agent-codex-audit-project-directories))
      (customize-save-variable 'ai-agent-codex-audit-project-directories
                               (append ai-agent-codex-audit-project-directories
                                       (list dir))))
    dir))

;;;;; Debug backtrace

;;;###autoload
(defun ai-agent-codex-debug-backtrace ()
  "Save the backtrace, identify the offending package, and open Codex."
  (interactive)
  (let ((backtrace-file (expand-file-name "backtrace.el" paths-dir-downloads)))
    (run-with-timer 0 nil #'ai-agent-codex--debug-identify-package backtrace-file)
    (debug-save-backtrace)))

(defun ai-agent-codex--debug-identify-package (backtrace-file)
  "Identify candidate packages from BACKTRACE-FILE and let the user choose."
  (unless (file-exists-p backtrace-file)
    (user-error "Backtrace file not found: %s" backtrace-file))
  (message "Identifying packages from backtrace...")
  (let ((contents (with-temp-buffer
                    (insert-file-contents backtrace-file)
                    (buffer-string)))
        (gptel-backend (alist-get ai-agent-codex-debug-backtrace-backend
                                 gptel--known-backends nil nil #'string=))
        (gptel-model ai-agent-codex-debug-backtrace-model)
        (gptel-use-tools nil))
    (gptel-request
     (format "Backtrace file: %s\n\nContents:\n%s" backtrace-file contents)
     :system "You are an Emacs expert. Given the backtrace, identify ALL Emacs packages that appear in the stack trace and could be the root cause of the error. Return ONLY a comma-separated list of package names."
     :callback
     (lambda (response info)
       (if (not response)
           (message "gptel request failed: %s" (plist-get info :status))
         (let* ((candidates (mapcar #'string-trim (split-string response ",")))
                (selected (completing-read "Package to debug: " candidates nil nil nil nil
                                           (car candidates))))
           (ai-agent-codex--debug-start-session
            (intern selected) backtrace-file)))))))

(defun ai-agent-codex--debug-start-session (package backtrace-file)
  "Start a Codex session for PACKAGE with BACKTRACE-FILE."
  (let* ((elpaca-entry (and (fboundp 'elpaca-get) (elpaca-get package)))
         (dir (cond
               (elpaca-entry (elpaca-source-dir elpaca-entry))
               ((condition-case nil
                    (file-name-directory (find-library-name (symbol-name package)))
                  (error nil)))
               (t (user-error "Package `%s' not found" package))))
         (prompt (format "Read the backtrace at %s. Identify the bug, fix it, and commit the fix."
                         backtrace-file)))
    (message "Starting Codex for `%s' in %s..." package dir)
    (cl-letf (((symbol-function 'codex--directory) (lambda () dir)))
      (codex--start nil (list prompt) nil t))))

;;;;; Handoff

;;;###autoload
(defun ai-agent-codex-handoff ()
  "Close this Codex session and start a new one with the handoff prompt."
  (interactive)
  (unless (file-exists-p ai-agent-codex-handoff-file)
    (user-error "No handoff file at %s — run /handoff first"
                ai-agent-codex-handoff-file))
  (let* ((prompt (with-temp-buffer
                   (insert-file-contents ai-agent-codex-handoff-file)
                   (string-trim (buffer-string))))
         (dir (if (codex--buffer-p (current-buffer))
                  default-directory
                (codex--directory))))
    (when (string-empty-p prompt)
      (user-error "Handoff file is empty"))
    (when (codex--buffer-p (current-buffer))
      (let ((kill-buffer-query-functions
             (remq 'ai-agent-protect-buffer kill-buffer-query-functions)))
        (kill-buffer (current-buffer))))
    (cl-letf (((symbol-function 'codex--directory) (lambda () dir)))
      (codex--start nil (list prompt) nil t))))

;;;;; Restart

;;;###autoload
(defun ai-agent-codex-restart ()
  "Kill the current Codex session and resume it in place.
Useful when a setting change requires relaunching Codex.  Preserves the
session's directory and instance name.  Codex does not expose a
session ID to Emacs, so this relies on `codex resume --last', which
Codex CLI filters by working directory; the just-killed session is
the most recently updated one for that directory."
  (interactive)
  (unless (codex--buffer-p (current-buffer))
    (user-error "Not in a Codex buffer"))
  (let ((dir default-directory)
        (instance-name (codex--extract-instance-name-from-buffer-name
                        (buffer-name))))
    (let ((kill-buffer-query-functions
           (remq 'ai-agent-protect-buffer kill-buffer-query-functions)))
      (kill-buffer (current-buffer)))
    (cl-letf (((symbol-function 'codex--directory) (lambda () dir)))
      (codex--start-subcommand "resume" t nil instance-name))))

;;;;; Start or switch (Codex-specific entry point)

;;;###autoload
(defun ai-agent-codex-start-or-switch ()
  "Start a new Codex session or switch to an existing one.
If no Codex sessions exist, start a new one.  Otherwise, show the
unified session switcher."
  (interactive)
  (if (null (codex--find-all-codex-buffers))
      (codex)
    (ai-agent--ensure-all-session-keys)
    (transient-setup 'ai-agent--session-switcher)))

;;;; Hooks

(add-hook 'codex-event-hook #'ai-agent-codex--handle-notification)
(add-hook 'kill-buffer-query-functions #'ai-agent-protect-buffer)
(add-hook 'codex-start-hook #'ai-agent--assign-session-key)
(add-hook 'codex-start-hook #'ai-agent--refresh-display-names)
(add-hook 'codex-start-hook #'ai-agent-disable-scrollback-truncation)
(add-hook 'codex-start-hook #'ai-agent-setup-snippet-keys)
(add-hook 'codex-start-hook #'ai-agent-fix-rendering)
(add-hook 'codex-start-hook #'ai-agent-codex-set-modeline)
(add-hook 'codex-process-environment-functions
          #'ai-agent-codex--sync-theme-before-start)
(add-hook 'kill-buffer-hook #'ai-agent--release-session-key)
(add-hook 'kill-buffer-hook #'ai-agent--refresh-display-names-deferred)
(advice-add 'codex--do-send-command :before
            #'ai-agent--clear-waiting-for-input)

;;;;; Exit and kill on exit

;;;###autoload
(defun ai-agent-codex-exit ()
  "Exit the current Codex session and kill its buffer.
Codex CLI does not support `/exit', so this sends the process a
SIGHUP and kills the buffer from the Emacs side."
  (interactive)
  (ai-agent-kill-session-buffer))

(defun ai-agent-codex--intercept-exit (orig-fn cmd)
  "Intercept `/exit' and kill the session instead of forwarding it.
ORIG-FN is `codex--do-send-command'.  CMD is the command string.
Codex CLI does not recognize `/exit', so we handle it on the
Emacs side to match Claude Code's behavior."
  (if (string= (string-trim cmd) "/exit")
      (when-let* ((buf (codex--get-or-prompt-for-buffer)))
        (with-current-buffer buf
          (ai-agent-codex-exit)))
    (funcall orig-fn cmd)))

(defun ai-agent-codex-setup-kill-on-exit ()
  "Arrange for the buffer to be killed when the Codex process exits."
  (interactive)
  (when (codex--buffer-p (current-buffer))
    (when-let* ((proc (get-buffer-process (current-buffer))))
      (let ((orig (process-sentinel proc))
            (buf (current-buffer)))
        (set-process-sentinel
         proc
         (lambda (process event)
           (when orig (funcall orig process event))
           (when (buffer-live-p buf)
             (condition-case nil
                 (kill-buffer buf)
               (error nil)))))))))

(add-hook 'codex-start-hook #'ai-agent-codex-setup-kill-on-exit)
(advice-add 'codex--do-send-command :around #'ai-agent-codex--intercept-exit)

;;;; Provide

(provide 'ai-agent-codex)
;;; ai-agent-codex.el ends here
