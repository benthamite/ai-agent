;;; agents-codex.el --- Extensions for codex -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/agents
;; Version: 0.1
;; Package-Requires: ((codex "0.1") (agents "0.1"))

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
(eval-and-compile (require 'agents))
(require 'cl-lib)
(require 'subr-x)
(require 'transient)

;;;; Variables

(defgroup agents-codex ()
  "Extensions for `codex'."
  :group 'codex)

(defcustom agents-codex-handoff-file
  (expand-file-name "codex-handoff.md" temporary-file-directory)
  "Path to the handoff file written by the handoff skill."
  :type 'file
  :group 'agents-codex)

(defcustom agents-codex-accounts nil
  "Alist of account names to Codex home directories.
Each entry is (NAME . CODEX-HOME).  When non-nil,
`agents-codex-start-or-switch' uses the persisted account
selection and sets `CODEX_HOME' accordingly so each account
maintains its own credentials while sharing the standard Codex
configuration, hooks, skills, sessions, and history from
`~/.codex/'.

Use `agents-codex-select-account' to change the active account.
The selection persists in `agents-codex-account-file'.

Example:
  \\='((\"personal\" . \"~/.codex-personal\")
    (\"work\"     . \"~/.codex-work\"))"
  :type '(alist :key-type string :value-type directory)
  :group 'agents-codex)

(defcustom agents-codex-account-file
  (expand-file-name ".codex-current-account" "~")
  "File storing the name of the currently active Codex account.
The file contains a single account name from `agents-codex-accounts'.
Written by `agents-codex-select-account', read at session start."
  :type 'file
  :group 'agents-codex)

(defcustom agents-codex-skill-directories nil
  "Additional directories to scan for Codex skills.
Searched in addition to the standard locations."
  :type '(repeat directory)
  :group 'agents-codex)

(defcustom agents-codex-programmatic-skill-directories
  (list (expand-file-name "~/.codex/programmatic-skills"))
  "Directories to scan for skills run only by `agents-run-skill'.
These directories are not loaded by ordinary Codex sessions."
  :type '(repeat directory)
  :group 'agents-codex)

(defcustom agents-codex-audit-skills
  '("/code-audit" "/design-audit" "/interpretability-audit")
  "Skills to run when performing a project audit."
  :type '(repeat string)
  :group 'agents-codex)

(defcustom agents-codex-audit-project-directories nil
  "Directories available for selection in `agents-codex-audit-project'."
  :type '(repeat directory)
  :group 'agents-codex)

(defcustom agents-codex-exec-approval-policy 'never
  "Approval policy used for non-interactive `codex exec' runs.
When nil, use `codex-approval-policy' or the CLI default."
  :type '(choice (const :tag "Codex default" nil)
                 (const :tag "Untrusted" untrusted)
                 (const :tag "On request" on-request)
                 (const :tag "Never" never))
  :group 'agents-codex)

(defcustom agents-codex-exec-sandbox-mode nil
  "Sandbox mode used for non-interactive `codex exec' runs.
When nil, use `codex-sandbox-mode' or the CLI default."
  :type '(choice (const :tag "Codex default" nil)
                 (const :tag "Read-only" read-only)
                 (const :tag "Workspace write" workspace-write)
                 (const :tag "Full access" danger-full-access))
  :group 'agents-codex)

(defcustom agents-codex-exec-skip-git-repo-check t
  "When non-nil, pass `--skip-git-repo-check' to `codex exec'."
  :type 'boolean
  :group 'agents-codex)

(defcustom agents-codex-debug-backtrace-model 'gemini-flash-lite-latest
  "GPtel model for identifying candidate packages from a backtrace."
  :type 'symbol
  :group 'agents-codex)

(defcustom agents-codex-debug-backtrace-backend "Gemini"
  "GPtel backend name for backtrace analysis."
  :type 'string
  :group 'agents-codex)

(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-use-tools)
(defvar gptel--known-backends)
(declare-function agents-svg-icon "agents" (svg-data &optional face))
(declare-function gptel-request "gptel")

(defvar agents-codex--current-account nil
  "Currently active Codex account name.
Loaded from `agents-codex-account-file' on first use;
changed by `agents-codex-select-account'.")

(defvar agents-codex--pending-account nil
  "Account name for the current `codex' invocation.
Dynamically bound by `agents-codex--start-with-account';
read by `agents-codex-account-env'.")

(defvar-local agents-codex--buffer-account nil
  "Account name that was active when this buffer's session started.
Set by `agents-codex--capture-buffer-account' via
`codex-start-hook'.")

(defconst agents-codex--shared-config-items
  '("config.toml" "hooks.json" "AGENTS.md" "rules"
    "skills" "programmatic-skills" "plugins" "vendor_imports"
    "history.jsonl" "sessions" "session_index.jsonl"
    "archived_sessions" "memories" "shell_snapshots"
    ".codex-global-state.json")
  "Files and directories symlinked from `~/.codex/' into each account home.
These items are shared across accounts so hooks, skills, project
trust, memories, session history, and other user-facing Codex
state remain available regardless of which account is active.
Only account credentials such as `auth.json' remain account-local.")

;;;; Backend registration

(defconst agents-codex-icon-svg
  "<svg fill=\"currentColor\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z\"/></svg>"
  "SVG path data for the OpenAI logo (knot icon).
Source: SVG Repo (CC0).")

(agents-register-backend 'codex
  (list :buffer-p #'codex--buffer-p
        :find-all-buffers #'codex--find-all-codex-buffers
        :find-buffers-for-dir #'codex--find-codex-buffers-for-directory
        :directory (lambda (buf) (with-current-buffer buf (codex--directory)))
        :extract-directory #'codex--extract-directory-from-buffer-name
        :extract-instance-name #'codex--extract-instance-name-from-buffer-name
        :send-command #'agents-codex-send-command
        :send-return #'agents-codex-send-return
        :start #'codex--start
        :start-new #'agents-codex--start-with-account
        :program "codex"
        :icon (lambda (&optional face) (let ((svg (agents-svg-icon agents-codex-icon-svg face)))
                                        (if (string-empty-p svg) "CX" svg)))
        :account (lambda (buf)
                   (buffer-local-value 'agents-codex--buffer-account buf))
        :label "Codex"
        :discover-skills #'agents-codex--discover-skills
        :handoff #'agents-codex-handoff
        :run-skill #'agents-codex-run-skill
        :audit-project #'agents-codex-audit-project
        :debug-backtrace #'agents-codex-debug-backtrace
        :setup-kill-on-exit #'agents-codex-setup-kill-on-exit
        :exit #'agents-codex-exit
        :restart #'agents-codex-restart
        :sync-theme #'agents-codex--sync-theme))

;;;; Functions

(defun agents-codex-send-command (cmd &optional buffer)
  "Insert CMD into BUFFER's Codex prompt without submitting it."
  (when-let* ((codex-buffer (agents-codex--target-buffer buffer)))
    (with-current-buffer codex-buffer
      (codex--term-send-string codex-terminal-backend cmd)
      (display-buffer codex-buffer))
    codex-buffer))

(defun agents-codex-send-return (&optional buffer)
  "Submit the active prompt in BUFFER's Codex session."
  (when-let* ((codex-buffer (agents-codex--target-buffer buffer)))
    (with-current-buffer codex-buffer
      (codex--term-send-action codex-terminal-backend :return)
      (display-buffer codex-buffer))
    codex-buffer))

(defun agents-codex--target-buffer (buffer)
  "Return BUFFER when live, otherwise prompt for a Codex buffer."
  (if (buffer-live-p buffer)
      buffer
    (codex--get-or-prompt-for-buffer)))

;;;;; Account selection

(defun agents-codex-account-env (_buffer-name _dir)
  "Return environment variables for the session being started.
Sets `CODEX_HOME' based on `agents-codex-accounts'.  Prefers
the dynamically bound `agents-codex--pending-account' and falls
back to the persisted active account via
`agents-codex--resolve-account', so callers that invoke
`codex--start' directly still get the right account."
  (when-let* ((account (or agents-codex--pending-account
                           (agents-codex--resolve-account)))
              (home (agents-codex--account-home account)))
    (agents-codex--sync-account-home account)
    (list (format "CODEX_HOME=%s" home))))

(defun agents-codex--account-home (account)
  "Return the expanded Codex home directory for ACCOUNT, or nil."
  (when-let* ((home (alist-get account agents-codex-accounts
                               nil nil #'string=)))
    (expand-file-name home)))

(defun agents-codex--config-file (&optional account)
  "Return the config.toml path for ACCOUNT or the default Codex config."
  (if-let* ((home (and account (agents-codex--account-home account))))
      (expand-file-name "config.toml" home)
    (expand-file-name codex-hooks-config-path)))

(defun agents-codex--sync-account-home (account)
  "Sync shared Codex state into ACCOUNT's home directory."
  (when-let* ((home (agents-codex--account-home account)))
    (make-directory home t)
    (condition-case err
        (agents-codex--ensure-shared-symlinks home)
      (error
       (message "agents-codex: failed to sync account home: %S" err)))))

(defun agents-codex--ensure-shared-symlinks (home)
  "Ensure shared config symlinks exist in account HOME."
  (let ((canonical-home (expand-file-name ".codex/" "~")))
    (dolist (item agents-codex--shared-config-items)
      (agents-codex--ensure-shared-symlink
       (expand-file-name item canonical-home)
       (expand-file-name item home)))))

(defun agents-codex--ensure-shared-symlink (source target)
  "Ensure TARGET is a symlink pointing to SOURCE.
Create the symlink if TARGET is missing, replace TARGET if it is a
virgin-state file or empty directory, and back up TARGET before
replacing it if it has real content."
  (when (file-exists-p source)
    (cond
     ((file-symlink-p target)
      (unless (equal (file-truename target) (file-truename source))
        (agents-codex--backup-item target)
        (make-symbolic-link source target)
        (message "agents-codex: replaced %s with symlink to %s"
                 target source)))
     ((not (file-exists-p target))
      (make-symbolic-link source target)
      (message "agents-codex: symlinked %s -> %s" target source))
     ((agents-codex--item-virgin-p target)
      (agents-codex--delete-item target)
      (make-symbolic-link source target)
      (message "agents-codex: replaced virgin %s with symlink to %s"
               target source))
     (t
      (agents-codex--backup-item target)
      (make-symbolic-link source target)
      (message "agents-codex: backed up and symlinked %s -> %s"
               target source)))))

(defun agents-codex--item-virgin-p (path)
  "Return non-nil if PATH is a virgin-state file or empty directory.
An empty directory is virgin.  A zero-byte file is virgin.  A small
JSON file containing only `{}' or `[]' is virgin."
  (cond
   ((file-directory-p path)
    (null (directory-files path nil directory-files-no-dot-files-regexp)))
   ((file-regular-p path)
    (agents-codex--file-virgin-p path))))

(defun agents-codex--file-virgin-p (path)
  "Return non-nil if regular file PATH has empty or placeholder content."
  (let ((size (file-attribute-size (file-attributes path))))
    (or (zerop size)
        (and (< size 16)
             (member (string-trim
                      (with-temp-buffer
                        (insert-file-contents path)
                        (buffer-string)))
                     '("" "{}" "[]"))))))

(defun agents-codex--delete-item (path)
  "Delete PATH, whether it is a file or a directory."
  (if (file-directory-p path)
      (delete-directory path t)
    (delete-file path)))

(defun agents-codex--backup-item (path)
  "Move PATH to a timestamped backup path."
  (let* ((timestamp (format-time-string "%Y%m%d%H%M%S"))
         (backup (format "%s.agents-backup-%s" path timestamp))
         (candidate backup)
         (counter 0))
    (while (file-exists-p candidate)
      (setq counter (1+ counter)
            candidate (format "%s.%d" backup counter)))
    (rename-file path candidate)
    (message "agents-codex: backed up %s to %s" path candidate)))

(defun agents-codex--load-account ()
  "Load the current account from `agents-codex-account-file'.
Return the account name, or nil if the file is missing or stale."
  (when (file-exists-p agents-codex-account-file)
    (let ((name (string-trim
                 (with-temp-buffer
                   (insert-file-contents agents-codex-account-file)
                   (buffer-string)))))
      (when (alist-get name agents-codex-accounts nil nil #'string=)
        name))))

(defun agents-codex--save-account (name)
  "Persist NAME as the active account to `agents-codex-account-file'."
  (with-temp-file agents-codex-account-file
    (insert name "\n"))
  (setq agents-codex--current-account name))

(defun agents-codex--prompt-account ()
  "Prompt for an account from `agents-codex-accounts'.
Return the account name, or nil."
  (when agents-codex-accounts
    (let ((names (mapcar #'car agents-codex-accounts)))
      (if (= (length names) 1)
          (car names)
        (completing-read "Account: " names nil t)))))

(defun agents-codex--resolve-account ()
  "Return the active account, loading from disk or prompting as needed.
On first use, loads from `agents-codex-account-file'.  If no
persisted account exists, prompts once and saves the selection."
  (when agents-codex-accounts
    (unless agents-codex--current-account
      (setq agents-codex--current-account
            (agents-codex--load-account)))
    (or agents-codex--current-account
        (let ((account (agents-codex--prompt-account)))
          (when account
            (agents-codex--save-account account))
          account))))

;;;###autoload
(defun agents-codex-select-account ()
  "Switch the active Codex account.
Prompts for an account from `agents-codex-accounts' and
persists the selection.  New sessions will use this account."
  (interactive)
  (unless agents-codex-accounts
    (user-error "No accounts configured in `agents-codex-accounts'"))
  (let ((account (agents-codex--prompt-account)))
    (when account
      (agents-codex--save-account account)
      (message "Switched to account: %s" account))))

(defun agents-codex--start-with-account ()
  "Start a new Codex session using the active account."
  (interactive)
  (let* ((account (agents-codex--resolve-account))
         (agents-codex--pending-account account))
    (codex)))

(defun agents-codex--capture-buffer-account ()
  "Store the account name as a buffer-local variable."
  (setq agents-codex--buffer-account
        (or agents-codex--pending-account
            (agents-codex--resolve-account))))

(defun agents-codex-buffer-account ()
  "Return the account name for the current buffer, or nil."
  agents-codex--buffer-account)

;;;;; Mode line

(declare-function doom-modeline-set-modeline "doom-modeline-core")

(defvar-local agents-codex--start-time nil
  "Time when this Codex session started.")

(defvar agents-codex--config-model-cache nil
  "Cached model lookup as (CONFIG MTIME . MODEL) for Codex config.")

(defun agents-codex--parse-config-model (config-file)
  "Return the model string declared in CONFIG-FILE, or nil."
  (with-temp-buffer
    (insert-file-contents config-file)
    (goto-char (point-min))
    (when (re-search-forward "^model *= *\"\\([^\"]+\\)\"" nil t)
      (match-string 1))))

(defun agents-codex--read-config-model (&optional account)
  "Read the model from ACCOUNT's Codex config.
Cached by file modification time so the doom-modeline ai-session
segment does not perform disk I/O on every redisplay."
  (let* ((config-file (agents-codex--config-file account))
         (mtime (file-attribute-modification-time
                 (file-attributes config-file))))
    (cond
     ((null mtime) nil)
     ((and agents-codex--config-model-cache
           (equal config-file (nth 0 agents-codex--config-model-cache))
           (equal mtime (nth 1 agents-codex--config-model-cache)))
      (nth 2 agents-codex--config-model-cache))
     (t
      (let ((model (agents-codex--parse-config-model config-file)))
        (setq agents-codex--config-model-cache
              (list config-file mtime model))
        model)))))

(defun agents-codex-set-modeline ()
  "Set the doom-modeline to the `ai-session' modeline for this buffer.
Also records the session start time."
  (when (codex--buffer-p (current-buffer))
    (setq agents-codex--start-time (current-time))
    (when (require 'doom-modeline-core nil t)
      (doom-modeline-set-modeline 'ai-session))))

(defun agents-codex-status-model ()
  "Return the model name for the current Codex session."
  (agents-codex--read-config-model agents-codex--buffer-account))

(defun agents-codex-status-duration-ms ()
  "Return session duration in milliseconds, or nil."
  (when agents-codex--start-time
    (truncate (* 1000 (float-time
                       (time-subtract (current-time)
                                      agents-codex--start-time))))))

;;;;; Theme sync

(defun agents-codex--sync-theme (theme)
  "Update Codex persistent theme configuration to THEME.
THEME is either \"light\" or \"dark\".  Return non-nil when the
config file changed."
  (agents-codex--sync-theme-to-config theme))

(defun agents-codex--sync-theme-to-config (&optional theme)
  "Update `tui.theme' in the active Codex config to THEME.
When THEME is nil, use the current Emacs AI theme.  Only writes
the file when the theme value actually changes."
  (let* ((theme (or theme (agents--theme)))
         (account (or agents-codex--pending-account
                      agents-codex--buffer-account))
         (_ (when account
              (agents-codex--sync-account-home account)))
         (config-file (agents-codex--config-file account))
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

(defun agents-codex--sync-theme-before-start (&rest _)
  "Persist the shared AI theme before starting a Codex process."
  (agents-sync-theme-now)
  nil)

;;;;; Notification handling

(defun agents-codex--handle-notification (message)
  "Handle a notification event from Codex CLI.
MESSAGE is a plist with :type, :buffer-name, :json-data, and :args.
The :type field is a string from the hook wrapper (e.g. \"Stop\")."
  (let ((hook-type (plist-get message :type)))
    (when (member hook-type '("Stop" "Notification" "SessionStart"))
      (when-let* ((buf (get-buffer (plist-get message :buffer-name))))
        (with-current-buffer buf
          (let ((name (agents--session-name (buffer-name))))
            (pcase hook-type
              ("Stop"
               (setq agents--waiting-for-input (current-time))
               (agents-notify
                "Codex ready"
                (format "%s: waiting for your response" name))
               (agents--scroll-to-bottom buf))
              ("Notification"
               (agents-notify
                "Codex"
                (format "%s: needs your attention" name)))))))))
  nil)

;;;;; Skill runner

(defun agents-codex--discover-skills ()
  "Discover available Codex skills.
Scans the standard Codex skill directories, project-local skill
directories, and any custom ones from
`agents-codex-skill-directories' and
`agents-codex-programmatic-skill-directories'."
  (let* ((skills (make-hash-table :test #'equal))
         (project-root (or (when-let* ((proj (project-current)))
                             (project-root proj))
                           (locate-dominating-file default-directory ".codex")
                           (locate-dominating-file default-directory ".git")))
         (dirs (append
                ;; Standard Codex skill locations
                (list (expand-file-name "skills"
                                        (or (getenv "CODEX_HOME") "~/.codex")))
                ;; Project-local
                (when project-root
                  (list (expand-file-name ".agents/skills" project-root)
                        (expand-file-name ".codex/skills" project-root)
                        (expand-file-name ".codex/programmatic-skills"
                                          project-root)))
                ;; Custom
                agents-codex-skill-directories
                agents-codex-programmatic-skill-directories)))
    (dolist (dir dirs)
      (when (file-directory-p dir)
        (dolist (file (file-expand-wildcards
                       (expand-file-name "*/SKILL.md" dir)))
          (when-let* ((meta (agents-codex--parse-skill-frontmatter file))
                      (name (plist-get meta :name)))
            (unless (and (plist-member meta :user-invocable)
                         (not (plist-get meta :user-invocable)))
              (puthash name (append meta (list :path file :source dir))
                       skills))))))
    (let (result)
      (maphash (lambda (_name skill) (push skill result)) skills)
      (sort result (lambda (a b)
                     (string< (plist-get a :name) (plist-get b :name)))))))

(defun agents-codex--parse-skill-frontmatter (file)
  "Parse YAML frontmatter from skill FILE and return a plist."
  (agents-parse-skill-frontmatter file))

(defun agents-codex--find-skill (skill-name)
  "Return discovered metadata for SKILL-NAME, or nil."
  (let ((name (string-remove-prefix "/" skill-name)))
    (cl-find name (agents-codex--discover-skills)
             :key (lambda (skill) (plist-get skill :name))
             :test #'equal)))

(defun agents-codex--skill-prompt (skill skill-name arguments)
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
    (agents-codex--slash-invocation skill-name arguments)))

(defun agents-codex--slash-invocation (skill-name arguments)
  "Return a Codex slash invocation for SKILL-NAME and ARGUMENTS."
  (let ((command (if (string-prefix-p "/" skill-name)
                     skill-name
                   (concat "/" skill-name))))
    (if (and arguments (not (string-empty-p arguments)))
        (format "%s %s" command arguments)
      command)))

(defun agents-codex--display-result (buffer-name title result)
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

(defun agents-codex--build-exec-command (prompt dir)
  "Return the `codex exec' command for PROMPT in DIR."
  (append (list codex-program)
          codex-program-switches
          (agents-codex--exec-approval-args)
          (list "exec")
          (agents-codex--exec-model-args)
          (agents-codex--exec-profile-args)
          (agents-codex--exec-sandbox-args)
          (agents-codex--exec-image-args)
          (list "--cd" (expand-file-name dir)
                "--color" "never")
          (when agents-codex-exec-skip-git-repo-check
            (list "--skip-git-repo-check"))
          (list prompt)))

(defun agents-codex--exec-model-args ()
  "Return `codex exec' model arguments."
  (when codex-model
    (list "--model" codex-model)))

(defun agents-codex--exec-profile-args ()
  "Return `codex exec' profile arguments."
  (when codex-profile
    (list "--profile" codex-profile)))

(defun agents-codex--exec-sandbox-args ()
  "Return `codex exec' sandbox arguments."
  (when-let* ((mode (or agents-codex-exec-sandbox-mode codex-sandbox-mode)))
    (list "--sandbox" (symbol-name mode))))

(defun agents-codex--exec-approval-args ()
  "Return Codex approval-policy arguments."
  (when-let* ((policy (or agents-codex-exec-approval-policy
                          codex-approval-policy)))
    (list "--ask-for-approval" (symbol-name policy))))

(defun agents-codex--exec-image-args ()
  "Return `codex exec' image arguments."
  (cl-loop for image in codex-default-images
           append (list "--image" image)))

(defun agents-codex--exec-process-environment (dir)
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

(defun agents-codex--run-prompt (prompt &rest kwargs)
  "Run PROMPT non-interactively via `codex exec'.
KWARGS accepts :dir and :callback.  The callback receives a plist
with :exit-code, :duration, :text, and :raw."
  (let* ((dir (or (plist-get kwargs :dir) default-directory))
         (callback (or (plist-get kwargs :callback)
                       (error "agents-codex--run-prompt: :callback required")))
         (args (agents-codex--build-exec-command prompt dir))
         (env (agents-codex--exec-process-environment dir))
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
(defun agents-codex-run-skill (skill-name &optional arguments)
  "Run Codex skill SKILL-NAME with optional ARGUMENTS.
Runs the skill non-interactively via `codex exec'."
  (interactive
   (let* ((skills (agents-codex--discover-skills))
          (_ (unless skills (user-error "No skills found")))
          (name (completing-read
                 "Skill: "
                 (mapcar (lambda (s) (plist-get s :name)) skills)
                 nil t))
          (args (read-string (format "Arguments for %s: " name))))
     (list name (unless (string-empty-p args) args))))
  (let* ((skill (agents-codex--find-skill skill-name))
         (prompt (agents-codex--skill-prompt skill skill-name arguments)))
    (message "Running Codex skill %s..." (agents-codex--slash-invocation skill-name nil))
    (agents-codex--run-prompt
     prompt
     :dir default-directory
     :callback
     (lambda (result)
       (agents-codex--display-result
        (format "*Codex Skill: %s*" (string-remove-prefix "/" skill-name))
        (format "Codex %s" (agents-codex--slash-invocation skill-name nil))
        result)))))

;;;;; Project audit

;;;###autoload
(defun agents-codex-audit-project ()
  "Run a comprehensive audit of a project via Codex.
Sequentially runs each skill in `agents-codex-audit-skills'
via `codex exec'."
  (interactive)
  (let* ((dir (agents-codex--read-audit-directory))
         (skills agents-codex-audit-skills))
    (when (yes-or-no-p
           (format "Run %d audit(s) on %s?" (length skills) dir))
      (agents-codex--audit-run-next
       (list :queue skills
             :results nil
             :dir dir
             :start-time (current-time))))))

(defun agents-codex--audit-run-next (state)
  "Run the next audit task in STATE."
  (if (null (plist-get state :queue))
      (agents-codex--audit-finish state)
    (let* ((queue (plist-get state :queue))
           (skill-name (car queue))
           (skill (agents-codex--find-skill skill-name))
           (prompt (agents-codex--skill-prompt skill skill-name "--accept")))
      (message "Running Codex audit %s..." skill-name)
      (agents-codex--run-prompt
       prompt
       :dir (plist-get state :dir)
       :callback
       (lambda (result)
         (plist-put state :results
                    (cons (append (list :skill skill-name) result)
                          (plist-get state :results)))
         (plist-put state :queue (cdr queue))
         (agents-codex--audit-run-next state))))))

(defun agents-codex--audit-finish (state)
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

(defun agents-codex--read-audit-directory ()
  "Prompt for a project directory with completion."
  (let* ((candidates (mapcar #'abbreviate-file-name
                             agents-codex-audit-project-directories))
         (input (completing-read "Project directory: " candidates nil nil))
         (dir (file-truename (expand-file-name input))))
    (unless (file-directory-p dir)
      (user-error "Not a directory: %s" dir))
    (unless (member dir (mapcar #'file-truename
                                agents-codex-audit-project-directories))
      (customize-save-variable 'agents-codex-audit-project-directories
                               (append agents-codex-audit-project-directories
                                       (list dir))))
    dir))

;;;;; Debug backtrace

;;;###autoload
(defun agents-codex-debug-backtrace ()
  "Save the backtrace, identify the offending package, and open Codex."
  (interactive)
  (let ((backtrace-file (expand-file-name agents-backtrace-file)))
    (run-with-timer 0 nil #'agents-codex--debug-identify-package backtrace-file)
    (agents-save-backtrace)))

(defun agents-codex--debug-identify-package (backtrace-file)
  "Identify candidate packages from BACKTRACE-FILE and let the user choose."
  (unless (file-exists-p backtrace-file)
    (user-error "Backtrace file not found: %s" backtrace-file))
  (unless (and (require 'gptel nil t) (fboundp 'gptel-request))
    (user-error "Package `gptel' is required for backtrace debugging"))
  (message "Identifying packages from backtrace...")
  (let ((contents (with-temp-buffer
                    (insert-file-contents backtrace-file)
                    (buffer-string)))
        (gptel-backend (alist-get agents-codex-debug-backtrace-backend
                                 gptel--known-backends nil nil #'string=))
        (gptel-model agents-codex-debug-backtrace-model)
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
           (agents-codex--debug-start-session
            (intern selected) backtrace-file)))))))

(defun agents-codex--debug-start-session (package backtrace-file)
  "Start a Codex session for PACKAGE with BACKTRACE-FILE."
  (let* ((dir (or (agents--package-source-directory package)
                  (user-error "Package `%s' not found" package)))
         (prompt (format "Read the backtrace at %s. Identify the bug, fix it, and commit the fix."
                         backtrace-file)))
    (message "Starting Codex for `%s' in %s..." package dir)
    (cl-letf (((symbol-function 'codex--directory) (lambda () dir)))
      (codex--start nil (list prompt) nil t))))

;;;;; Handoff

;;;###autoload
(defun agents-codex-handoff (&optional buffer-name)
  "Close this Codex session and start a new one with the handoff prompt."
  (interactive)
  (unless (file-exists-p agents-codex-handoff-file)
    (user-error "No handoff file at %s — run /handoff first"
                agents-codex-handoff-file))
  (let* ((prompt (with-temp-buffer
                   (insert-file-contents agents-codex-handoff-file)
                   (string-trim (buffer-string))))
         (source-buffer (agents-codex--handoff-source-buffer buffer-name))
         (account (when source-buffer
                    (buffer-local-value 'agents-codex--buffer-account
                                        source-buffer)))
         (dir (agents-codex--handoff-directory source-buffer)))
    (when (string-empty-p prompt)
      (user-error "Handoff file is empty"))
    (when source-buffer
      (agents--force-kill-buffer source-buffer))
    (let ((agents-codex--pending-account
           (or account (agents-codex--resolve-account))))
      (cl-letf (((symbol-function 'codex--directory) (lambda () dir)))
        (codex--start nil (list prompt) nil t)))))

(defun agents-codex-handoff-from-emacsclient ()
  "Run `agents-codex-handoff' for the client-provided buffer name.
The first value in `server-eval-args-left' is treated as the Codex
buffer that requested the handoff."
  (interactive)
  (let ((buffer-name (car server-eval-args-left)))
    (setq server-eval-args-left nil)
    (agents-codex-handoff buffer-name)))

(defun agents-codex--handoff-source-buffer (buffer-name)
  "Return the Codex source buffer named BUFFER-NAME, or current buffer."
  (cond
   ((and buffer-name (not (string-empty-p buffer-name)))
    (let ((buffer (get-buffer buffer-name)))
      (unless buffer
        (user-error "No Codex session buffer named `%s'" buffer-name))
      (unless (codex--buffer-p buffer)
        (user-error "Buffer `%s' is not a Codex session" buffer-name))
      buffer))
   ((codex--buffer-p (current-buffer))
    (current-buffer))))

(defun agents-codex--handoff-directory (source-buffer)
  "Return the project directory for SOURCE-BUFFER or fallback context."
  (if source-buffer
      (buffer-local-value 'default-directory source-buffer)
    (codex--directory)))

;;;;; Restart

;;;###autoload
(defun agents-codex-restart ()
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
        (account agents-codex--buffer-account)
        (instance-name (codex--extract-instance-name-from-buffer-name
                        (buffer-name))))
    (agents--force-kill-buffer (current-buffer))
    (let ((agents-codex--pending-account
           (or account (agents-codex--resolve-account))))
      (cl-letf (((symbol-function 'codex--directory) (lambda () dir)))
        (codex--start-subcommand "resume" t nil instance-name)))))

;;;;; Start or switch (Codex-specific entry point)

;;;###autoload
(defun agents-codex-start-or-switch ()
  "Start a new Codex session or switch to an existing one.
If no Codex sessions exist, start a new one.  Otherwise, show the
unified session switcher."
  (interactive)
  (if (null (codex--find-all-codex-buffers))
      (agents-codex--start-with-account)
    (agents--ensure-all-session-keys)
    (transient-setup 'agents--session-switcher)))

;;;;; Branch navigation

;;;###autoload
(defun agents-codex-resume (arg)
  "Resume a previous Codex session.
With prefix ARG, use Codex CLI's `--last' flag."
  (interactive "P")
  (codex-resume arg))

;;;###autoload
(defun agents-codex-fork (arg)
  "Fork a previous Codex session.
With prefix ARG, use Codex CLI's `--last' flag."
  (interactive "P")
  (codex-fork arg))

;;;; Hooks

(add-hook 'codex-event-hook #'agents-codex--handle-notification)
(add-hook 'kill-buffer-query-functions #'agents-protect-buffer)
(add-hook 'codex-start-hook #'agents--assign-session-key)
(add-hook 'codex-start-hook #'agents--refresh-display-names)
(add-hook 'codex-start-hook #'agents-disable-scrollback-truncation)
(add-hook 'codex-start-hook #'agents-setup-snippet-keys)
(add-hook 'codex-start-hook #'agents-fix-rendering)
(add-hook 'codex-start-hook #'agents-codex--capture-buffer-account)
(add-hook 'codex-start-hook #'agents-codex-set-modeline)
(add-hook 'codex-process-environment-functions
          #'agents-codex-account-env)
(add-hook 'codex-process-environment-functions
          #'agents-codex--sync-theme-before-start)
(add-hook 'kill-buffer-hook #'agents--release-session-key)
(add-hook 'kill-buffer-hook #'agents--refresh-display-names-deferred)
(advice-add 'codex--do-send-command :before
            #'agents--clear-waiting-for-input)

;;;;; Exit and kill on exit

;;;###autoload
(defun agents-codex-exit ()
  "Exit the current Codex session and kill its buffer.
Codex CLI does not support `/exit', so this sends the process a
SIGHUP and kills the buffer from the Emacs side."
  (interactive)
  (agents-kill-session-buffer))

(defun agents-codex--intercept-exit (orig-fn cmd)
  "Intercept `/exit' and kill the session instead of forwarding it.
ORIG-FN is `codex--do-send-command'.  CMD is the command string.
Codex CLI does not recognize `/exit', so we handle it on the
Emacs side to match Claude Code's behavior."
  (if (string= (string-trim cmd) "/exit")
      (when-let* ((buf (codex--get-or-prompt-for-buffer)))
        (with-current-buffer buf
          (agents-codex-exit)))
    (funcall orig-fn cmd)))

(defun agents-codex-setup-kill-on-exit ()
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

(add-hook 'codex-start-hook #'agents-codex-setup-kill-on-exit)
(advice-add 'codex--do-send-command :around #'agents-codex--intercept-exit)

;;;;; Account menu infix

(eval-and-compile
  (defclass agents-codex--account-variable (transient-lisp-variable)
    ()
    "An infix that displays and selects the active Codex account."))

(cl-defmethod transient-infix-read ((_obj agents-codex--account-variable))
  "Prompt for a Codex account."
  (agents-codex--prompt-account))

(cl-defmethod transient-infix-set ((obj agents-codex--account-variable) value)
  "Set the account variable and persist VALUE to disk."
  (set (oref obj variable) value)
  (when value
    (agents-codex--save-account value)))

(cl-defmethod transient-init-value ((obj agents-codex--account-variable))
  "Initialize Codex account infix from persisted state."
  (unless (oref obj value)
    (set (oref obj variable) (agents-codex--load-account)))
  (cl-call-next-method obj))

(transient-define-infix agents-codex--infix-account ()
  "Select the active Codex account."
  :class 'agents-codex--account-variable
  :variable 'agents-codex--current-account
  :description "codex account")

;;;;; Extend unified menu

(defun agents-codex--remove-menu-suffixes ()
  "Remove Codex menu suffixes before appending them.
`transient-append-suffix' mutates the prefix definition, so
reloading this file can otherwise leave stale or duplicate
entries in `agents-menu'."
  (dolist (command '(agents-codex-resume
                     agents-codex-fork
                     agents-codex--infix-account))
    (while (ignore-errors
             (transient-get-suffix 'agents-menu command)
             t)
      (transient-remove-suffix 'agents-menu command))))

(defun agents-codex--account-menu-location ()
  "Return the menu location after which to insert the Codex account infix."
  (if (ignore-errors
        (transient-get-suffix 'agents-menu
                              'agents-claude--infix-account)
        t)
      'agents-claude--infix-account
    "-t"))

(defun agents-codex--append-menu-suffixes ()
  "Append Codex suffixes to `agents-menu' in a stable order."
  (agents-codex--remove-menu-suffixes)
  (transient-append-suffix 'agents-menu "x"
    '("R" "codex resume" agents-codex-resume))
  (transient-append-suffix 'agents-menu "R"
    '("F" "codex fork" agents-codex-fork))
  (transient-append-suffix 'agents-menu
    (agents-codex--account-menu-location)
    '("-x" agents-codex--infix-account)))

(with-eval-after-load 'agents
  (agents-codex--append-menu-suffixes))

(with-eval-after-load 'agents-claude
  (agents-codex--append-menu-suffixes))

;;;; Provide

(provide 'agents-codex)
;;; agents-codex.el ends here
