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
(require 'cl-lib)
(require 'subr-x)
(require 'transient)

;;;; Variables

(defgroup ai-agent-codex ()
  "Extensions for `codex'."
  :group 'codex)

(defcustom ai-agent-codex-handoff-file
  (expand-file-name "codex-handoff.md" temporary-file-directory)
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

(defcustom ai-agent-codex-exec-approval-policy 'never
  "Approval policy used for non-interactive `codex exec' runs.
When nil, use `codex-approval-policy' or the CLI default."
  :type '(choice (const :tag "Codex default" nil)
                 (const :tag "Untrusted" untrusted)
                 (const :tag "On request" on-request)
                 (const :tag "Never" never))
  :group 'ai-agent-codex)

(defcustom ai-agent-codex-exec-sandbox-mode nil
  "Sandbox mode used for non-interactive `codex exec' runs.
When nil, use `codex-sandbox-mode' or the CLI default."
  :type '(choice (const :tag "Codex default" nil)
                 (const :tag "Read-only" read-only)
                 (const :tag "Workspace write" workspace-write)
                 (const :tag "Full access" danger-full-access))
  :group 'ai-agent-codex)

(defcustom ai-agent-codex-exec-skip-git-repo-check t
  "When non-nil, pass `--skip-git-repo-check' to `codex exec'."
  :type 'boolean
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
(declare-function gptel-request "gptel")

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
    (when (require 'doom-modeline-core nil t)
      (doom-modeline-set-modeline 'ai-session))))

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
            (unless (and (plist-member meta :user-invocable)
                         (not (plist-get meta :user-invocable)))
              (puthash name (append meta (list :path file :source dir))
                       skills))))))
    (let (result)
      (maphash (lambda (_name skill) (push skill result)) skills)
      (sort result (lambda (a b)
                     (string< (plist-get a :name) (plist-get b :name)))))))

(defun ai-agent-codex--parse-skill-frontmatter (file)
  "Parse YAML frontmatter from skill FILE and return a plist."
  (ai-agent-parse-skill-frontmatter file))

(defun ai-agent-codex--find-skill (skill-name)
  "Return discovered metadata for SKILL-NAME, or nil."
  (let ((name (string-remove-prefix "/" skill-name)))
    (cl-find name (ai-agent-codex--discover-skills)
             :key (lambda (skill) (plist-get skill :name))
             :test #'equal)))

(defun ai-agent-codex--skill-prompt (skill skill-name arguments)
  "Return a prompt for running SKILL-NAME with ARGUMENTS.
When SKILL metadata is available, point Codex at the skill file.
Otherwise return a slash invocation for Codex-native skill lookup."
  (if skill
      (format (string-join
               '("Run the Codex skill `%s`%s."
                 ""
                 "Skill file: %s"
                 ""
                 "Read the skill file first and follow its instructions exactly."
                 "Resolve relative paths mentioned by the skill relative to the skill file's directory.%s")
               "\n")
              (plist-get skill :name)
              (if (and arguments (not (string-empty-p arguments)))
                  (format " with these arguments: %s" arguments)
                "")
              (plist-get skill :path)
              (if (and arguments (not (string-empty-p arguments)))
                  (format "\n\nArguments: %s" arguments)
                ""))
    (ai-agent-codex--slash-invocation skill-name arguments)))

(defun ai-agent-codex--slash-invocation (skill-name arguments)
  "Return a Codex slash invocation for SKILL-NAME and ARGUMENTS."
  (let ((command (if (string-prefix-p "/" skill-name)
                     skill-name
                   (concat "/" skill-name))))
    (if (and arguments (not (string-empty-p arguments)))
        (format "%s %s" command arguments)
      command)))

(defun ai-agent-codex--display-result (buffer-name title result)
  "Display RESULT in BUFFER-NAME with TITLE."
  (let ((buf (get-buffer-create buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "#+title: %s — %s\n"
                        title
                        (format-time-string "%Y-%m-%d %H:%M:%S")))
        (insert (format "#+exit-code: %s\n" (plist-get result :exit-code)))
        (insert (format "#+duration: %.1fs\n\n" (plist-get result :duration)))
        (insert (or (plist-get result :text) "(no output)"))
        (unless (string-suffix-p "\n" (or (plist-get result :text) ""))
          (insert "\n")))
      (org-mode)
      (goto-char (point-min)))
    (pop-to-buffer buf)))

(defun ai-agent-codex--build-exec-command (prompt dir)
  "Return the `codex exec' command for PROMPT in DIR."
  (append (list codex-program)
          codex-program-switches
          (ai-agent-codex--exec-approval-args)
          (list "exec")
          (ai-agent-codex--exec-model-args)
          (ai-agent-codex--exec-profile-args)
          (ai-agent-codex--exec-sandbox-args)
          (ai-agent-codex--exec-image-args)
          (list "--cd" (expand-file-name dir)
                "--color" "never")
          (when ai-agent-codex-exec-skip-git-repo-check
            (list "--skip-git-repo-check"))
          (list prompt)))

(defun ai-agent-codex--exec-model-args ()
  "Return `codex exec' model arguments."
  (when codex-model
    (list "--model" codex-model)))

(defun ai-agent-codex--exec-profile-args ()
  "Return `codex exec' profile arguments."
  (when codex-profile
    (list "--profile" codex-profile)))

(defun ai-agent-codex--exec-sandbox-args ()
  "Return `codex exec' sandbox arguments."
  (when-let* ((mode (or ai-agent-codex-exec-sandbox-mode codex-sandbox-mode)))
    (list "--sandbox" (symbol-name mode))))

(defun ai-agent-codex--exec-approval-args ()
  "Return Codex approval-policy arguments."
  (when-let* ((policy (or ai-agent-codex-exec-approval-policy
                          codex-approval-policy)))
    (list "--ask-for-approval" (symbol-name policy))))

(defun ai-agent-codex--exec-image-args ()
  "Return `codex exec' image arguments."
  (cl-loop for image in codex-default-images
           append (list "--image" image)))

(defun ai-agent-codex--exec-process-environment (dir)
  "Return the process environment for non-interactive Codex runs in DIR."
  (let* ((buffer-name (format "*codex-exec:%s*"
                              (file-name-nondirectory
                               (directory-file-name dir))))
         (extra-env (apply #'append
                           (mapcar (lambda (func)
                                     (funcall func buffer-name dir))
                                   codex-process-environment-functions))))
    (append `(,(format "CODEX_BUFFER_NAME=%s" buffer-name))
            extra-env
            process-environment)))

(defun ai-agent-codex--run-prompt (prompt &rest kwargs)
  "Run PROMPT non-interactively via `codex exec'.
KWARGS accepts :dir and :callback.  The callback receives a plist
with :exit-code, :duration, :text, and :raw."
  (let* ((dir (or (plist-get kwargs :dir) default-directory))
         (callback (or (plist-get kwargs :callback)
                       (error "ai-agent-codex--run-prompt: :callback required")))
         (args (ai-agent-codex--build-exec-command prompt dir))
         (env (ai-agent-codex--exec-process-environment dir))
         (start-time (current-time))
         (output-buf (generate-new-buffer " *codex-exec-output*")))
    (unless (executable-find codex-program)
      (error "Codex program `%s' not found in PATH" codex-program))
    (let ((process-environment env)
          (default-directory dir))
      (make-process
       :name "codex-exec"
       :buffer output-buf
       :command args
       :sentinel
       (lambda (proc _event)
         (when (memq (process-status proc) '(exit signal))
           (let* ((exit-code (process-exit-status proc))
                  (raw (with-current-buffer (process-buffer proc)
                         (buffer-string)))
                  (duration (float-time
                             (time-subtract (current-time) start-time)))
                  (result (list :exit-code exit-code
                                :duration duration
                                :text (string-trim raw)
                                :raw raw)))
             (ignore-errors (kill-buffer (process-buffer proc)))
             (funcall callback result))))))))

;;;###autoload
(defun ai-agent-codex-run-skill (skill-name &optional arguments)
  "Run Codex skill SKILL-NAME with optional ARGUMENTS.
Runs the skill non-interactively via `codex exec'."
  (interactive
   (let* ((skills (ai-agent-codex--discover-skills))
          (_ (unless skills (user-error "No skills found")))
          (name (completing-read
                 "Skill: "
                 (mapcar (lambda (s) (plist-get s :name)) skills)
                 nil t))
          (args (read-string (format "Arguments for %s: " name))))
     (list name (unless (string-empty-p args) args))))
  (let* ((skill (ai-agent-codex--find-skill skill-name))
         (prompt (ai-agent-codex--skill-prompt skill skill-name arguments)))
    (message "Running Codex skill %s..." (ai-agent-codex--slash-invocation skill-name nil))
    (ai-agent-codex--run-prompt
     prompt
     :dir default-directory
     :callback
     (lambda (result)
       (ai-agent-codex--display-result
        (format "*Codex Skill: %s*" (string-remove-prefix "/" skill-name))
        (format "Codex %s" (ai-agent-codex--slash-invocation skill-name nil))
        result)))))

;;;;; Project audit

;;;###autoload
(defun ai-agent-codex-audit-project ()
  "Run a comprehensive audit of a project via Codex.
Sequentially runs each skill in `ai-agent-codex-audit-skills'
via `codex exec'."
  (interactive)
  (let* ((dir (ai-agent-codex--read-audit-directory))
         (skills ai-agent-codex-audit-skills))
    (when (yes-or-no-p
           (format "Run %d audit(s) on %s?" (length skills) dir))
      (ai-agent-codex--audit-run-next
       (list :queue skills
             :results nil
             :dir dir
             :start-time (current-time))))))

(defun ai-agent-codex--audit-run-next (state)
  "Run the next audit task in STATE."
  (if (null (plist-get state :queue))
      (ai-agent-codex--audit-finish state)
    (let* ((queue (plist-get state :queue))
           (skill-name (car queue))
           (skill (ai-agent-codex--find-skill skill-name))
           (prompt (ai-agent-codex--skill-prompt skill skill-name "--accept")))
      (message "Running Codex audit %s..." skill-name)
      (ai-agent-codex--run-prompt
       prompt
       :dir (plist-get state :dir)
       :callback
       (lambda (result)
         (plist-put state :results
                    (cons (append (list :skill skill-name) result)
                          (plist-get state :results)))
         (plist-put state :queue (cdr queue))
         (ai-agent-codex--audit-run-next state))))))

(defun ai-agent-codex--audit-finish (state)
  "Display the audit results from STATE."
  (let* ((results (reverse (plist-get state :results)))
         (total (length results))
         (successes (cl-count 0 results :key
                              (lambda (result)
                                (plist-get result :exit-code))))
         (failures (- total successes))
         (duration (float-time
                    (time-subtract (current-time)
                                   (plist-get state :start-time))))
         (buf (get-buffer-create "*Codex Audit Results*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "#+title: Codex audit results — %s\n\n"
                        (format-time-string "%Y-%m-%d %H:%M:%S")))
        (insert (format "- Directory: [[file:%s]]\n" (plist-get state :dir)))
        (insert (format "- Total: %d | Success: %d | Failed: %d\n" total successes failures))
        (insert (format "- Time: %.1f seconds\n\n" duration))
        (dolist (result results)
          (insert (format "* %s %s\n"
                          (if (zerop (plist-get result :exit-code)) "DONE" "FAIL")
                          (plist-get result :skill)))
          (insert (format ":PROPERTIES:\n:EXIT_CODE: %s\n:DURATION: %.1fs\n:END:\n\n"
                          (plist-get result :exit-code)
                          (plist-get result :duration)))
          (insert "#+begin_example\n")
          (insert (or (plist-get result :text) "(no output)"))
          (unless (string-suffix-p "\n" (or (plist-get result :text) ""))
            (insert "\n"))
          (insert "#+end_example\n\n")))
      (org-mode)
      (goto-char (point-min)))
    (pop-to-buffer buf)
    (message "Codex audit complete: %d/%d succeeded (%.1fs)"
             successes total duration)))

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
  (let ((backtrace-file (expand-file-name ai-agent-backtrace-file)))
    (run-with-timer 0 nil #'ai-agent-codex--debug-identify-package backtrace-file)
    (ai-agent-save-backtrace)))

(defun ai-agent-codex--debug-identify-package (backtrace-file)
  "Identify candidate packages from BACKTRACE-FILE and let the user choose."
  (unless (file-exists-p backtrace-file)
    (user-error "Backtrace file not found: %s" backtrace-file))
  (unless (and (require 'gptel nil t) (fboundp 'gptel-request))
    (user-error "Package `gptel' is required for backtrace debugging"))
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
  (let* ((dir (or (ai-agent--package-source-directory package)
                  (user-error "Package `%s' not found" package)))
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
      (ai-agent--force-kill-buffer (current-buffer)))
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
    (ai-agent--force-kill-buffer (current-buffer))
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

;;;;; Branch navigation

;;;###autoload
(defun ai-agent-codex-resume (arg)
  "Resume a previous Codex session.
With prefix ARG, use Codex CLI's `--last' flag."
  (interactive "P")
  (codex-resume arg))

;;;###autoload
(defun ai-agent-codex-fork (arg)
  "Fork a previous Codex session.
With prefix ARG, use Codex CLI's `--last' flag."
  (interactive "P")
  (codex-fork arg))

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

;;;;; Extend unified menu

(with-eval-after-load 'ai-agent
  (transient-append-suffix 'ai-agent-menu "x"
    '("R" "codex resume" ai-agent-codex-resume))
  (transient-append-suffix 'ai-agent-menu "R"
    '("F" "codex fork" ai-agent-codex-fork)))

;;;; Provide

(provide 'ai-agent-codex)
;;; ai-agent-codex.el ends here
