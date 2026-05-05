;;; ai-agent-claude.el --- Extensions for claude-code -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/ai-agent
;; Version: 0.1
;; Package-Requires: ((claude-code "0.1") (consult "1.0") (paths "0.1") (ai-agent "0.1") (agent-log "0.1"))

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

;; Extensions for `claude-code'.

;;; Code:

(require 'claude-code)
(eval-and-compile (require 'ai-agent))
(require 'consult)
(require 'paths)
(require 'subr-x)
(require 'transient)

;;;; Variables

(defgroup ai-agent-claude ()
  "Extensions for `claude-code'."
  :group 'claude-code)

(defcustom ai-agent-claude-warn-kill-with-branches t
  "When non-nil, warn before killing a session that has branches.
If the session being killed is the root of a branch tree with
more than one member, a second confirmation prompt is shown after
the standard kill-protection prompt."
  :type 'boolean
  :group 'ai-agent-claude)

(defcustom ai-agent-claude-fork-worktree-directory
  (expand-file-name "claude-worktrees"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name ".cache" "~")))
  "Base directory for git worktrees created by `ai-agent-claude-create-branch'.
Each forked session gets a sibling worktree under this directory,
isolating its filesystem and git state from the parent session.
Defaults to a location outside Google Drive to avoid sync
interference with concurrent git operations."
  :type 'directory
  :group 'ai-agent-claude)

(defcustom ai-agent-claude-log-directory
  (expand-file-name "claude-logs" paths-dir-notes)
  "Directory where Claude conversation logs are saved."
  :type 'directory
  :group 'ai-agent-claude)

(defcustom ai-agent-claude-status-interval 5
  "Interval in seconds between status file polls."
  :type 'integer
  :group 'ai-agent-claude)

(defcustom ai-agent-claude-usage-interval 300
  "Base interval in seconds between usage API polls.
Fetches 5-hour session and 7-day weekly utilization from the API.
On HTTP 429 responses the interval doubles, up to
`ai-agent-claude-usage-max-interval'; it resets on success."
  :type 'integer
  :group 'ai-agent-claude)

(defcustom ai-agent-claude-usage-max-interval 900
  "Maximum polling interval in seconds after repeated 429 backoffs."
  :type 'integer
  :group 'ai-agent-claude)

(defcustom ai-agent-claude-copilot-enabled nil
  "When non-nil, enable `copilot-mode' in Claude Code buffers.
Copilot's ghost-text prose completions are shown while typing
prompts and accepted text is sent to the terminal correctly."
  :type 'boolean
  :group 'ai-agent-claude)

(defcustom ai-agent-claude-accounts nil
  "Alist of account names to `CLAUDE_CONFIG_DIR' paths.
Each entry is (NAME . CONFIG-DIR).  When non-nil,
`ai-agent-claude-start-or-switch' uses the persisted account
selection and sets `CLAUDE_CONFIG_DIR' accordingly so each account
maintains its own OAuth credentials.

Use `ai-agent-claude-select-account' to change the active account.
The selection persists in `ai-agent-claude-account-file'.

Example:
  \\='((\"personal\" . \"~/.claude-personal\")
    (\"epoch\"    . \"~/.claude-epoch\"))"
  :type '(alist :key-type string :value-type directory)
  :group 'ai-agent-claude)

(defcustom ai-agent-claude-account-file
  (expand-file-name ".claude-current-account" "~")
  "File storing the name of the currently active Claude account.
The file contains a single account name from `ai-agent-claude-accounts'.
Written by `ai-agent-claude-select-account', read at session start."
  :type 'file
  :group 'ai-agent-claude)

(defface ai-agent-claude-waiting
  '((t :inherit warning))
  "Face for sessions waiting for user input in the session switcher."
  :group 'ai-agent-claude)

(defvar ai-agent-claude--current-account nil
  "Currently active Claude account name.
Loaded from `ai-agent-claude-account-file' on first use;
changed by `ai-agent-claude-select-account'.")

(defvar ai-agent-claude--pending-account nil
  "Account name for the current `claude-code' invocation.
Dynamically bound by `ai-agent-claude--start-with-account';
read by `ai-agent-claude-account-env'.")

(defvar-local ai-agent-claude--buffer-account nil
  "Account name that was active when this buffer's session started.
Set by `ai-agent-claude--capture-buffer-account' via
`claude-code-start-hook'.")

(defcustom ai-agent-claude-settings-file
  (expand-file-name "settings.json" "~/.claude/")
  "Claude Code settings file updated by setup commands."
  :type 'file
  :group 'ai-agent-claude)

(defcustom ai-agent-claude-hook-wrapper
  (when-let* ((library (locate-library "claude-code")))
    (expand-file-name "bin/claude-code-hook-wrapper"
                      (file-name-directory library)))
  "Absolute path to the claude-code hook wrapper script."
  :type '(choice (const :tag "Unavailable" nil) file)
  :group 'ai-agent-claude)

(defconst ai-agent-claude--hooks-directory
  (file-truename
   (expand-file-name "hooks/"
                     (file-name-directory
                      (file-truename
                       (or load-file-name buffer-file-name)))))
  "Absolute path to the bundled Claude hook helper directory.")

(defcustom ai-agent-claude-status-directory
  (expand-file-name "claude-code-status/" temporary-file-directory)
  "Directory where the statusline script writes JSON status files."
  :type 'directory
  :group 'ai-agent-claude)

(defcustom ai-agent-claude-statusline-script
  (expand-file-name "etc/claude-code-statusline.sh"
                    (file-name-directory
                     (file-truename
                      (or load-file-name buffer-file-name))))
  "Absolute path to the bundled Claude Code statusline script."
  :type 'file
  :group 'ai-agent-claude)

(defvar-local ai-agent-claude--status-data nil
  "Parsed status plist for the current Claude buffer.")

(defvar-local ai-agent-claude--display-name-cache nil
  "Cached display name for the modeline.
Updated by `ai-agent--refresh-display-names'.")

(defvar-local ai-agent-claude--original-session-id nil
  "Session ID when this buffer was first created.
Used to detect when `/branch' creates a new session.")

;; Home-row keys and session key map are now managed by ai-agent.
(defvar ai-agent-claude--session-keys ai-agent--session-keys
  "Alias for `ai-agent--session-keys' for backward compatibility.")
(defconst ai-agent-claude--home-row-keys ai-agent--home-row-keys
  "Alias for `ai-agent--home-row-keys'.")

(defvar-local ai-agent-claude--status-timer nil
  "Timer for periodic status polling in the current Claude buffer.")

(defvar ai-agent-claude--usage-data (make-hash-table :test #'equal)
  "Hash table mapping account names to parsed usage plists.")

(defvar ai-agent-claude--usage-timer nil
  "Timer for periodic usage API polling.")

(defvar ai-agent-claude--usage-current-interval nil
  "Current polling interval in seconds, possibly increased by backoff.")

(defvar-local ai-agent-claude--copilot-active nil
  "Non-nil when Copilot integration is active in the current buffer.")

(defvar-local ai-agent-claude--copilot-change-timer nil
  "Debounce timer for triggering Copilot after eat buffer changes.")

(defvar eat-terminal)
(defvar url-http-end-of-headers)
(defvar url-request-method)
(defvar url-request-extra-headers)
(declare-function ai-agent-svg-icon "ai-agent" (svg-data &optional face))
(declare-function claude-code--term-send-return "claude-code" (backend))
(declare-function json-pretty-print-buffer "json" ())
(declare-function org-back-to-heading "org" (&optional invisible-ok))
(declare-function org-map-entries "org" (func &optional match scope &rest skip))
(declare-function org-get-todo-state "org" ())
(declare-function org-get-heading "org" (&optional no-tags no-todo no-priority no-comment))
(declare-function org-end-of-meta-data "org" (&optional full))
(declare-function org-entry-is-done-p "org" ())
(declare-function org-todo "org" (&optional arg))
(declare-function outline-next-heading "outline" ())
(autoload 'agent-log-menu "agent-log" nil t)
(declare-function eat-self-input "eat" (n &optional e))
(declare-function eat-term-display-cursor "eat" (terminal))
(declare-function eat-term-send-string "eat" (terminal string))

(defvar copilot-mode)
(defvar copilot--overlay)
(defvar copilot--connection)
(defvar copilot--doc-version)
(defvar copilot--track-changes-id)
(defvar copilot-disable-predicates)
(declare-function copilot-mode "copilot")
(declare-function copilot-accept-completion "copilot")
(declare-function copilot-complete "copilot")
(declare-function copilot-clear-overlay "copilot")
(declare-function copilot--overlay-visible "copilot")
(declare-function copilot--get-language-id "copilot")
(declare-function copilot--get-uri "copilot")
(declare-function copilot--get-source "copilot")
(declare-function copilot--connection-alivep "copilot")
(declare-function copilot--post-command "copilot")
(declare-function copilot--show-completion "copilot")
(declare-function copilot--set-overlay-text "copilot")
(declare-function track-changes-unregister "track-changes")
(declare-function jsonrpc-notify "jsonrpc")
(declare-function jsonrpc-async-request "jsonrpc")

;;;; Backend registration

(defconst ai-agent-claude-icon-svg
  "<svg fill=\"none\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path clip-rule=\"evenodd\" d=\"M20.998 10.949H24v3.102h-3v3.028h-1.487V20H18v-2.921h-1.487V20H15v-2.921H9V20H7.488v-2.921H6V20H4.487v-2.921H3V14.05H0V10.95h3V5h17.998v5.949zM6 10.949h1.488V8.102H6v2.847zm10.51 0H18V8.102h-1.49v2.847z\" fill=\"#D97757\" fill-rule=\"evenodd\"/></svg>"
  "SVG path data for the Claude Code mascot (Clawd pixel art).
Source: lobehub/lobe-icons (MIT).")

(ai-agent-register-backend 'claude-code
  (list :buffer-p #'claude-code--buffer-p
        :find-all-buffers #'claude-code--find-all-claude-buffers
        :find-buffers-for-dir #'claude-code--find-claude-buffers-for-directory
        :directory (lambda (buf) (with-current-buffer buf (claude-code--directory)))
        :extract-directory #'claude-code--extract-directory-from-buffer-name
        :extract-instance-name #'claude-code--extract-instance-name-from-buffer-name
        :send-command (lambda (cmd &optional _buf) (claude-code--do-send-command cmd))
        :start #'claude-code--start
        :start-new #'ai-agent-claude--start-with-account
        :program "claude"
        :send-return (lambda (&optional _buf)
                       (claude-code--term-send-return claude-code-terminal-backend))
        :icon (lambda (&optional face) (let ((svg (ai-agent-svg-icon ai-agent-claude-icon-svg face)))
                                        (if (string-empty-p svg) "CC" svg)))
        :account (lambda (buf)
                   (buffer-local-value 'ai-agent-claude--buffer-account buf))
        :has-background-tasks-p #'ai-agent-claude--has-background-tasks-p
        :display-name-suffix #'ai-agent-claude--branch-suffix
        :label "Claude Code"
        :discover-skills #'ai-agent-claude--discover-skills
        :handoff #'ai-agent-claude-handoff
        :run-skill #'ai-agent-claude-run-skill
        :audit-project #'ai-agent-claude-audit-project
        :debug-backtrace #'ai-agent-claude-debug-backtrace
        :setup-kill-on-exit #'ai-agent-claude-setup-kill-on-exit
        :exit #'ai-agent-claude-exit
        :restart #'ai-agent-claude-restart
        :sync-theme #'ai-agent-claude--sync-theme))

;;;; Functions

;;;;; Exit

;;;###autoload
(defun ai-agent-claude-exit ()
  "Exit the current Claude Code session.
Sends `/exit' to the CLI, which terminates the process.  The
sentinel installed by `ai-agent-claude-setup-kill-on-exit'
then kills the buffer."
  (interactive)
  (claude-code--do-send-command "/exit"))

;;;;; C-g fix

(defun ai-agent-claude--send-escape-in-current-buffer (orig-fn)
  "When already in a Claude buffer, send escape directly without prompting.
ORIG-FN is `claude-code-send-escape'.  The upstream implementation uses
`claude-code--with-buffer', which re-resolves the target buffer via
`claude-code--get-or-prompt-for-buffer'.  When multiple sessions share
the same project directory, that triggers a selection prompt--defeating
the purpose of \\`ESC\\' as a quick interrupt.  This advice short-circuits
the lookup: if the current buffer is already a Claude buffer, send the
escape sequence directly to it."
  (if (claude-code--buffer-p (current-buffer))
      (claude-code--term-send-string claude-code-terminal-backend (kbd "ESC"))
    (funcall orig-fn)))

(advice-add 'claude-code-send-escape :around
            #'ai-agent-claude--send-escape-in-current-buffer)

;;;;; Snippet insertion




;;;;; Buffer protection

(defun ai-agent-claude-protect-buffer ()
  "Prompt for confirmation before killing claude-code buffers.
Returns t if the buffer should be killed, nil otherwise.  Skips
the prompt when the session process has already exited (e.g. via
/exit).  Intended for use in `kill-buffer-query-functions'."
  (or (not ai-agent-protect-buffers)
      (not (claude-code--buffer-p (current-buffer)))
      (not (process-live-p (get-buffer-process (current-buffer))))
      (yes-or-no-p "Kill claude-code buffer? ")))

(defun ai-agent-claude--confirm-kill-branches ()
  "Return t unless the current session has branches and user declines.
Reads the status file to find the session ID and project
directory, then does a fast header-only scan to check for
branches.  Returns t (allow kill) if the session has no branches,
if the status file is unavailable, or if the user confirms."
  (condition-case nil
      (let ((status (ai-agent-claude--parse-status-file)))
        (if (not status)
            t
          (let ((sid (plist-get status :session_id))
                (transcript (plist-get status :transcript_path)))
            (if (not (and sid transcript))
                t
              (let* ((project-dir (file-name-directory transcript))
                     (headers (ai-agent-claude--scan-session-headers project-dir))
                     (children-map (ai-agent-claude--build-children-map headers))
                     (members (ai-agent-claude--collect-tree-members sid children-map))
                     (branch-count (1- (hash-table-count members))))
                (if (<= branch-count 0)
                    t
                  (yes-or-no-p
                   (format "Session has %d %s — kill anyway? "
                           branch-count
                           (if (= branch-count 1) "branch" "branches")))))))))
    (error t)))

(defun ai-agent-claude-setup-kill-on-exit ()
  "Arrange for the buffer to be killed when the Claude process exits.
Works with any terminal backend by wrapping the process sentinel.
When `ai-agent-claude-warn-kill-with-branches' is non-nil and
the session has branches, prompts for confirmation before killing."
  (interactive)
  (when (claude-code--buffer-p (current-buffer))
    (when-let* ((proc (get-buffer-process (current-buffer))))
      (let ((orig (process-sentinel proc))
            (buf (current-buffer)))
        (set-process-sentinel
         proc
         (lambda (process event)
           (when orig
             (funcall orig process event))
           (when (and (buffer-live-p buf)
                      (with-current-buffer buf
                        (ai-agent-claude--confirm-kill-branches)))
             (condition-case nil
                 (kill-buffer buf)
               (error nil)))))))))

(defun ai-agent-claude-fix-rendering ()
  "Send SIGWINCH to fix terminal rendering after startup.
Works around a race condition where Claude Code's TUI queries
terminal dimensions before the terminal window is fully laid out,
resulting in a garbled banner."
  (interactive)
  (when-let* ((proc (get-buffer-process (current-buffer))))
    (ai-agent-claude--send-sigwinch-after-delay (current-buffer))))

(defun ai-agent-claude--send-sigwinch-after-delay (buffer)
  "Send SIGWINCH to the process in BUFFER after a short delay."
  (run-at-time ai-agent-sigwinch-delay nil
               #'ai-agent-claude--send-sigwinch buffer))

(defun ai-agent-claude--send-sigwinch (buffer)
  "Send SIGWINCH to the process in BUFFER."
  (when (buffer-live-p buffer)
    (when-let* ((proc (get-buffer-process buffer)))
      (signal-process proc 'SIGWINCH))))

;;;;; Smart start

(defun ai-agent-claude-account-env (_buffer-name _dir)
  "Return environment variables for the session being started.
Sets `CLAUDE_CONFIG_DIR' based on `ai-agent-claude-accounts'.
Prefers the dynamically bound `ai-agent-claude--pending-account'
\(set by `ai-agent-claude--start-with-account' and
`ai-agent-claude-restart') and falls back to the persisted active
account via `ai-agent-claude--resolve-account', so callers that
invoke `claude-code--start' directly (handoff, branch navigation,
debug sessions) still get the right account's `CLAUDE_CONFIG_DIR'."
  (when-let* ((account (or ai-agent-claude--pending-account
                           (ai-agent-claude--resolve-account)))
              (config-dir (alist-get account ai-agent-claude-accounts
                                     nil nil #'string=)))
    (list (format "CLAUDE_CONFIG_DIR=%s"
                  (expand-file-name config-dir)))))

(defconst ai-agent-claude--shared-config-items
  '("settings.json" "settings.local.json"
    "skills" "plugins" "projects" "memory" "history.jsonl")
  "Files and directories symlinked from `~/.claude/' into each account config dir.
These items are shared across all accounts so that skills, plugins,
project trust, memory, session history, permissions, and hooks are
available regardless of which account is active.  Only OAuth
credentials remain account-specific.")

(defconst ai-agent-claude--shared-claude-json-keys
  '("theme" "claudeInChromeDefaultEnabled"
    "hasCompletedClaudeInChromeOnboarding")
  "Keys copied verbatim from canonical `~/.claude.json' into each
account copy.  The `mcpServers' key is handled separately via
per-server deep merge.  The `projects' key is handled separately
via trust-aware merge logic.")

(defun ai-agent-claude--sync-account-config (account)
  "Sync shared state into ACCOUNT's config directory.
Deep-merges `mcpServers' per-server from canonical, preserving
per-account `env' entries (e.g. account-specific API keys).
Copies theme and chrome settings verbatim.  Merges the `projects'
key from all account configs so folder trust decisions are
available everywhere.  Also symlinks settings, skills, plugins,
projects, memory, and history from `~/.claude/'.

Only writes `.claude.json' when actual changes are detected, to
avoid triggering file-change detection in running Claude Code
sessions."
  (when-let* ((config-dir (alist-get account ai-agent-claude-accounts
                                     nil nil #'string=))
              (target-path (expand-file-name
                            ".claude.json" (expand-file-name config-dir))))
    (make-directory (expand-file-name config-dir) t)
    (ai-agent-claude--ensure-shared-symlinks (expand-file-name config-dir))
    (condition-case err
        (let* ((target (ai-agent-claude--read-claude-json target-path))
               (canonical (ai-agent-claude--read-claude-json
                           (expand-file-name ".claude.json" "~")))
               (merged-projects (ai-agent-claude--collect-all-projects))
               (changed nil))
          (when target
            ;; Sync shared keys from canonical config.
            (when canonical
              (dolist (key ai-agent-claude--shared-claude-json-keys)
                (let ((val (gethash key canonical)))
                  (when (and val
                             (not (equal (json-serialize
                                         (gethash key target))
                                        (json-serialize val))))
                    (puthash key val target)
                    (setq changed t))))
              ;; Deep-merge mcpServers per-server, preserving per-account env.
              (when-let* ((canonical-servers (gethash "mcpServers" canonical)))
                (let ((merged (ai-agent-claude--merge-mcp-servers
                               canonical-servers
                               (gethash "mcpServers" target))))
                  (unless (equal (json-serialize (gethash "mcpServers" target))
                                 (json-serialize merged))
                    (puthash "mcpServers" merged target)
                    (setq changed t)))))
            ;; Merge projects from all accounts.
            (when (> (hash-table-count merged-projects) 0)
              (unless (equal (json-serialize (gethash "projects" target))
                             (json-serialize merged-projects))
                (puthash "projects" merged-projects target)
                (setq changed t)))
            (when changed
              (ai-agent-claude--write-claude-json target-path target))))
      (error
       (message "ai-agent-claude: failed to sync account config: %S" err)))))

(defun ai-agent-claude--merge-mcp-servers (canonical target)
  "Merge CANONICAL MCP servers into TARGET, preserving per-account env.
For each server in CANONICAL, copy all keys into TARGET's entry
but deep-merge the `env' hash table so per-account entries
survive.  Returns the merged result."
  (let ((result (or target (make-hash-table :test #'equal))))
    (maphash
     (lambda (name config)
       (let ((existing (gethash name result)))
         (if (not (and existing (hash-table-p existing)))
             (puthash name config result)
           (let ((account-env (copy-hash-table (gethash "env" existing
                                                        (make-hash-table)))))
             (maphash (lambda (k v) (puthash k v existing)) config)
             (ai-agent-claude--deep-merge-env account-env
                                                 (gethash "env" existing))))))
     canonical)
    result))

(defun ai-agent-claude--deep-merge-env (account-env target-env)
  "Merge ACCOUNT-ENV entries into TARGET-ENV, account wins on conflict.
Modifies TARGET-ENV in place."
  (when (and (hash-table-p account-env)
             (> (hash-table-count account-env) 0))
    (maphash (lambda (k v) (puthash k v target-env)) account-env)))

(defun ai-agent-claude--ensure-shared-symlinks (config-dir)
  "Ensure shared config symlinks exist in CONFIG-DIR.
For each item in `ai-agent-claude--shared-config-items', create a
symlink pointing to the canonical file or directory in `~/.claude/'.
If the target is a virgin-state file or empty directory (typically
created by `claude' on first authentication), it is replaced with a
symlink.  Targets with real content are left alone and a warning is
logged."
  (let ((canonical-dir (expand-file-name ".claude/" "~")))
    (dolist (item ai-agent-claude--shared-config-items)
      (ai-agent-claude--ensure-shared-symlink
       (expand-file-name item canonical-dir)
       (expand-file-name item config-dir)))))

(defun ai-agent-claude--ensure-shared-symlink (source target)
  "Ensure TARGET is a symlink pointing to SOURCE.
Create the symlink if TARGET is missing, replace TARGET if it is a
virgin-state file or empty directory, warn and skip if TARGET has
real content."
  (when (file-exists-p source)
    (cond
     ((file-symlink-p target))
     ((not (file-exists-p target))
      (make-symbolic-link source target)
      (message "ai-agent-claude: symlinked %s -> %s" target source))
     ((ai-agent-claude--item-virgin-p target)
      (ai-agent-claude--delete-item target)
      (make-symbolic-link source target)
      (message "ai-agent-claude: replaced virgin %s with symlink to %s"
               target source))
     (t
      (lwarn 'ai-agent-claude :warning
             "%s has real content; cannot replace with symlink to %s"
             target source)))))

(defun ai-agent-claude--item-virgin-p (path)
  "Return non-nil if PATH is a virgin-state file or empty directory.
An empty directory is virgin.  A zero-byte file is virgin.  A small
JSON file containing only `{}' or `[]' is virgin."
  (cond
   ((file-directory-p path)
    (null (directory-files path nil directory-files-no-dot-files-regexp)))
   ((file-regular-p path)
    (ai-agent-claude--file-virgin-p path))))

(defun ai-agent-claude--file-virgin-p (path)
  "Return non-nil if regular file PATH has empty or placeholder content."
  (let ((size (file-attribute-size (file-attributes path))))
    (or (zerop size)
        (and (< size 16)
             (member (string-trim
                      (with-temp-buffer
                        (insert-file-contents path)
                        (buffer-string)))
                     '("" "{}" "[]"))))))

(defun ai-agent-claude--delete-item (path)
  "Delete PATH, whether it is a file or a directory."
  (if (file-directory-p path)
      (delete-directory path t)
    (delete-file path)))

(defun ai-agent-claude--read-claude-json (path)
  "Read and parse the JSON file at PATH.
Return a hash table, or nil if PATH does not exist or is invalid."
  (when (file-exists-p path)
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents path)
          (json-parse-buffer))
      (error nil))))

(defun ai-agent-claude--collect-all-projects ()
  "Collect and merge `projects' from all `.claude.json' sources.
Reads the canonical `~/.claude.json' first, then each account
config.  For duplicate keys, prefers entries where
`hasTrustDialogAccepted' is true."
  (let ((merged (make-hash-table :test #'equal))
        (paths (ai-agent-claude--all-claude-json-paths)))
    (dolist (path paths)
      (when-let* ((data (ai-agent-claude--read-claude-json path))
                  (projects (gethash "projects" data)))
        (when (hash-table-p projects)
          (maphash (lambda (key val)
                     (ai-agent-claude--merge-project merged key val))
                   projects))))
    merged))

(defun ai-agent-claude--all-claude-json-paths ()
  "Return paths to the canonical and all account `.claude.json' files."
  (cons (expand-file-name ".claude.json" "~")
        (mapcar (lambda (entry)
                  (expand-file-name ".claude.json"
                                    (expand-file-name (cdr entry))))
                ai-agent-claude-accounts)))

(defun ai-agent-claude--merge-project (table key val)
  "Merge project VAL under KEY into TABLE.
Prefers entries where `hasTrustDialogAccepted' is true."
  (let ((existing (gethash key table)))
    (cond
     ((not existing)
      (puthash key val table))
     ((and (hash-table-p val)
           (eq (gethash "hasTrustDialogAccepted" val) t)
           (not (eq (gethash "hasTrustDialogAccepted" existing) t)))
      (puthash key val table)))))

(defun ai-agent-claude--write-claude-json (path data)
  "Write DATA as pretty-printed JSON to PATH."
  (require 'json)
  (with-temp-file path
    (insert (json-serialize data))
    (json-pretty-print-buffer)))

(defun ai-agent-claude--load-account ()
  "Load the current account from `ai-agent-claude-account-file'.
Return the account name, or nil if the file is missing or stale."
  (when (file-exists-p ai-agent-claude-account-file)
    (let ((name (string-trim
                 (with-temp-buffer
                   (insert-file-contents ai-agent-claude-account-file)
                   (buffer-string)))))
      (when (alist-get name ai-agent-claude-accounts nil nil #'string=)
        name))))

(defun ai-agent-claude--save-account (name)
  "Persist NAME as the active account to `ai-agent-claude-account-file'."
  (with-temp-file ai-agent-claude-account-file
    (insert name "\n"))
  (setq ai-agent-claude--current-account name))

(defun ai-agent-claude--prompt-account ()
  "Prompt for an account from `ai-agent-claude-accounts'.
Return the account name, or nil."
  (when ai-agent-claude-accounts
    (let ((names (mapcar #'car ai-agent-claude-accounts)))
      (if (= (length names) 1)
          (car names)
        (completing-read "Account: " names nil t)))))

(defun ai-agent-claude--resolve-account ()
  "Return the active account, loading from disk or prompting as needed.
On first use, loads from `ai-agent-claude-account-file'.  If no
persisted account exists, prompts once and saves the selection."
  (when ai-agent-claude-accounts
    (unless ai-agent-claude--current-account
      (setq ai-agent-claude--current-account
            (ai-agent-claude--load-account)))
    (or ai-agent-claude--current-account
        (let ((account (ai-agent-claude--prompt-account)))
          (when account
            (ai-agent-claude--save-account account))
          account))))

;;;###autoload
(defun ai-agent-claude-select-account ()
  "Switch the active Claude account.
Prompts for an account from `ai-agent-claude-accounts' and
persists the selection.  New sessions will use this account."
  (interactive)
  (unless ai-agent-claude-accounts
    (user-error "No accounts configured in `ai-agent-claude-accounts'"))
  (let ((account (ai-agent-claude--prompt-account)))
    (when account
      (ai-agent-claude--save-account account)
      (ai-agent-claude--sync-account-config account)
      (message "Switched to account: %s" account))))

;;;###autoload
(defun ai-agent-claude-init-account (account)
  "Initialize ACCOUNT's config directory without switching to it.
Creates the config directory and all shared symlinks pointing at
`~/.claude/'.  Safe to call on an already-initialized account: it heals
virgin-state files that `claude' may have created on first
authentication, and leaves real content alone with a warning.

Use this before a new account's first `claude' run, or to repair an
account whose shared files got reset.  Does not change the persisted
active account."
  (interactive
   (list (completing-read "Initialize account: "
                          (mapcar #'car ai-agent-claude-accounts)
                          nil t)))
  (unless (alist-get account ai-agent-claude-accounts nil nil #'string=)
    (user-error "Account %S not in `ai-agent-claude-accounts'" account))
  (ai-agent-claude--sync-account-config account)
  (message "Initialized account: %s" account))

(defun ai-agent-claude--start-with-account ()
  "Start a new Claude session using the active account."
  (interactive)
  (let* ((account (ai-agent-claude--resolve-account))
         (ai-agent-claude--pending-account account))
    (when account
      (ai-agent-claude--sync-account-config account))
    (claude-code)))

;;;###autoload
(defun ai-agent-claude-start-or-switch ()
  "Start a new Claude session or switch to an existing one.
If no sessions are active, start a new one.  If sessions exist,
show the unified session switcher."
  (interactive)
  (if (null (claude-code--find-all-claude-buffers))
      (ai-agent-claude--start-with-account)
    (ai-agent--ensure-all-session-keys)
    (transient-setup 'ai-agent--session-switcher)))










(defun ai-agent-claude-display-name (&optional buffer)
  "Return the display name for BUFFER's modeline.
Delegates to `ai-agent-display-name', which appends branch suffixes
through the Claude backend registration."
  (ai-agent-display-name (or buffer (current-buffer))))


(defun ai-agent-claude--branch-suffix (buffer)
  "Return a short branch ID for BUFFER, or nil if not branched."
  (with-current-buffer buffer
    (let ((original ai-agent-claude--original-session-id)
          (current (when ai-agent-claude--status-data
                     (plist-get ai-agent-claude--status-data :session_id))))
      (when (and original current (not (string= original current)))
        (substring current 0 8)))))

(defun ai-agent-claude--refresh-display-names ()
  "Recompute and cache display names for all Claude buffers."
  (ai-agent--refresh-display-names))

;;;;; Status polling

(defun ai-agent-claude-start-status-polling ()
  "Start polling the status file for the current Claude buffer."
  (interactive)
  (when (claude-code--buffer-p (current-buffer))
    (when ai-agent-claude--status-timer
      (cancel-timer ai-agent-claude--status-timer))
    (let* ((buf (current-buffer))
           (timer-cell (cons nil nil))
           (timer (run-with-timer
                   ai-agent-claude-status-interval
                   ai-agent-claude-status-interval
                   #'ai-agent-claude--read-status
                   timer-cell buf)))
      (setcar timer-cell timer)
      (setq ai-agent-claude--status-timer timer))))

(defvar monet--sessions)
(declare-function monet--session-server "monet")
(declare-function monet--session-port "monet")
(declare-function monet--session-directory "monet")
(declare-function monet--remove-lockfile "monet")
(declare-function websocket-server-close "websocket")

(defun ai-agent-claude--monet-stop-session (key)
  "Fully stop the monet session for KEY.
Closes the websocket server, removes the lockfile, and removes
the session from `monet--sessions'."
  (when-let* ((session (gethash key monet--sessions))
              (server (monet--session-server session)))
    (ignore-errors
      (monet--remove-lockfile (monet--session-port session)))
    (when (process-live-p server)
      (ignore-errors (websocket-server-close server))
      (when (process-live-p server)
        (delete-process server)))
    (remhash key monet--sessions)))

(defun ai-agent-claude--cleanup-monet-session ()
  "Clean up the monet websocket session for the current Claude buffer."
  (when (and (claude-code--buffer-p (current-buffer))
             (boundp 'monet--sessions))
    (ai-agent-claude--monet-stop-session (buffer-name))))

(defun ai-agent-claude--monet-cleanup-before-start (orig-fn key directory)
  "Clean up old monet session for KEY before starting a new one.
ORIG-FN is called with KEY and DIRECTORY after cleanup."
  (when (and (boundp 'monet--sessions)
             (gethash key monet--sessions))
    (ai-agent-claude--monet-stop-session key))
  (funcall orig-fn key directory))

(defun ai-agent-claude--monet-gc-orphaned-servers ()
  "Delete websocket server processes not tracked by any monet session.
Runs periodically as a safety net to catch servers leaked through
any code path."
  (when (boundp 'monet--sessions)
    (let ((active-servers nil))
      (maphash (lambda (_k session)
        (when-let* ((server (monet--session-server session)))
          (push server active-servers)))
        monet--sessions)
      (dolist (p (process-list))
        (when (and (string-match-p "\\`websocket server on port [0-9]"
                                   (process-name p))
                   (eq (process-status p) 'listen)
                   (not (memq p active-servers)))
          (delete-process p))))))

(defun ai-agent-claude--diff-file-in-session-p (diff-buffer session)
  "Return non-nil if DIFF-BUFFER's file is inside SESSION's directory."
  (when-let ((session-dir (and session (monet--session-directory session)))
             (file-dir (buffer-local-value 'default-directory diff-buffer)))
    (file-in-directory-p (expand-file-name file-dir)
                         (file-name-as-directory
                          (expand-file-name session-dir)))))

(defun ai-agent-claude--display-diff-buffer (diff-buffer &optional session)
  "Display DIFF-BUFFER in a bottom side window without switching tabs.
Override for `monet--display-diff-buffer' that avoids the tab-switching
side effects of `display-buffer-in-tab', which can corrupt the window
layout when called from an async websocket callback.
When SESSION is provided and the file is outside the session directory,
the diff is suppressed entirely; the terminal approval prompt suffices."
  (if (and session (not (ai-agent-claude--diff-file-in-session-p diff-buffer session)))
      nil
    (display-buffer diff-buffer
                    '((display-buffer-in-side-window)
                      (side . bottom)
                      (slot . 0)
                      (window-height . 0.3)
                      (preserve-size . (nil . t))))))

(with-eval-after-load 'monet
  (advice-add 'monet-start-server-in-directory :around
              #'ai-agent-claude--monet-cleanup-before-start)
  (advice-add 'monet--display-diff-buffer :override
              #'ai-agent-claude--display-diff-buffer)
  (run-with-timer 60 60 #'ai-agent-claude--monet-gc-orphaned-servers))

(defun ai-agent-claude-stop-status-polling ()
  "Stop status polling and clean up the status file."
  (interactive)
  (when (and (claude-code--buffer-p (current-buffer))
             ai-agent-claude--status-timer)
    (cancel-timer ai-agent-claude--status-timer)
    (ai-agent-claude--cleanup-status-file)))

(defun ai-agent-claude--read-status (timer-cell buffer)
  "Read and parse the status file for BUFFER.
TIMER-CELL is a cons whose car is the timer that triggered this
call; it is canceled automatically when BUFFER is no longer live."
  (if (not (buffer-live-p buffer))
      (cancel-timer (car timer-cell))
    (with-current-buffer buffer
      (when-let* ((data (ai-agent-claude--parse-status-file)))
        (ai-agent-claude--detect-branch data)
        (setq ai-agent-claude--status-data data)))))

(defun ai-agent-claude--detect-branch (new-data)
  "Detect a session ID change, indicating a branch.
NEW-DATA is the freshly parsed status plist.  On the first poll,
records the session ID as the original.  On subsequent polls, if
the ID differs from the previous one, refreshes display names so
the modeline reflects the new branch."
  (let ((new-id (plist-get new-data :session_id)))
    (when new-id
      (if (not ai-agent-claude--original-session-id)
          (setq ai-agent-claude--original-session-id new-id)
        (let ((old-id (plist-get ai-agent-claude--status-data :session_id)))
          (when (and old-id (not (string= new-id old-id)))
            (ai-agent-claude--refresh-display-names)))))))

(defun ai-agent-claude--parse-status-file ()
  "Parse the status JSON file for the current buffer.
Returns a plist, or nil if the file is missing or malformed."
  (let ((file (ai-agent-claude--status-file)))
    (when (file-exists-p file)
      (condition-case nil
          (json-parse-string
           (with-temp-buffer
             (insert-file-contents file)
             (buffer-string))
           :object-type 'plist)
        (json-parse-error nil)))))

(defun ai-agent-claude--status-file ()
  "Return the status file path for the current buffer."
  (expand-file-name
   (ai-agent-claude--status-file-name (buffer-name))
   ai-agent-claude-status-directory))

(defun ai-agent-claude--status-file-name (buffer-name)
  "Return the collision-resistant status filename for BUFFER-NAME."
  (concat (secure-hash 'sha256 buffer-name) ".json"))

(defun ai-agent-claude--sanitize-buffer-name ()
  "Sanitize the current buffer name for use as a filename.
Replaces every character that is not alphanumeric, underscore,
or hyphen with an underscore, mirroring the shell script's
`tr -c' invocation."
  (replace-regexp-in-string "[^a-zA-Z0-9_-]" "_" (buffer-name)))

(defun ai-agent-claude--cleanup-status-file ()
  "Delete the status file for the current buffer."
  (let ((file (ai-agent-claude--status-file)))
    (when (file-exists-p file)
      (delete-file file))))

;;;;; Usage polling

(defun ai-agent-claude--fetch-usage ()
  "Fetch usage data for all accounts with active sessions."
  (dolist (account (ai-agent-claude--active-accounts))
    (ai-agent-claude--fetch-usage-for-account account)))

(defun ai-agent-claude--fetch-usage-for-account (account)
  "Fetch usage data for ACCOUNT asynchronously.
Reads the OAuth token from the macOS Keychain and queries the
undocumented `api/oauth/usage' endpoint.  Stores the parsed
response in `ai-agent-claude--usage-data' keyed by ACCOUNT."
  (when-let* ((token (ai-agent-claude--get-oauth-token account)))
    (let ((url-request-method "GET")
          (url-request-extra-headers
           `(("Authorization" . ,(concat "Bearer " token))
             ("anthropic-beta" . "oauth-2025-04-20"))))
      (url-retrieve
       "https://api.anthropic.com/api/oauth/usage"
       #'ai-agent-claude--handle-usage-response
       (list account) t t))))

(defun ai-agent-claude--handle-usage-response (status account)
  "Handle the async usage API response for ACCOUNT.
STATUS is the plist passed by `url-retrieve'."
  (unwind-protect
      (let ((err (plist-get status :error)))
        (if (ai-agent-claude--usage-response-429-p err)
            (ai-agent-claude--usage-backoff)
          (when (and (null err) url-http-end-of-headers)
            (goto-char url-http-end-of-headers)
            (condition-case nil
                (progn
                  (puthash account
                           (json-parse-buffer :object-type 'plist)
                           ai-agent-claude--usage-data)
                  (ai-agent-claude--usage-reset-interval))
              (json-parse-error nil)))))
    (kill-buffer)))

(defun ai-agent-claude--usage-response-429-p (err)
  "Return non-nil if ERR indicates an HTTP 429 response."
  (and (consp err)
       (eq (car err) 'error)
       (member 429 (cdr err))))

(defun ai-agent-claude--usage-backoff ()
  "Double the polling interval, capped at the configured maximum."
  (let ((new-interval (min (* 2 (or ai-agent-claude--usage-current-interval
                                    ai-agent-claude-usage-interval))
                           ai-agent-claude-usage-max-interval)))
    (setq ai-agent-claude--usage-current-interval new-interval)
    (ai-agent-claude--usage-reschedule new-interval)))

(defun ai-agent-claude--usage-reset-interval ()
  "Reset the polling interval to the base value after a successful fetch."
  (when (and ai-agent-claude--usage-current-interval
             (> ai-agent-claude--usage-current-interval
                ai-agent-claude-usage-interval))
    (setq ai-agent-claude--usage-current-interval
          ai-agent-claude-usage-interval)
    (ai-agent-claude--usage-reschedule
     ai-agent-claude-usage-interval)))

(defun ai-agent-claude--usage-reschedule (interval)
  "Cancel the current usage timer and restart it with INTERVAL seconds."
  (when ai-agent-claude--usage-timer
    (cancel-timer ai-agent-claude--usage-timer)
    (setq ai-agent-claude--usage-timer
          (run-with-timer interval interval
                          #'ai-agent-claude--fetch-usage))))

(defun ai-agent-claude--active-accounts ()
  "Return a list of unique account names with active Claude sessions.
Returns a list containing nil when no multi-account setup exists."
  (let ((accounts nil))
    (dolist (buf (claude-code--find-all-claude-buffers))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (cl-pushnew ai-agent-claude--buffer-account accounts
                      :test #'equal))))
    (or accounts (list nil))))

(defun ai-agent-claude--get-oauth-token (account)
  "Extract the OAuth access token from the macOS Keychain for ACCOUNT.
Returns the token string, or nil if unavailable."
  (let ((service (ai-agent-claude--keychain-service account)))
    (when-let* ((raw (with-output-to-string
                       (with-current-buffer standard-output
                         (call-process "security" nil t nil
                                       "find-generic-password"
                                       "-s" service "-w"))))
                (json (condition-case nil
                          (json-parse-string (string-trim raw)
                                             :object-type 'plist)
                        (json-parse-error nil)))
                (oauth (plist-get json :claudeAiOauth)))
      (plist-get oauth :accessToken))))

(defun ai-agent-claude--keychain-service (account)
  "Return the macOS Keychain service name for ACCOUNT.
Computes the SHA-256 prefix of the expanded config directory
path, matching Claude Code's credential storage convention.
When ACCOUNT is nil or not in `ai-agent-claude-accounts',
returns the default service name."
  (if-let* ((name (and (stringp account) account))
            (config-dir (alist-get name ai-agent-claude-accounts
                                   nil nil #'string=)))
      (concat "Claude Code-credentials-"
              (substring (secure-hash 'sha256 (expand-file-name config-dir))
                         0 8))
    "Claude Code-credentials"))

(defun ai-agent-claude-start-usage-polling ()
  "Start polling the usage API.
Does nothing if the timer is already running."
  (interactive)
  (unless ai-agent-claude--usage-timer
    (setq ai-agent-claude--usage-current-interval
          ai-agent-claude-usage-interval)
    (ai-agent-claude--fetch-usage)
    (setq ai-agent-claude--usage-timer
          (run-with-timer
           ai-agent-claude-usage-interval
           ai-agent-claude-usage-interval
           #'ai-agent-claude--fetch-usage))))

(defun ai-agent-claude-stop-usage-polling ()
  "Stop polling the usage API."
  (interactive)
  (when ai-agent-claude--usage-timer
    (cancel-timer ai-agent-claude--usage-timer)
    (setq ai-agent-claude--usage-timer nil
          ai-agent-claude--usage-current-interval nil)))

;;;;; Status accessors

(defun ai-agent-claude-status-model ()
  "Return the model display name from the status data."
  (when-let* ((model (plist-get ai-agent-claude--status-data :model)))
    (plist-get model :display_name)))

(defun ai-agent-claude-status-cost ()
  "Return the total session cost in USD from the status data."
  (when-let* ((cost (plist-get ai-agent-claude--status-data :cost)))
    (plist-get cost :total_cost_usd)))

(defun ai-agent-claude-status-context-percent ()
  "Return the context window usage percentage from the status data."
  (when-let* ((ctx (plist-get ai-agent-claude--status-data :context_window)))
    (plist-get ctx :used_percentage)))

(defun ai-agent-claude-status-token-count ()
  "Return the total input token count from the status data."
  (when-let* ((ctx (plist-get ai-agent-claude--status-data :context_window)))
    (plist-get ctx :total_input_tokens)))

(defun ai-agent-claude-status-lines-added ()
  "Return the total lines added from the status data."
  (when-let* ((cost (plist-get ai-agent-claude--status-data :cost)))
    (plist-get cost :total_lines_added)))

(defun ai-agent-claude-status-lines-removed ()
  "Return the total lines removed from the status data."
  (when-let* ((cost (plist-get ai-agent-claude--status-data :cost)))
    (plist-get cost :total_lines_removed)))

(defun ai-agent-claude-status-duration-ms ()
  "Return the total session duration in milliseconds from the status data."
  (when-let* ((cost (plist-get ai-agent-claude--status-data :cost)))
    (plist-get cost :total_duration_ms)))

(defun ai-agent-claude-status-cache-read-tokens ()
  "Return the cache read input token count from the status data."
  (when-let* ((ctx (plist-get ai-agent-claude--status-data :context_window))
              (usage (plist-get ctx :current_usage)))
    (plist-get usage :cache_read_input_tokens)))

(defun ai-agent-claude-status-cache-total-tokens ()
  "Return the total input tokens for the current turn from the status data.
This is the sum of INPUT_TOKENS, CACHE_CREATION_INPUT_TOKENS, and
CACHE_READ_INPUT_TOKENS."
  (when-let* ((ctx (plist-get ai-agent-claude--status-data :context_window))
              (usage (plist-get ctx :current_usage)))
    (let ((input (or (plist-get usage :input_tokens) 0))
          (creation (or (plist-get usage :cache_creation_input_tokens) 0))
          (read (or (plist-get usage :cache_read_input_tokens) 0)))
      (+ input creation read))))

;;;;; Usage accessors

(defun ai-agent-claude--usage-for-buffer ()
  "Return the usage plist for the current buffer's account."
  (gethash ai-agent-claude--buffer-account
           ai-agent-claude--usage-data))

(defun ai-agent-claude-status-session-usage ()
  "Return the 5-hour session utilization percentage."
  (when-let* ((data (ai-agent-claude--usage-for-buffer))
              (five (plist-get data :five_hour)))
    (plist-get five :utilization)))

(defun ai-agent-claude-status-weekly-usage ()
  "Return the 7-day weekly utilization percentage."
  (when-let* ((data (ai-agent-claude--usage-for-buffer))
              (seven (plist-get data :seven_day)))
    (plist-get seven :utilization)))

(defun ai-agent-claude-status-session-reset ()
  "Return the 5-hour session reset time as an ISO string."
  (when-let* ((data (ai-agent-claude--usage-for-buffer))
              (five (plist-get data :five_hour)))
    (plist-get five :resets_at)))

(defun ai-agent-claude-status-weekly-reset ()
  "Return the 7-day weekly reset time as an ISO string."
  (when-let* ((data (ai-agent-claude--usage-for-buffer))
              (seven (plist-get data :seven_day)))
    (plist-get seven :resets_at)))

;;;;; Alert

(defun ai-agent-claude-notify (title message)
  "Notification function combining modeline pulse with optional alert.
TITLE is the notification title.  MESSAGE is the notification
body.  When `ai-agent-alert-on-ready' is non-nil, dispatch to
the style configured in `ai-agent-alert-style'."
  (claude-code-default-notification title message)
  (when ai-agent-alert-on-ready
    (ai-agent--alert-visual title message)
    (ai-agent--alert-sound)))



(defun ai-agent-claude--notification-type (json-str)
  "Extract the notification type from JSON-STR.
Return a string like \"idle_prompt\" or \"permission_prompt\", or
nil if the type cannot be determined."
  (when json-str
    (condition-case nil
        (let ((parsed (json-parse-string json-str :object-type 'alist)))
          (or (alist-get 'notification_type parsed)
              (alist-get 'type parsed)))
      (error nil))))

(defun ai-agent-claude--handle-notification (message)
  "Handle a notification event from the Claude Code CLI.
MESSAGE is a plist with :type, :buffer-name, :json-data, and
:args.  Fires OS alerts for idle_prompt, permission_prompt, and
elicitation_dialog notifications."
  (when (eq (plist-get message :type) 'notification)
    (when-let* ((buf (get-buffer (plist-get message :buffer-name))))
      (with-current-buffer buf
        (let* ((name (ai-agent-claude--session-name (buffer-name)))
               (ntype (ai-agent-claude--notification-type
                       (plist-get message :json-data))))
          (pcase ntype
            ("idle_prompt"
             (setq ai-agent--waiting-for-input (current-time))
             (ai-agent-claude-notify
              "Claude ready"
              (format "%s: waiting for your response" name)))
            ("permission_prompt"
             (ai-agent-claude-notify
              "Claude needs approval"
              (format "%s: permission request pending" name)))
            ("elicitation_dialog"
             (ai-agent-claude-notify
              "Claude needs input"
              (format "%s: waiting for your input" name)))
            (_
             (ai-agent-claude-notify
              "Claude Code"
              (format "%s: needs your attention" name))))))))
  nil)

(defconst ai-agent-claude--background-tasks-regexp
  "· *[0-9]+ +\\(shells?\\|monitors?\\)"
  "Regexp matching the background-task count in Claude's status line.
Claude Code renders \"· N shells\" or \"· N monitors\" near the
footer when background Bash processes or Task agents are running.")

(defun ai-agent-claude--has-background-tasks-p (&optional buffer)
  "Return non-nil when Claude session BUFFER has active background tasks.
Scans the tail of the terminal buffer for Claude Code's
status-line indicator (e.g. \"· 3 shells\" or \"· 5 monitors\")."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (save-excursion
          (goto-char (point-max))
          (re-search-backward ai-agent-claude--background-tasks-regexp
                              (max (point-min) (- (point-max) 800))
                              t))))))

(defun ai-agent-claude-jump-to-waiting ()
  "Switch to the Claude session that most recently started waiting for input."
  (interactive)
  (let (best-buf best-time)
    (dolist (buf (claude-code--find-all-claude-buffers))
      (when (buffer-live-p buf)
        (let ((ts (buffer-local-value 'ai-agent--waiting-for-input buf)))
          (when (and ts (or (null best-time) (time-less-p best-time ts)))
            (setq best-buf buf best-time ts)))))
    (if best-buf
        (switch-to-buffer best-buf)
      (message "No sessions waiting for input"))))

(defun ai-agent-claude--handle-stop (message)
  "Handle a stop event from the Claude Code CLI.
MESSAGE is a plist with :type, :buffer-name, :json-data, and
:args.  Scrolls the corresponding terminal buffer to bottom."
  (when (eq (plist-get message :type) 'stop)
    (when-let* ((buf (get-buffer (plist-get message :buffer-name))))
      (with-current-buffer buf
        (ai-agent-claude--scroll-to-bottom buf))))
  nil)

(defun ai-agent-claude--scroll-to-bottom (buffer)
  "Scroll BUFFER and its windows to the terminal cursor.
Move point and all windows showing BUFFER to the eat terminal
cursor, keeping the cursor line at the bottom of each window."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (bound-and-true-p eat-terminal)
        (let ((cursor-pos (eat-term-display-cursor eat-terminal)))
          (goto-char cursor-pos)
          (ai-agent-claude--scroll-windows-to cursor-pos))))))

(defun ai-agent-claude--scroll-windows-to (pos)
  "Set `window-point' to POS and recenter in all windows showing this buffer."
  (dolist (window (get-buffer-window-list nil nil t))
    (set-window-point window pos)
    (with-selected-window window
      (goto-char pos)
      (recenter -1))))

(defun ai-agent-claude--session-name (buffer-name)
  "Extract the project name from BUFFER-NAME.
Given \"*claude:~/path/to/project/:default*\", return
\"project\"."
  (if (string-match "/\\([^/]+\\)/:[^*]+\\*\\'" buffer-name)
      (match-string 1 buffer-name)
    buffer-name))

(defun ai-agent-claude-toggle-alert ()
  "Toggle OS notifications for the current Claude session."
  (interactive)
  (setq ai-agent-alert-on-ready (not ai-agent-alert-on-ready))
  (message "Claude alert notifications %s"
           (if ai-agent-alert-on-ready "enabled" "disabled")))

(defun ai-agent-claude-alert-indicator ()
  "Return a bell icon reflecting the current alert state."
  (if ai-agent-alert-on-ready "🔔" "🔕"))

;;;;; Modeline

(declare-function doom-modeline-set-modeline "doom-modeline-core")

(defun ai-agent-claude-set-modeline ()
  "Set the doom-modeline to the `ai-session' modeline for this buffer.
Also starts status and usage polling if not already active."
  (when (claude-code--buffer-p (current-buffer))
    (unless ai-agent-claude--status-timer
      (ai-agent-claude-start-status-polling))
    (ai-agent-claude-start-usage-polling)
    (doom-modeline-set-modeline 'ai-session)))

(defun ai-agent-claude--capture-buffer-account ()
  "Store the account name as a buffer-local variable.
Called from `claude-code-start-hook'.  Uses the dynamically bound
`ai-agent-claude--pending-account' when available (set by
`ai-agent-claude--start-with-account'), otherwise falls back to
`ai-agent-claude--resolve-account' so that sessions started via
other code paths (e.g. `agent-log-resume-session') also get an account."
  (setq ai-agent-claude--buffer-account
        (or ai-agent-claude--pending-account
            (ai-agent-claude--resolve-account))))

(defun ai-agent-claude-buffer-account ()
  "Return the account name for the current buffer, or nil."
  ai-agent-claude--buffer-account)

;;;;; Copilot integration

(defun ai-agent-claude-setup-copilot ()
  "Set up Copilot integration in the current Claude Code buffer.
Guards on `ai-agent-claude-copilot-enabled',
`claude-code--buffer-p', `eat-terminal', and the availability of
the `copilot' package."
  (when (and ai-agent-claude-copilot-enabled
             (claude-code--buffer-p (current-buffer))
             (bound-and-true-p eat-terminal)
             (require 'copilot nil t))
    (advice-add 'copilot--get-language-id :around
                #'ai-agent-claude--copilot-language-id)
    ;; The copilot server ignores virtual buffer URIs.  Setting
    ;; buffer-file-name makes copilot--get-uri return a file URI
    ;; natively, so didOpen uses the same URI as inlineCompletion.
    (setq buffer-file-name
          (expand-file-name
           (concat "claude-code-"
                   (ai-agent-claude--sanitize-buffer-name)
                   ".txt")
           temporary-file-directory))
    (setq buffer-auto-save-file-name nil)
    (setq-local copilot-disable-predicates
                (cons (lambda () buffer-read-only)
                      copilot-disable-predicates))
    (advice-add 'copilot-accept-completion :around
                #'ai-agent-claude--copilot-accept-around)
    (advice-add 'copilot--show-completion :around
                #'ai-agent-claude--copilot-show-completion)
    (advice-add 'copilot--set-overlay-text :around
                #'ai-agent-claude--copilot-set-overlay-text)
    (add-hook 'post-command-hook
              #'ai-agent-claude--copilot-post-command nil t)
    ;; Eat's semi-char-mode keymap binds TAB to `eat-self-input'.
    ;; Since it is a minor-mode keymap, it takes priority over
    ;; copilot's keymap overlay (which also requires point to be
    ;; within its range).  Use a minor mode activated after eat to
    ;; get higher priority in `minor-mode-map-alist'.
    (ai-agent-claude--copilot-keys-mode 1)
    (setq ai-agent-claude--copilot-active t)
    (copilot-mode 1)
    ;; Copilot registers a `track-changes' handler when the mode
    ;; enables, but eat's `inhibit-modification-hooks' prevents
    ;; track-changes from working and causes "Recovering from
    ;; confusing calls to before/after-change-functions" errors.
    ;; Unregister it since we do our own full-document sync.
    (when (bound-and-true-p copilot--track-changes-id)
      (track-changes-unregister copilot--track-changes-id)
      (setq copilot--track-changes-id nil))
    ;; Copilot's own `post-command-hook' handler calls
    ;; `copilot-complete' without syncing the document, which would
    ;; use stale content.  Remove it and rely on our handler that
    ;; syncs before requesting completions.
    (remove-hook 'post-command-hook #'copilot--post-command t)))

(defvar ai-agent-claude--copilot-keys-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'ai-agent-claude--copilot-tab)
    (define-key map [tab] #'ai-agent-claude--copilot-tab)
    map)
  "Keymap for `ai-agent-claude--copilot-keys-mode'.")

(define-minor-mode ai-agent-claude--copilot-keys-mode
  "Minor mode providing Copilot keybindings in Claude Code buffers."
  :keymap ai-agent-claude--copilot-keys-mode-map)

(defun ai-agent-claude--copilot-tab ()
  "Accept Copilot completion, try snippet expansion, or send TAB to eat."
  (interactive)
  (cond
   ((copilot--overlay-visible)
    (copilot-accept-completion))
   ((ai-agent--try-expand-snippet-at-prompt)
    nil)
   (t
    (eat-self-input 1 ?\t))))

(defun ai-agent-claude--copilot-language-id (orig-fn)
  "Return \"plaintext\" in Claude Code eat buffers.
ORIG-FN is `copilot--get-language-id'.  The default language ID
for `eat-mode' is \"eat\", which the Copilot server does not
recognize."
  (if ai-agent-claude--copilot-active
      "plaintext"
    (funcall orig-fn)))

(defun ai-agent-claude--copilot-show-completion (orig-fn completion-data)
  "Relocate the copilot overlay to the TUI prompt line.
ORIG-FN is `copilot--show-completion'.  COMPLETION-DATA is the
server response.  In eat buffers the line numbers in the server's
range drift because the buffer changes between sync and response,
so the overlay often ends up on a TUI chrome line.  This advice
lets the original function create the overlay, then moves it to
the prompt and re-renders the ghost text at the correct position.
Finally it moves point there so the Emacs cursor sits at the
ghost text boundary."
  (if (not ai-agent-claude--copilot-active)
      (funcall orig-fn completion-data)
    (funcall orig-fn completion-data)
    (when (copilot--overlay-visible)
      (let ((prompt-bol
             (save-excursion
               (goto-char (point-max))
               (when (re-search-backward "^❯[[:space:]]" nil t)
                 (point)))))
        (when prompt-bol
          (let* ((prompt-eol (save-excursion (goto-char prompt-bol)
                                             (line-end-position)))
                 (line-text (buffer-substring-no-properties
                             prompt-bol prompt-eol))
                 (insert-text (plist-get completion-data :insertText))
                 (prefix-len
                  (when insert-text
                    (let ((i 0)
                          (max-i (min (length line-text)
                                      (length insert-text))))
                      (while (and (< i max-i)
                                  (= (aref line-text i)
                                     (aref insert-text i)))
                        (cl-incf i))
                      i)))
                 (completion
                  (when (and prefix-len
                             (< prefix-len (length insert-text)))
                    (substring insert-text prefix-len)))
                 (insert-pos (+ prompt-bol (or prefix-len 0))))
            (when (and completion (not (string-empty-p completion)))
              (goto-char insert-pos)
              (overlay-put copilot--overlay 'tail-length 0)
              (copilot--set-overlay-text copilot--overlay completion)
              (overlay-put copilot--overlay 'completion completion)
              (overlay-put copilot--overlay 'completion-start insert-pos))))))))

(defun ai-agent-claude--copilot-set-overlay-text (orig-fn ov completion)
  "Clip the copilot overlay to the remaining terminal columns.
ORIG-FN is `copilot--set-overlay-text'.  OV is the overlay.
COMPLETION is the completion text.  In eat buffers, the overlay's
`after-string' must not wrap past the line end, otherwise it
pushes TUI chrome down and disrupts the terminal layout.  This
advice truncates the completion to the first line and clips it to
the remaining space on the current terminal line."
  (if ai-agent-claude--copilot-active
      (let* ((first-line (car (split-string completion "\n")))
             (remaining (max 0 (- (window-width) (current-column) 1)))
             (clipped (if (> (length first-line) remaining)
                         (substring first-line 0 remaining)
                       first-line)))
        (unless (string-empty-p clipped)
          (funcall orig-fn ov clipped)))
    (funcall orig-fn ov completion)))

(defun ai-agent-claude--copilot-accept-around (orig-fn &optional transform-fn)
  "Around advice for `copilot-accept-completion' in eat buffers.
When in a Claude Code eat buffer, extract the completion, send
telemetry, and inject text via the terminal instead of using
`delete-region'/`insert'.  Otherwise, call ORIG-FN with
TRANSFORM-FN unchanged."
  (if (and (bound-and-true-p eat-terminal)
           ai-agent-claude--copilot-active)
      (when (copilot--overlay-visible)
        (let* ((completion (overlay-get copilot--overlay 'completion))
               (command (overlay-get copilot--overlay 'command))
               (full-insert-text (overlay-get copilot--overlay 'full-insert-text))
               (t-completion (funcall (or transform-fn #'identity) completion))
               (is-partial (and (string-prefix-p t-completion completion)
                                (not (string-equal t-completion completion)))))
          (ai-agent-claude--copilot-send-telemetry
           is-partial command full-insert-text completion t-completion)
          (copilot-clear-overlay t)
          (let ((text (replace-regexp-in-string "\n" "\e\r" t-completion)))
            (eat-term-send-string eat-terminal text))
          t))
    (funcall orig-fn transform-fn)))

(defun ai-agent-claude--copilot-send-telemetry
    (is-partial command full-insert-text completion t-completion)
  "Send Copilot telemetry for acceptance.
IS-PARTIAL is non-nil for partial acceptance.  COMMAND is the LSP
command from the overlay.  FULL-INSERT-TEXT is the original full
suggestion.  COMPLETION is the remaining completion text.
T-COMPLETION is the transformed (accepted) portion."
  (when (and command (bound-and-true-p copilot--connection))
    (condition-case nil
        (if is-partial
            (let* ((prefix-len (- (length full-insert-text) (length completion)))
                   (accepted-length (+ prefix-len (length t-completion))))
              (jsonrpc-notify copilot--connection
                              'textDocument/didPartiallyAcceptCompletion
                              (list :item (list :command command)
                                    :acceptedLength accepted-length)))
          (jsonrpc-async-request copilot--connection
                                 'workspace/executeCommand command
                                 :success-fn #'ignore))
      (error nil))))

(defun ai-agent-claude--copilot-sync-document ()
  "Send a full-document `textDocument/didChange' to the Copilot server.
Eat's process filter runs with `inhibit-modification-hooks' bound
to t, so `track-changes' never detects buffer modifications and
the server's document becomes stale.  This function works around
the problem by sending the entire buffer contents as a single
replacement change, keeping the server in sync."
  (when (and (bound-and-true-p copilot--connection)
             (copilot--connection-alivep))
    (cl-incf copilot--doc-version)
    (jsonrpc-notify
     copilot--connection
     'textDocument/didChange
     (list :textDocument (list :uri (copilot--get-uri)
                               :version copilot--doc-version)
           :contentChanges
           (vector (list :text (copilot--get-source)))))))

(defun ai-agent-claude--copilot-post-command ()
  "Schedule a debounced `copilot-complete' after user input.
Eat's process filter runs with `inhibit-modification-hooks' bound
to t, so neither `after-change-functions' nor `track-changes'
detect buffer modifications (making copilot's normal
`post-command-hook' trigger ineffective).  This function replaces
copilot's trigger by scheduling a document sync and completion
request after a short delay, giving the terminal echo time to
arrive and update the buffer before the Copilot server is
consulted."
  (when (and ai-agent-claude--copilot-active
             (bound-and-true-p copilot-mode)
             (not buffer-read-only))
    (copilot-clear-overlay)
    (when (timerp ai-agent-claude--copilot-change-timer)
      (cancel-timer ai-agent-claude--copilot-change-timer))
    (let ((buf (current-buffer)))
      (setq ai-agent-claude--copilot-change-timer
            (run-with-timer
             0.3 nil
             (lambda ()
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (setq ai-agent-claude--copilot-change-timer nil)
                   (when copilot-mode
                     (ai-agent-claude--copilot-complete-at-prompt))))))))))

(defun ai-agent-claude--copilot-complete-at-prompt ()
  "Sync the document and request completion at the TUI prompt.
Claude Code's TUI repositions the terminal cursor for rendering,
so `point' often lands on a status-bar or border line rather than
the input prompt.  This function searches backward for the `❯'
prompt marker and moves point to the end of the user's text on
that line before syncing and requesting completions."
  (save-excursion
    (goto-char (point-max))
    (when (re-search-backward "^❯[[:space:]]" nil t)
      (end-of-line)
      (skip-chars-backward " \t")
      (ai-agent-claude--copilot-sync-document)
      (copilot-complete))))

(defun ai-agent-claude-teardown-copilot ()
  "Clean up Copilot integration in the current Claude Code buffer."
  (when ai-agent-claude--copilot-active
    (when (timerp ai-agent-claude--copilot-change-timer)
      (cancel-timer ai-agent-claude--copilot-change-timer))
    (setq ai-agent-claude--copilot-active nil)))

;;;;; Non-interactive execution

(defcustom ai-agent-claude-batch-allowed-tools nil
  "Tools to auto-allow via `--allowedTools' for non-interactive execution.
When nil (the default), no `--allowedTools' flag is passed and tool
access is governed by `ai-agent-claude-batch-permission-mode'
and the user's settings.json."
  :type '(choice (const :tag "None (use permission-mode)" nil)
                 (repeat string))
  :group 'ai-agent-claude)

(defcustom ai-agent-claude-batch-permission-mode "auto"
  "Permission mode passed via `--permission-mode' for non-interactive execution.
The default \"auto\" uses a background classifier to allow most
actions while blocking risky ones (force pushes, mass deletion,
sending secrets to external endpoints, etc.)."
  :type '(choice (const :tag "Auto" "auto")
                 (const :tag "Bypass all" "bypassPermissions")
                 (const :tag "Default" "default")
                 (const :tag "Accept edits" "acceptEdits")
                 (const :tag "Don't ask" "dontAsk")
                 (const :tag "None" nil))
  :group 'ai-agent-claude)

(defcustom ai-agent-claude-batch-max-turns 30
  "Maximum agentic turns per entry in non-interactive execution."
  :type 'integer
  :group 'ai-agent-claude)

(defcustom ai-agent-claude-batch-system-prompt nil
  "Optional system prompt appended via `--append-system-prompt'.
When non-nil, passed to each `claude -p' invocation."
  :type '(choice (const :tag "None" nil) string)
  :group 'ai-agent-claude)

(defcustom ai-agent-claude-batch-model nil
  "Optional model override via `--model' for non-interactive execution.
When non-nil, passed to each `claude -p' invocation."
  :type '(choice (const :tag "Default" nil) string)
  :group 'ai-agent-claude)

(defcustom ai-agent-claude-run-skill-model "opus"
  "Model to use for `ai-agent-claude-run-skill'.
Skills are complex agentic tasks that benefit from the most
capable model.  Supports aliases like \"opus\", \"sonnet\",
\"haiku\" as well as full model IDs.  Set to nil to use
`ai-agent-claude-batch-model' or Claude's default."
  :type '(choice (const :tag "Opus (latest)" "opus")
                 (const :tag "Sonnet (latest)" "sonnet")
                 (const :tag "Haiku (latest)" "haiku")
                 (const :tag "Use batch default" nil)
                 string)
  :group 'ai-agent-claude)

(defcustom ai-agent-claude-audit-skills
  '("/code-audit" "/design-audit" "/interpretability-audit")
  "Skills to run when performing an integral project audit.
Each entry is a skill name (with leading slash) that will be
invoked with `--accept'."
  :type '(repeat string)
  :group 'ai-agent-claude)

(defcustom ai-agent-claude-audit-project-directories nil
  "Directories available for selection in `ai-agent-claude-audit-project'.
New directories entered by the user are automatically added to this list."
  :type '(repeat directory)
  :group 'ai-agent-claude)

(defcustom ai-agent-claude-org-todo-in-progress-keyword nil
  "Org TODO keyword to set when sending a heading to Claude Code.
When non-nil, `ai-agent-claude-send-todo-at-point' changes the
heading's TODO state to this keyword after sending.  The keyword
must be one of the values in `org-todo-keywords' for the current
buffer.  When nil, the TODO state is not changed.

Org's built-in keywords are just TODO and DONE, with no
intermediate state, so this is disabled by default.  Users who
have configured an in-progress keyword (e.g. DOING, IN-PROGRESS,
STARTED) can set this option to that keyword."
  :type '(choice (const :tag "Don't change TODO state" nil)
                 (string :tag "Keyword"))
  :group 'ai-agent-claude)

;; Batch state is passed as a plist through closures to support
;; parallel runs.  Keys: :queue :results :log-dir :working-dir :start-time

(defun ai-agent-claude--batch-collect-todos (scope)
  "Collect TODO entries from the current org buffer according to SCOPE.
SCOPE is one of `buffer', `subtree', or `region'.
Returns a list of plists with :title and :body keys."
  (let ((entries '()))
    (org-map-entries
     (lambda ()
       (when (and (org-get-todo-state)
                  (not (org-entry-is-done-p)))
         (let* ((title (org-get-heading t t t t))
                (body-start (save-excursion
                              (org-end-of-meta-data t)
                              (point)))
                (body-end (save-excursion
                            (outline-next-heading)
                            (or (point) (point-max))))
                (body (string-trim
                       (buffer-substring-no-properties body-start body-end))))
           (push (list :title title :body body) entries))))
     nil
     (pcase scope
       ('buffer nil)
       ('subtree 'tree)
       ('region 'region)))
    (nreverse entries)))

(defun ai-agent-claude--batch-format-prompt (entry)
  "Format ENTRY plist as a prompt string for `claude -p'.
Combines :title and :body, using title alone when body is empty."
  (let ((title (plist-get entry :title))
        (body (plist-get entry :body)))
    (if (or (null body) (string-empty-p body))
        title
      (concat title "\n\n" body))))

(defun ai-agent-claude-batch-todos ()
  "Process org TODO entries sequentially via `claude -p'.
Infers scope automatically: region if active, subtree if the
buffer is narrowed, buffer otherwise.  Prompts for a working
directory, then runs each TODO as a non-interactive Claude
session.  Results are logged to timestamped files and displayed
in a summary buffer when all entries have been processed."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Must be called from an org-mode buffer"))
  (let* ((scope (cond
                 ((use-region-p) 'region)
                 ((buffer-narrowed-p) 'subtree)
                 (t 'buffer)))
         (entries (ai-agent-claude--batch-collect-todos scope)))
    (when (null entries)
      (user-error "No TODO entries found in %s" scope))
    (let ((dir (project-prompt-project-dir)))
      (when (or (eq scope 'region)
                (yes-or-no-p
                 (format "Process %d TODO(s) in %s?" (length entries) dir)))
        (ai-agent-claude--batch-start entries dir)))))

(defun ai-agent-claude-send-todo-at-point ()
  "Send the org TODO at point to a running Claude Code session.
Extracts the heading and body of the TODO entry at point,
formats them as a prompt, and sends it to the Claude Code
session associated with the current file's project.  When no
unique session can be inferred, prompts for selection.

When `ai-agent-claude-org-todo-in-progress-keyword' is
non-nil, the heading's TODO state is changed to that keyword
after sending."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Must be called from an org-mode buffer"))
  (unless (org-get-todo-state)
    (user-error "Point is not on a TODO heading"))
  (let* ((entry (ai-agent-claude--collect-todo-at-point))
         (prompt (ai-agent-claude--batch-format-prompt entry))
         (buf (ai-agent-claude--resolve-session-for-file)))
    (with-current-buffer buf
      (claude-code--do-send-command prompt))
    (when ai-agent-claude-org-todo-in-progress-keyword
      (org-todo ai-agent-claude-org-todo-in-progress-keyword))
    (display-buffer buf)))

(defun ai-agent-claude--org-to-markdown (text)
  "Convert org inline markup in TEXT to Markdown equivalents.
Handles verbatim (=…=) and code (~…~) to backticks."
  (replace-regexp-in-string "[=~]\\([^=~\n]+\\)[=~]" "`\\1`" text))

(defun ai-agent-claude--collect-todo-at-point ()
  "Return a plist with :title and :body for the TODO at point."
  (save-excursion
    (org-back-to-heading t)
    (let* ((title (ai-agent-claude--org-to-markdown
                   (org-get-heading t t t t)))
           (body-start (progn (org-end-of-meta-data t) (point)))
           (body-end (progn (outline-next-heading)
                            (or (point) (point-max))))
           (body (string-trim
                  (buffer-substring-no-properties body-start body-end))))
      (list :title title :body body))))

(defun ai-agent-claude--resolve-session-for-file ()
  "Find the Claude Code session for the current file's project.
Returns a buffer.  Uses the project root to find matching
sessions.  Falls back to `claude-code--get-or-prompt-for-buffer'
when no project is detected or no session matches."
  (let* ((project (project-current))
         (dir (and project (project-root project)))
         (buffers (and dir
                       (claude-code--find-claude-buffers-for-directory dir))))
    (cond
     ((= (length buffers) 1)
      (car buffers))
     ((> (length buffers) 1)
      (claude-code--select-buffer-from-choices
       (format "Multiple sessions for %s: "
               (abbreviate-file-name dir))
       buffers t))
     (t
      (or (claude-code--get-or-prompt-for-buffer)
          (user-error "No running Claude Code session found"))))))

(defun ai-agent-claude--batch-start (entries dir &optional commit-after-each)
  "Start batch processing of ENTRIES in working directory DIR.
When COMMIT-AFTER-EACH is non-nil, automatically commit any uncommitted
changes in DIR after each entry completes successfully."
  (when commit-after-each
    (ai-agent-claude--ensure-clean-worktree dir))
  (let* ((log-dir (expand-file-name
                   (format-time-string "batch_%Y-%m-%d_%H-%M-%S")
                   ai-agent-claude-log-directory))
         (state (list :queue entries
                      :results nil
                      :log-dir log-dir
                      :working-dir dir
                      :start-time (current-time)
                      :commit-after-each commit-after-each)))
    (make-directory log-dir t)
    (message "Batch processing %d TODO(s)..." (length entries))
    (ai-agent-claude--batch-run-next state)))

(defun ai-agent-claude--ensure-clean-worktree (dir)
  "Signal a user error unless DIR is a clean git worktree."
  (let ((default-directory dir))
    (with-temp-buffer
      (let ((exit (call-process "git" nil t nil
                                "status" "--porcelain")))
        (cond
         ((not (zerop exit))
          (user-error "Cannot inspect git worktree in %s: %s"
                      dir (string-trim (buffer-string))))
         ((> (buffer-size) 0)
          (user-error
           "Refusing audit auto-commit because %s has uncommitted changes"
           dir)))))))

(defun ai-agent-claude--batch-run-next (state)
  "Process the next entry in the batch queue in STATE.
STATE is a plist with keys :queue :results :log-dir :working-dir
:start-time.  When the queue is empty, display the summary buffer."
  (if (null (plist-get state :queue))
      (ai-agent-claude--batch-finish state)
    (let* ((queue (plist-get state :queue))
           (entry (car queue))
           (index (1+ (length (plist-get state :results))))
           (title (plist-get entry :title))
           (prompt (ai-agent-claude--batch-format-prompt entry))
           (log-file (expand-file-name
                      (format "%02d_%s.json"
                              index
                              (replace-regexp-in-string
                               "[^a-zA-Z0-9_-]" "-"
                               (truncate-string-to-width title 50)))
                      (plist-get state :log-dir))))
      (plist-put state :queue (cdr queue))
      (message "Batch [%d/%d]: %s"
               index
               (+ index (length (plist-get state :queue)))
               title)
      (ai-agent-claude--run-prompt
       prompt
       :dir (plist-get state :working-dir)
       :callback
       (lambda (result)
         (when-let* ((raw (plist-get result :raw)))
           (with-temp-file log-file
             (insert raw)))
         (plist-put state :results
                    (cons (list :title title
                                :index index
                                :exit-code (plist-get result :exit-code)
                                :duration (plist-get result :duration)
                                :cost (plist-get result :cost)
                                :result-text (or (plist-get result :text)
                                                 "(failed to parse output)")
                                :log-file log-file)
                          (plist-get state :results)))
         (when (and (zerop (plist-get result :exit-code))
                    (plist-get state :commit-after-each))
           (ignore-errors
             (ai-agent-claude--batch-commit-changes state title)))
         (ai-agent-claude--batch-run-next state))))))

(defun ai-agent-claude--batch-commit-changes (state title)
  "Commit uncommitted work in the working directory of STATE.
TITLE is the entry title, used to derive the commit message scope."
  (let ((default-directory (plist-get state :working-dir)))
    (with-temp-buffer
      (call-process "git" nil t nil "status" "--porcelain")
      (when (> (buffer-size) 0)
        (call-process "git" nil nil nil "add" "-A")
        (let ((scope (replace-regexp-in-string
                      "^/" ""
                      (car (split-string title " ")))))
          (call-process "git" nil nil nil "commit" "-m"
                        (format "%s: apply audit recommendations" scope)))))))

(defun ai-agent-claude--batch-parse-stream-json (raw)
  "Parse stream-json output RAW into a plist.
Returns (:text ASSISTANT-TEXT :cost COST :session-id ID
         :num-turns N :subtype TYPE)."
  (let (texts cost session-id num-turns subtype)
    (dolist (line (split-string raw "\n" t))
      (condition-case nil
          (let ((obj (json-parse-string line :object-type 'plist)))
            (pcase (plist-get obj :type)
              ("assistant"
               (let ((content (plist-get (plist-get obj :message) :content)))
                 (when (vectorp content)
                   (seq-doseq (block content)
                     (when (equal (plist-get block :type) "text")
                       (push (plist-get block :text) texts))))))
              ("result"
               (setq cost (or (plist-get obj :total_cost_usd)
                              (plist-get obj :cost_usd) 0)
                     session-id (plist-get obj :session_id)
                     num-turns (plist-get obj :num_turns)
                     subtype (plist-get obj :subtype)))))
        (error nil)))
    (list :text (if texts
                    (string-join (nreverse texts) "\n\n")
                  (format (concat "No assistant text captured.\n"
                                  "Session: %s | Turns: %s | Reason: %s\n"
                                  "Resume with: claude --resume %s")
                          (or session-id "?") (or num-turns "?")
                          (or subtype "unknown") (or session-id "?")))
          :cost (or cost 0)
          :session-id session-id)))

(defun ai-agent-claude--build-cli-args (prompt &rest kwargs)
  "Build the argument list for `claude -p' with PROMPT.
KWARGS are keyword arguments:
  :allowed-tools   list of tool name strings
  :permission-mode permission mode string
  :system-prompt   string appended via --append-system-prompt
  :model           model name string
  :max-turns       integer, maximum agentic turns
Each defaults to the corresponding `ai-agent-claude-batch-*'
customization variable when not supplied."
  (let ((allowed-tools (or (plist-get kwargs :allowed-tools)
                           ai-agent-claude-batch-allowed-tools))
        (permission-mode (or (plist-get kwargs :permission-mode)
                             ai-agent-claude-batch-permission-mode))
        (system-prompt (or (plist-get kwargs :system-prompt)
                           ai-agent-claude-batch-system-prompt))
        (model (or (plist-get kwargs :model)
                   ai-agent-claude-batch-model))
        (max-turns (or (plist-get kwargs :max-turns)
                       ai-agent-claude-batch-max-turns))
        (args (list claude-code-program
                    "-p" prompt
                    "--output-format" "stream-json"
                    "--verbose")))
    (setq args (append args (list "--max-turns"
                                  (number-to-string max-turns))))
    (when permission-mode
      (setq args (append args (list "--permission-mode" permission-mode))))
    (when allowed-tools
      (setq args (append args (list "--allowedTools"
                                    (string-join allowed-tools ",")))))
    (when system-prompt
      (setq args (append args (list "--append-system-prompt"
                                    system-prompt))))
    (when model
      (setq args (append args (list "--model" model))))
    args))

(defun ai-agent-claude--run-prompt (prompt &rest kwargs)
  "Run PROMPT non-interactively via `claude -p' and call back with results.
KWARGS are keyword arguments:
  :dir             working directory (default `default-directory')
  :callback        function called with a result plist (required)
  :allowed-tools   passed to `ai-agent-claude--build-cli-args'
  :system-prompt   passed to `ai-agent-claude--build-cli-args'
  :model           passed to `ai-agent-claude--build-cli-args'
  :max-turns       passed to `ai-agent-claude--build-cli-args'

The CALLBACK receives a plist with keys:
  :exit-code  process exit code
  :duration   elapsed seconds (float)
  :cost       USD cost (float)
  :text       parsed assistant text
  :session-id session ID string
  :raw        raw stream-json output

Returns the process object."
  (let* ((dir (or (plist-get kwargs :dir) default-directory))
         (callback (or (plist-get kwargs :callback)
                       (error "ai-agent-claude--run-prompt: :callback required")))
         (args (apply #'ai-agent-claude--build-cli-args prompt
                      (cl-loop for key in '(:allowed-tools :system-prompt
                                            :model :max-turns)
                               for val = (plist-get kwargs key)
                               when val append (list key val))))
         (env (ai-agent-claude--batch-process-environment))
         (start-time (current-time))
         (output-buf (generate-new-buffer " *claude-run-output*")))
    (let ((process-environment env)
          (default-directory dir))
      (make-process
       :name "claude-run"
       :buffer output-buf
       :command args
       :sentinel
       (lambda (proc _event)
         (when (memq (process-status proc) '(exit signal))
           (let (result)
             (condition-case err
                 (let* ((exit-code (process-exit-status proc))
                        (raw (with-current-buffer (process-buffer proc)
                               (buffer-string)))
                        (duration (float-time
                                   (time-subtract (current-time) start-time)))
                        (parsed (ai-agent-claude--batch-parse-stream-json raw)))
                   (setq result (list :exit-code exit-code
                                      :duration duration
                                      :cost (or (plist-get parsed :cost) 0)
                                      :text (plist-get parsed :text)
                                      :session-id (plist-get parsed :session-id)
                                      :raw raw)))
               (error
                (setq result (list :exit-code -1
                                   :duration (float-time
                                              (time-subtract (current-time)
                                                             start-time))
                                   :cost 0
                                   :text (format "Sentinel error: %S" err)
                                   :session-id nil
                                   :raw ""))))
             (ignore-errors (kill-buffer (process-buffer proc)))
             (funcall callback result))))))))

(defun ai-agent-claude--batch-process-environment ()
  "Return the process environment for non-interactive Claude runs."
  (if-let* ((account (ai-agent-claude--resolve-account))
            (config-dir (alist-get account ai-agent-claude-accounts
                                   nil nil #'string=)))
      (cons (format "CLAUDE_CONFIG_DIR=%s" (expand-file-name config-dir))
            (cl-remove-if
             (lambda (s)
               (or (string-prefix-p "CLAUDE_CODE" s)
                   (string-prefix-p "ANTHROPIC_API_KEY=" s)))
             process-environment))
    process-environment))

;;;;; Skill runner

(defun ai-agent-claude--parse-skill-frontmatter (file)
  "Parse YAML frontmatter from skill FILE and return a plist.
Returns a plist with keys :name, :description, :argument-hint,
:argument-source, :argument-choices, :argument-default,
:argument-multiple, :user-invocable, or nil if FILE has no
frontmatter."
  (ai-agent-parse-skill-frontmatter file))

(defun ai-agent-claude--discover-skills ()
  "Discover available Claude Code skills.
Scans `~/.claude/skills/' for global skills and the current
project's `.claude/skills/' for project-local skills.  Returns a
list of plists, each with keys :name, :description,
:argument-hint, :user-invocable, :path, :source.  Project skills
shadow global skills with the same name."
  (let ((skills (make-hash-table :test #'equal))
        (global-dir (expand-file-name "~/.claude/skills"))
        (project-dir (when-let* ((proj (project-current)))
                       (expand-file-name ".claude/skills"
                                         (project-root proj)))))
    ;; Scan global skills first
    (when (file-directory-p global-dir)
      (dolist (file (file-expand-wildcards
                     (expand-file-name "*/SKILL.md" global-dir)))
        (when-let* ((meta (ai-agent-claude--parse-skill-frontmatter file))
                    (name (plist-get meta :name)))
          (puthash name (append meta (list :path file :source "global"))
                   skills))))
    ;; Project skills shadow global ones
    (when (and project-dir (file-directory-p project-dir))
      (dolist (file (file-expand-wildcards
                     (expand-file-name "*/SKILL.md" project-dir)))
        (when-let* ((meta (ai-agent-claude--parse-skill-frontmatter file))
                    (name (plist-get meta :name)))
          (puthash name (append meta (list :path file :source "project"))
                   skills))))
    ;; Filter to user-invocable and collect
    (let (result)
      (maphash (lambda (_name skill)
                 ;; Include unless explicitly marked non-invocable
                 (unless (and (plist-member skill :user-invocable)
                              (not (plist-get skill :user-invocable)))
                   (push skill result)))
               skills)
      (sort result (lambda (a b)
                     (string< (plist-get a :name) (plist-get b :name)))))))

(defun ai-agent-claude--skill-display-result (skill-name result
                                                              &optional _buffers-before)
  "Display RESULT plist in a buffer for SKILL-NAME.
BUFFERS-BEFORE is ignored; results are always written to a
dedicated buffer so unrelated user buffers are never modified."
  (let ((meta-text (concat
                     (format "#+cost: $%.4f\n" (plist-get result :cost))
                     (format "#+duration: %.1fs\n" (plist-get result :duration))
                     (if-let* ((sid (plist-get result :session-id)))
                         (format "#+session: %s\n" sid)
                       "")))
        (buf (get-buffer-create (format "*Claude Skill: %s*" skill-name))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "#+title: /%s — %s\n"
                        skill-name
                        (format-time-string "%Y-%m-%d %H:%M:%S")))
        (insert meta-text)
        (insert "\n")
        (insert (or (plist-get result :text) "(no output)"))
        (unless (string-suffix-p "\n" (or (plist-get result :text) ""))
          (insert "\n")))
      (org-mode)
      (goto-char (point-min)))
    (pop-to-buffer buf)
    (message "/%s complete (%.1fs, $%.4f)"
             skill-name
             (plist-get result :duration)
             (plist-get result :cost))))

;;;###autoload
(defun ai-agent-claude-run-skill (skill-name &optional arguments dir)
  "Run Claude Code skill SKILL-NAME non-interactively.
ARGUMENTS is an optional string of arguments appended to the
skill invocation.  DIR is the working directory for the process;
defaults to `default-directory'.

Interactively, prompts for the skill with completion, then for
arguments if the skill declares an argument-hint or
argument-source."
  (interactive
   (let* ((skills (ai-agent-claude--discover-skills))
          (_ (unless skills (user-error "No user-invocable skills found")))
          (max-len (apply #'max (mapcar (lambda (s)
                                          (length (plist-get s :name)))
                                        skills)))
          (annotate (lambda (cand)
                      (when-let* ((skill (cl-find cand skills
                                                  :key (lambda (s) (plist-get s :name))
                                                  :test #'equal))
                                  (desc (plist-get skill :description))
                                  (source (plist-get skill :source)))
                        (concat (make-string (- (+ max-len 2) (length cand)) ?\s)
                                (propertize (format "[%s] " source)
                                            'face 'font-lock-comment-face)
                                (propertize desc 'face 'completions-annotations)))))
          (name (completing-read
                 "Skill: "
                 (lambda (str pred action)
                   (if (eq action 'metadata)
                       `(metadata (annotation-function . ,annotate))
                     (complete-with-action
                      action
                      (mapcar (lambda (s) (plist-get s :name)) skills)
                      str pred)))))
          (skill (cl-find name skills
                          :key (lambda (s) (plist-get s :name))
                          :test #'equal))
          (hint (and skill (plist-get skill :argument-hint)))
          (candidates (and skill
                           (ai-agent--skill-argument-candidates skill)))
          (default (and skill (plist-get skill :argument-default)))
          (multiple-p (and skill (plist-get skill :argument-multiple)))
          (args (cond
                 ;; Completion candidates available
                 ((and candidates multiple-p)
                  (let ((selected (completing-read-multiple
                                   (format "Arguments %s: " (or hint ""))
                                   candidates)))
                    (when selected (string-join selected " "))))
                 (candidates
                  (let ((selected (completing-read
                                   (format "Arguments%s: "
                                           (cond
                                            ((and hint default)
                                             (format " %s (default %s)" hint default))
                                            (hint (format " %s" hint))
                                            (default (format " (default %s)" default))
                                            (t "")))
                                   candidates nil nil nil nil default)))
                    (unless (string-empty-p selected) selected)))
                 ;; No candidates but has a hint — free-form input
                 (hint
                  (let ((input (read-string (format "Arguments %s: " hint))))
                    (unless (string-empty-p input) input))))))
     (list name args nil)))
  (let* ((skill (cl-find skill-name (ai-agent-claude--discover-skills)
                         :key (lambda (s) (plist-get s :name))
                         :test #'equal))
         (model (or (and skill (plist-get skill :model))
                    ai-agent-claude-run-skill-model))
         (prompt (if (and arguments (not (string-empty-p arguments)))
                     (format "/%s %s" skill-name arguments)
                   (format "/%s" skill-name)))
         (buffers-before (buffer-list)))
    (message "Running /%s%s..." skill-name
             (if (and skill (plist-get skill :model))
                 (format " [%s]" model) ""))
    (ai-agent-claude--run-prompt
     prompt
     :dir (or dir default-directory)
     :model model
     :callback
     (lambda (result)
       (ai-agent-claude--skill-display-result
        skill-name result buffers-before)))))

;;;;; Batch TODO processing

(defun ai-agent-claude--batch-finish (state)
  "Display the batch processing summary buffer for STATE."
  (let* ((results (sort (plist-get state :results)
                        (lambda (a b)
                          (< (plist-get a :index) (plist-get b :index)))))
         (total (length results))
         (successes (cl-count 0 results :key (lambda (r) (plist-get r :exit-code))))
         (failures (- total successes))
         (total-cost (cl-reduce #'+ results :key (lambda (r) (plist-get r :cost))))
         (start-time (plist-get state :start-time))
         (total-time (float-time
                      (time-subtract (current-time) start-time)))
         (buf (get-buffer-create "*Claude Batch Results*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "#+title: Batch results — %s\n\n"
                        (format-time-string "%Y-%m-%d %H:%M:%S" start-time)))
        (insert (format "- Total: %d | Success: %d | Failed: %d\n" total successes failures))
        (insert (format "- Cost: $%.4f\n" total-cost))
        (insert (format "- Time: %.1f seconds\n" total-time))
        (insert (format "- Logs: [[file:%s]]\n\n" (plist-get state :log-dir)))
        (dolist (result results)
          (let ((status (if (= 0 (plist-get result :exit-code)) "DONE" "FAIL")))
            (insert (format "* %s %s\n" status (plist-get result :title)))
            (insert (format ":PROPERTIES:\n:COST: $%.4f\n:DURATION: %.1fs\n:END:\n\n"
                            (plist-get result :cost)
                            (plist-get result :duration)))
            (insert (format "Log: [[file:%s]]\n\n" (plist-get result :log-file)))
            (insert "#+begin_example\n")
            (insert (or (plist-get result :result-text) "(no output)"))
            (unless (string-suffix-p "\n" (or (plist-get result :result-text) ""))
              (insert "\n"))
            (insert "#+end_example\n\n"))))
      (org-mode)
      (goto-char (point-min)))
    (pop-to-buffer buf)
    (message "Batch complete: %d/%d succeeded (%.1fs, $%.4f)"
             successes total total-time total-cost)))

;;;;; Project audit

(defun ai-agent-claude-audit-project ()
  "Run a comprehensive audit of a project.
Prompt the user to select a project directory from
`ai-agent-claude-audit-project-directories' or enter a new one.
New directories are persisted to the list for future use.
Sequentially invokes each skill in `ai-agent-claude-audit-skills'
with `--accept', each in a separate non-interactive Claude session.
Results are displayed in a summary buffer when all audits complete."
  (interactive)
  (let* ((dir (ai-agent-claude--read-audit-project-directory))
         (entries (mapcar (lambda (skill)
                            (list :title (format "%s --accept" skill)
                                  :body ""))
                          ai-agent-claude-audit-skills)))
    (when (yes-or-no-p
           (format "Run %d audit(s) on %s?" (length entries) dir))
      (ai-agent-claude--batch-start entries dir t))))

(defun ai-agent-claude--read-audit-project-directory ()
  "Prompt the user for a project directory, with completion.
Offer `ai-agent-claude-audit-project-directories' as candidates but allow
free input.  When the entered directory is not already in the list, add it and
persist via `customize-save-variable'."
  (let* ((candidates (mapcar #'abbreviate-file-name
                             ai-agent-claude-audit-project-directories))
         (input (completing-read "Project directory: " candidates nil nil))
         (dir (file-truename (expand-file-name input))))
    (unless (file-directory-p dir)
      (user-error "Not a directory: %s" dir))
    (unless (member dir (mapcar #'file-truename
                                ai-agent-claude-audit-project-directories))
      (customize-save-variable 'ai-agent-claude-audit-project-directories
                               (append ai-agent-claude-audit-project-directories
                                       (list dir))))
    dir))

;;;;; Theme sync

(defun ai-agent-claude--sync-theme (theme)
  "Update Claude Code persistent theme settings to THEME.
THEME is either \"light\" or \"dark\".  Return the number of files
changed."
  (let ((changed 0))
    (dolist (path (ai-agent-claude--theme-config-files))
      (when (ai-agent-claude--write-claude-json-key path "theme" theme)
        (setq changed (1+ changed))))
    changed))

(defun ai-agent-claude--theme-config-files ()
  "Return Claude Code JSON files that should receive theme sync."
  (ai-agent-claude--dedupe-existing-files
   (append
    (ai-agent-claude--primary-or-existing-files
     (ai-agent-claude--all-claude-settings-paths))
    (ai-agent-claude--primary-or-existing-files
     (ai-agent-claude--all-claude-json-paths)))))

(defun ai-agent-claude--all-claude-settings-paths ()
  "Return paths to canonical and account `settings.json' files."
  (cons (expand-file-name "settings.json" "~/.claude/")
        (mapcar (lambda (entry)
                  (expand-file-name "settings.json"
                                    (expand-file-name (cdr entry))))
                ai-agent-claude-accounts)))

(defun ai-agent-claude--primary-or-existing-files (paths)
  "Return the first file from PATHS, plus any other existing files."
  (let ((primary t)
        result)
    (dolist (path paths (nreverse result))
      (when (or primary (file-exists-p path))
        (push path result))
      (setq primary nil))))

(defun ai-agent-claude--dedupe-existing-files (paths)
  "Return PATHS de-duplicated by true name when possible."
  (let (seen result)
    (dolist (path paths (nreverse result))
      (let ((key (if (file-exists-p path)
                     (file-truename path)
                   (expand-file-name path))))
        (unless (member key seen)
          (push key seen)
          (push path result))))))

(defun ai-agent-claude--write-claude-json-key (path key value)
  "Write KEY to VALUE in Claude JSON file PATH if it changed.
Return non-nil when PATH was written."
  (let ((data (if (file-exists-p path)
                  (or (ai-agent-claude--read-claude-json path)
                      (error "Invalid JSON in %s" path))
                (make-hash-table :test #'equal))))
    (unless (equal (gethash key data) value)
      (puthash key value data)
      (make-directory (file-name-directory path) t)
      (ai-agent-claude--write-claude-json path data)
      t)))

(defun ai-agent-claude--sync-theme-before-start (&rest _)
  "Persist the shared AI theme before starting a Claude Code process."
  (ai-agent-sync-theme-now)
  nil)

;;;;; Setup

;;;###autoload
(defun ai-agent-claude-setup-config ()
  "Ensure Claude Code settings contain ai-agent statusline and hooks."
  (interactive)
  (ai-agent-claude-ensure-statusline-config)
  (ai-agent-claude-ensure-stop-hook-config)
  (ai-agent-claude-ensure-notification-hook-config)
  (message "ai-agent-claude: updated %s" ai-agent-claude-settings-file))

(defun ai-agent-claude-ensure-statusline-config (&optional file)
  "Ensure FILE has a `statusLine' entry.
FILE defaults to `ai-agent-claude-settings-file'."
  (interactive)
  (ai-agent-claude--update-settings
   (or file ai-agent-claude-settings-file)
   #'ai-agent-claude--ensure-statusline))

(defun ai-agent-claude-ensure-stop-hook-config (&optional file)
  "Ensure FILE has a Claude Code `Stop' hook.
FILE defaults to `ai-agent-claude-settings-file'."
  (interactive)
  (ai-agent-claude--update-settings
   (or file ai-agent-claude-settings-file)
   #'ai-agent-claude--ensure-stop-hook))

(defun ai-agent-claude-ensure-notification-hook-config (&optional file)
  "Ensure FILE has a Claude Code `Notification' hook.
FILE defaults to `ai-agent-claude-settings-file'."
  (interactive)
  (ai-agent-claude--update-settings
   (or file ai-agent-claude-settings-file)
   #'ai-agent-claude--ensure-notification-hook))

(defun ai-agent-claude--update-settings (file updater)
  "Read JSON settings FILE, apply UPDATER, and write when changed."
  (let* ((settings (ai-agent-claude--read-json-object file))
         (before (json-serialize settings)))
    (funcall updater settings)
    (unless (equal before (json-serialize settings))
      (make-directory (file-name-directory file) t)
      (ai-agent-claude--write-claude-json file settings)
      t)))

(defun ai-agent-claude--read-json-object (file)
  "Read FILE as a JSON object, or return an empty object if missing."
  (if (not (file-exists-p file))
      (make-hash-table :test #'equal)
    (let ((data (with-temp-buffer
                  (insert-file-contents file)
                  (json-parse-buffer))))
      (unless (hash-table-p data)
        (error "Expected JSON object in %s" file))
      data)))

(defun ai-agent-claude--ensure-statusline (settings)
  "Ensure SETTINGS has an ai-agent statusline command."
  (unless (gethash "statusLine" settings)
    (puthash "statusLine" (ai-agent-claude--statusline-entry) settings)))

(defun ai-agent-claude--statusline-entry ()
  "Return the JSON object for the Claude Code statusline command."
  (ai-agent-claude--require-executable ai-agent-claude-statusline-script)
  (let ((entry (make-hash-table :test #'equal)))
    (puthash "type" "command" entry)
    (puthash "command" (ai-agent-claude--statusline-command) entry)
    (puthash "padding" 0 entry)
    entry))

(defun ai-agent-claude--statusline-command ()
  "Return the shell command for the bundled statusline script."
  (format "AI_AGENT_CLAUDE_STATUS_DIR=%s %s"
          (shell-quote-argument
           (directory-file-name
            (expand-file-name ai-agent-claude-status-directory)))
          (shell-quote-argument ai-agent-claude-statusline-script)))

(defun ai-agent-claude--ensure-stop-hook (settings)
  "Ensure SETTINGS has the ai-agent Stop hook."
  (ai-agent-claude--ensure-hook
   settings "Stop" (ai-agent-claude--stop-hook-command) nil))

(defun ai-agent-claude--ensure-notification-hook (settings)
  "Ensure SETTINGS has the ai-agent Notification hook."
  (ai-agent-claude--ensure-hook
   settings "Notification" (ai-agent-claude--notification-hook-command) 5))

(defun ai-agent-claude--ensure-hook (settings name command timeout)
  "Ensure SETTINGS hook NAME includes COMMAND with optional TIMEOUT."
  (let* ((hooks (ai-agent-claude--ensure-hooks settings))
         (entries (ai-agent-claude--json-list (gethash name hooks))))
    (unless (ai-agent-claude--hook-command-present-p entries command)
      (puthash name
               (vconcat entries
                        (vector (ai-agent-claude--hook-entry command timeout)))
               hooks))))

(defun ai-agent-claude--ensure-hooks (settings)
  "Return SETTINGS' `hooks' object, creating it when needed."
  (let ((hooks (gethash "hooks" settings)))
    (unless (hash-table-p hooks)
      (setq hooks (make-hash-table :test #'equal))
      (puthash "hooks" hooks settings))
    hooks))

(defun ai-agent-claude--json-list (value)
  "Return JSON array VALUE as a list."
  (cond
   ((vectorp value) (append value nil))
   ((listp value) value)
   (t nil)))

(defun ai-agent-claude--hook-command-present-p (entries command)
  "Return non-nil if ENTRIES already contain hook COMMAND."
  (cl-some
   (lambda (entry)
     (cl-some
      (lambda (hook)
        (and (hash-table-p hook)
             (equal (gethash "command" hook) command)))
      (ai-agent-claude--json-list (and (hash-table-p entry)
                                       (gethash "hooks" entry)))))
   entries))

(defun ai-agent-claude--hook-entry (command &optional timeout)
  "Return a Claude Code hook entry object for COMMAND.
TIMEOUT, when non-nil, is written as the hook command timeout."
  (let ((entry (make-hash-table :test #'equal)))
    (puthash "matcher" "" entry)
    (puthash "hooks" (vector (ai-agent-claude--hook-command command timeout))
             entry)
    entry))

(defun ai-agent-claude--hook-command (command &optional timeout)
  "Return a Claude Code command hook object for COMMAND.
TIMEOUT, when non-nil, is written as the hook command timeout."
  (let ((hook (make-hash-table :test #'equal)))
    (puthash "type" "command" hook)
    (puthash "command" command hook)
    (when timeout
      (puthash "timeout" timeout hook))
    hook))

(defun ai-agent-claude--stop-hook-command ()
  "Return the command string for the Stop hook."
  (format "%s stop"
          (shell-quote-argument (ai-agent-claude--hook-wrapper))))

(defun ai-agent-claude--hook-wrapper ()
  "Return a verified path to `claude-code-hook-wrapper'."
  (ai-agent-claude--require-executable ai-agent-claude-hook-wrapper))

(defun ai-agent-claude--notification-hook-command ()
  "Return the command string for the Notification hook in settings.json."
  (let ((fire-and-forget
         (expand-file-name "fire-and-forget.sh"
                           ai-agent-claude--hooks-directory))
        (notification
         (expand-file-name "notify-emacs-notification.sh"
                           ai-agent-claude--hooks-directory)))
    (ai-agent-claude--require-executable fire-and-forget)
    (ai-agent-claude--require-executable notification)
    (format "%s %s"
            (shell-quote-argument fire-and-forget)
            (shell-quote-argument notification))))

(defun ai-agent-claude--require-executable (file)
  "Return FILE or signal an error if it is not executable."
  (unless (and file (file-executable-p file))
    (error "Executable not found: %s" file))
  file)

(defun ai-agent-claude--has-statusline-key-p ()
  "Return non-nil if the current buffer has a `statusLine' JSON key."
  (when-let* ((settings (ai-agent-claude--parse-current-json-object)))
    (gethash "statusLine" settings)))

(defun ai-agent-claude--has-stop-hook-p ()
  "Return non-nil if the current buffer has a `Stop' hook."
  (when-let* ((settings (ai-agent-claude--parse-current-json-object))
              (hooks (gethash "hooks" settings)))
    (and (hash-table-p hooks) (gethash "Stop" hooks))))

(defun ai-agent-claude--has-notification-hook-p ()
  "Return non-nil if the current buffer has a configured Notification hook."
  (when-let* ((settings (ai-agent-claude--parse-current-json-object))
              (hooks (gethash "hooks" settings))
              ((hash-table-p hooks))
              (entries (ai-agent-claude--json-list
                        (gethash "Notification" hooks))))
    (cl-some
     (lambda (entry)
       (cl-some
        (lambda (hook)
          (and (hash-table-p hook)
               (string-match-p
                "notify-emacs-notification"
                (or (gethash "command" hook) ""))))
        (ai-agent-claude--json-list (gethash "hooks" entry))))
     entries)))

(defun ai-agent-claude--parse-current-json-object ()
  "Parse the current buffer as a JSON object, returning nil on failure."
  (save-excursion
    (goto-char (point-min))
    (condition-case nil
        (let ((data (json-parse-buffer)))
          (and (hash-table-p data) data))
      (error nil))))

;; Work around upstream bug: `claude-code--adjust-window-size-advice' crashes
;; when `claude-code--window-widths' is nil or void during redisplay.
(defvar claude-code--window-widths nil)
(unless (hash-table-p claude-code--window-widths)
  (setq claude-code--window-widths
        (make-hash-table :test 'eq :weakness 'key)))

(defun ai-agent-claude-disable-scrollback-truncation ()
  "Disable eat scrollback truncation in Claude Code buffers.
The default `eat-term-scrollback-size' of 131072 characters causes the
buffer to be truncated, losing earlier output."
  (interactive)
  (setq-local eat-term-scrollback-size nil))


;; Fix upstream scroll function.  Two problems:
;;
;; 1. `eat--synchronize-scroll-windows' only includes windows whose
;;    `window-point' equals the terminal cursor.  When eat modifies the
;;    buffer during a terminal redraw, Emacs can reset window-point to 1
;;    for non-selected windows.  Once that happens the equality check
;;    fails and the window is permanently excluded from sync.
;;
;; 2. The upstream conditional recenter (checking `pos-visible-in-window-p')
;;    can miss recenters when display state is stale.
;;
;; We fix both by re-including any desynchronized windows and always
;; recentering with `(recenter -1)'.
(advice-add 'claude-code--eat-synchronize-scroll :override
            #'ai-agent-claude--eat-synchronize-scroll)

(defun ai-agent-claude--eat-synchronize-scroll (windows)
  "Keep the terminal cursor at the bottom of WINDOWS.
Re-include any windows showing this buffer that were excluded from
WINDOWS because their point drifted from the cursor, then
unconditionally recenter with `(recenter -1)'."
  (when (not buffer-read-only)
    (let ((cursor-pos (eat-term-display-cursor eat-terminal)))
      ;; Re-include windows that fell out of sync (point != cursor).
      (dolist (w (get-buffer-window-list nil nil t))
        (unless (memq w windows)
          (push w windows)))
      (dolist (window windows)
        (if (eq window 'buffer)
            (goto-char cursor-pos)
          (set-window-point window cursor-pos)
          (with-selected-window window
            (goto-char cursor-pos)
            (recenter -1)))))))

;;;;; Debug backtrace

(defcustom ai-agent-claude-debug-backtrace-model 'gemini-flash-lite-latest
  "GPtel model for identifying candidate packages from a backtrace."
  :type 'symbol
  :group 'ai-agent-claude)

(defcustom ai-agent-claude-debug-backtrace-backend "Gemini"
  "GPtel backend name for backtrace analysis."
  :type 'string
  :group 'ai-agent-claude)

(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-use-tools)
(defvar gptel--known-backends)
(declare-function debug-save-backtrace "init" ())
(declare-function gptel-request "gptel")
(declare-function elpaca-get "elpaca")
(declare-function elpaca-source-dir "elpaca")
(declare-function find-library-name "find-func")

;;;###autoload
(defun ai-agent-claude-debug-backtrace ()
  "Save the backtrace, choose the offending package, and open Claude Code.
Use `debug-save-backtrace' to save the backtrace to the downloads
directory, then ask a light LLM (via `gptel') to list all packages
implicated in the error.  The user selects the right one via
`completing-read', then an interactive Claude Code session starts
in that package's source directory with the backtrace file path."
  (interactive)
  (let ((backtrace-file (expand-file-name "backtrace.el" paths-dir-downloads)))
    ;; Schedule the identification work to run after the current command.
    ;; `debug-save-backtrace' kills the *Backtrace* buffer, which exits the
    ;; debugger's `recursive-edit' and unwinds this call frame.
    (run-with-timer 0 nil #'ai-agent-claude--debug-identify-package backtrace-file)
    (debug-save-backtrace)))

(defun ai-agent-claude--debug-identify-package (backtrace-file)
  "Identify candidate packages from BACKTRACE-FILE and let the user choose.
Ask a light LLM to list all packages implicated in the backtrace,
then present the list via `completing-read' so the user can select
the right one before starting a Claude Code session."
  (unless (file-exists-p backtrace-file)
    (user-error "Backtrace file not found: %s" backtrace-file))
  (message "Identifying packages from backtrace...")
  (let ((contents (with-temp-buffer
                    (insert-file-contents backtrace-file)
                    (buffer-string)))
        (gptel-backend (alist-get ai-agent-claude-debug-backtrace-backend
                                 gptel--known-backends nil nil #'string=))
        (gptel-model ai-agent-claude-debug-backtrace-model)
        (gptel-use-tools nil))
    (gptel-request
     (format "Backtrace file: %s\n\nContents:\n%s" backtrace-file contents)
     :system "You are an Emacs expert. Given the backtrace, identify ALL Emacs packages that appear in the stack trace and could be the root cause of the error. Return ONLY a comma-separated list of package names, ordered from most likely root cause to least likely. For example: \"org-roam, org, emacsql\" or \"magit, transient, with-editor\"."
     :callback
     (lambda (response info)
       (if (not response)
           (message "gptel request failed: %s" (plist-get info :status))
         (let* ((candidates (mapcar #'string-trim (split-string response ",")))
                (selected (completing-read "Package to debug: " candidates nil nil nil nil
                                           (car candidates))))
           (ai-agent-claude--debug-start-session
            (intern selected) backtrace-file)))))))

(declare-function claude-code--start "claude-code")

(defun ai-agent-claude--debug-start-session (package backtrace-file)
  "Start a Claude Code session for PACKAGE with BACKTRACE-FILE.
Find the elpaca source directory for PACKAGE, start Claude Code
there with the backtrace prompt passed as a CLI argument."
  (let* ((elpaca-entry (elpaca-get package))
         (dir (cond
               (elpaca-entry (elpaca-source-dir elpaca-entry))
               ((condition-case nil
                    (file-name-directory (find-library-name (symbol-name package)))
                  (error nil)))
               (t (user-error "Package `%s' not found" package))))
         (prompt (format "Read the backtrace at %s. Identify the bug, fix it, and commit the fix."
                         backtrace-file)))
    (message "Starting Claude Code for `%s' in %s..." package dir)
    (cl-letf (((symbol-function 'claude-code--directory) (lambda () dir)))
      (claude-code--start nil (list prompt) nil t))))

(setq claude-code-notification-function #'claude-code-default-notification)
(add-hook 'claude-code-event-hook #'ai-agent-claude--handle-notification)
(add-hook 'claude-code-event-hook #'ai-agent-claude--handle-stop)
(add-hook 'kill-buffer-query-functions #'ai-agent-protect-buffer)
(add-hook 'claude-code-start-hook #'ai-agent-claude-setup-kill-on-exit)
(add-hook 'claude-code-start-hook #'ai-agent-claude-start-status-polling)
(add-hook 'claude-code-start-hook #'ai-agent-claude--capture-buffer-account)
(add-hook 'claude-code-start-hook #'ai-agent-claude-set-modeline)
(add-hook 'claude-code-start-hook #'ai-agent--refresh-display-names)
(add-hook 'kill-buffer-hook #'ai-agent-claude-stop-status-polling)
(add-hook 'kill-buffer-hook #'ai-agent--refresh-display-names-deferred)
(add-hook 'kill-buffer-hook #'ai-agent-claude--cleanup-monet-session)
(add-hook 'claude-code-start-hook #'ai-agent-disable-scrollback-truncation)
(add-hook 'claude-code-start-hook #'ai-agent-setup-snippet-keys)
(add-hook 'claude-code-start-hook #'ai-agent--assign-session-key)
(add-hook 'claude-code-start-hook #'ai-agent-claude-setup-copilot)
(add-hook 'claude-code-process-environment-functions
          #'ai-agent-claude--sync-theme-before-start)
(add-hook 'kill-buffer-hook #'ai-agent--release-session-key)
(add-hook 'kill-buffer-hook #'ai-agent-claude-teardown-copilot)
(advice-add 'claude-code--eat-send-return :before
            #'ai-agent--clear-waiting-for-input)
(advice-add 'claude-code--vterm-send-return :before
            #'ai-agent--clear-waiting-for-input)
(advice-add 'claude-code--do-send-command :before
            #'ai-agent--clear-waiting-for-input)

;;;;; Handoff

(defconst ai-agent-claude-handoff-file
  "/tmp/claude-code-handoff.md"
  "Path to the handoff file written by the `/handoff' skill.")

;;;###autoload
(defun ai-agent-claude-handoff ()
  "Close this Claude session and start a new one with the handoff prompt.
The `/handoff' skill must have been run first to write the handoff
file.  The new session starts in the same project directory with
the handoff contents passed as a CLI argument."
  (interactive)
  (unless (file-exists-p ai-agent-claude-handoff-file)
    (user-error "No handoff file at %s — run /handoff first"
                ai-agent-claude-handoff-file))
  (let* ((prompt (ai-agent-claude--read-handoff-file))
         (dir (ai-agent-claude--handoff-directory)))
    (when (string-empty-p prompt)
      (user-error "Handoff file is empty — run /handoff first"))
    (ai-agent-claude--kill-current-claude-buffer)
    (cl-letf (((symbol-function 'claude-code--directory) (lambda () dir)))
      (claude-code--start nil (list prompt) nil t))))

(defun ai-agent-claude--read-handoff-file ()
  "Read and return the trimmed contents of the handoff file."
  (with-temp-buffer
    (insert-file-contents ai-agent-claude-handoff-file)
    (string-trim (buffer-string))))

(defun ai-agent-claude--handoff-directory ()
  "Return the project directory for the handoff session.
Uses the current Claude buffer's directory if in one."
  (if (claude-code--buffer-p (current-buffer))
      default-directory
    (claude-code--directory)))

(defun ai-agent-claude--kill-current-claude-buffer ()
  "Kill the current buffer if it is a Claude session.
Bypasses the kill-protection query."
  (when (claude-code--buffer-p (current-buffer))
    (ai-agent--force-kill-buffer (current-buffer))))

;;;;; Restart

;;;###autoload
(defun ai-agent-claude-restart ()
  "Kill the current Claude session and resume it in place.
Useful when a setting change requires relaunching Claude.  Preserves the
session's directory and instance name, and uses the currently active
account (from `ai-agent-claude-accounts'), so the result is
equivalent to manually closing the session and reopening it."
  (interactive)
  (unless (claude-code--buffer-p (current-buffer))
    (user-error "Not in a Claude buffer"))
  (let* ((account (ai-agent-claude--resolve-account))
         (ai-agent-claude--pending-account account)
         (session-id (ai-agent-claude--current-session-id))
         (dir default-directory)
         (instance-name (claude-code--extract-instance-name-from-buffer-name
                         (buffer-name))))
    (when account
      (ai-agent-claude--sync-account-config account))
    (ai-agent-claude--kill-current-claude-buffer)
    (cl-letf (((symbol-function 'claude-code--directory) (lambda () dir))
              ((symbol-function 'claude-code--prompt-for-instance-name)
               (lambda (_dir _existing _force) instance-name)))
      (claude-code--start nil (list "--resume" session-id) nil t))))

;;;;; Branch navigation

(require 'iso8601)

(defun ai-agent-claude--read-session-header (jsonl-file)
  "Read first line of JSONL-FILE and return a lightweight metadata plist.
Returns (:session-id :forked-from :fork-uuid :file-path) or nil.
This is fast (reads only first few KB) and is used for the initial
scan to build the branch tree."
  (condition-case nil
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8))
          (insert-file-contents jsonl-file nil 0 65536))
        (goto-char (point-min))
        (let* ((line (buffer-substring-no-properties
                      (point) (line-end-position)))
               (json (json-parse-string line :object-type 'plist))
               (forked (plist-get json :forkedFrom)))
          (list :session-id (plist-get json :sessionId)
                :forked-from (when forked (plist-get forked :sessionId))
                :fork-uuid (when forked (plist-get forked :messageUuid))
                :file-path jsonl-file)))
    (error nil)))

(defun ai-agent-claude--read-session-prompt (header)
  "Enrich HEADER plist with :first-prompt and :timestamp.
Reads the full JSONL file referenced by HEADER's :file-path."
  (let ((file (plist-get header :file-path))
        (fork-uuid (plist-get header :fork-uuid))
        (session-id (plist-get header :session-id))
        (forked-from (plist-get header :forked-from)))
    (condition-case nil
        (with-temp-buffer
          (let ((coding-system-for-read 'utf-8))
            (insert-file-contents file))
          (goto-char (point-min))
          (if fork-uuid
              (ai-agent-claude--branch-prompt
               session-id forked-from fork-uuid)
            (ai-agent-claude--root-prompt session-id)))
      (error (list :session-id session-id
                   :forked-from forked-from
                   :first-prompt "(error reading session)"
                   :timestamp nil)))))

(defun ai-agent-claude--user-message-prompt-p (json)
  "Return non-nil if JSON is a user message with text content."
  (and (equal (plist-get json :type) "user")
       (let* ((msg (plist-get json :message))
              (content (when msg (plist-get msg :content))))
         (and (stringp content)
              (not (string-empty-p (string-trim content)))))))

(defun ai-agent-claude--root-prompt (session-id)
  "Find the first user prompt in the current buffer for SESSION-ID."
  (goto-char (point-min))
  (let ((result nil))
    (while (and (not result) (not (eobp)))
      (let ((json (ai-agent-claude--parse-jsonl-line)))
        (when (and json (ai-agent-claude--user-message-prompt-p json))
          (setq result (ai-agent-claude--meta-from-json
                        session-id nil json))))
      (forward-line 1))
    (or result
        (list :session-id session-id :forked-from nil
              :first-prompt "(no prompt)" :timestamp nil))))

(defun ai-agent-claude--branch-prompt (session-id forked-from fork-uuid)
  "Find the first new user prompt after FORK-UUID in the current buffer.
SESSION-ID and FORKED-FROM are passed through to the result."
  (goto-char (point-min))
  (let ((found-fork nil)
        (result nil))
    (while (and (not result) (not (eobp)))
      (let ((json (ai-agent-claude--parse-jsonl-line)))
        (when json
          (if (not found-fork)
              (when (string= (plist-get json :uuid) fork-uuid)
                (setq found-fork t))
            (when (ai-agent-claude--user-message-prompt-p json)
              (setq result (ai-agent-claude--meta-from-json
                            session-id forked-from json))))))
      (forward-line 1))
    (or result
        (list :session-id session-id
              :forked-from forked-from
              :first-prompt "(branch)"
              :timestamp nil))))

(defun ai-agent-claude--parse-jsonl-line ()
  "Parse the current line as JSON, returning a plist or nil."
  (let ((line (buffer-substring-no-properties
               (line-beginning-position) (line-end-position))))
    (unless (string-empty-p line)
      (condition-case nil
          (json-parse-string line :object-type 'plist)
        (error nil)))))

(defun ai-agent-claude--meta-from-json (session-id forked-from json)
  "Build metadata plist from SESSION-ID, FORKED-FROM id, and message JSON."
  (let* ((msg (plist-get json :message))
         (content (when msg (plist-get msg :content))))
    (list :session-id session-id
          :forked-from forked-from
          :first-prompt (ai-agent-claude--truncate-prompt content)
          :timestamp (plist-get json :timestamp))))

(defun ai-agent-claude--truncate-prompt (content)
  "Truncate CONTENT to a short display string."
  (if (stringp content)
      (truncate-string-to-width
       (replace-regexp-in-string "[\n\r\t]+" " " (string-trim content))
       60 nil nil "…")
    "(no prompt)"))

(defun ai-agent-claude--scan-session-headers (project-dir)
  "Scan JSONL files in PROJECT-DIR and return session headers.
Returns a hash table mapping session ID to a lightweight header
plist.  Only reads the first line of each file (fast)."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (file (directory-files project-dir t "\\.jsonl\\'"))
      (let ((header (ai-agent-claude--read-session-header file)))
        (when (and header (plist-get header :session-id))
          (puthash (plist-get header :session-id) header table))))
    table))

(defun ai-agent-claude--enrich-sessions (headers member-ids)
  "Enrich session HEADERS with full prompt text for MEMBER-IDS.
HEADERS is a hash table of session ID to header plist.  MEMBER-IDS
is a hash table of session IDs to include.  Return a new hash table
with :first-prompt and :timestamp populated."
  (let ((table (make-hash-table :test 'equal)))
    (maphash (lambda (id header)
               (when (gethash id member-ids)
                 (puthash id (ai-agent-claude--read-session-prompt header)
                          table)))
             headers)
    table))

(defun ai-agent-claude--find-branch-root (session-id sessions)
  "Follow forkedFrom chain from SESSION-ID upward in SESSIONS hash table.
Returns the root session ID."
  (let ((current session-id)
        (seen (make-hash-table :test 'equal)))
    (catch 'done
      (while t
        (puthash current t seen)
        (let* ((meta (gethash current sessions))
               (parent (when meta (plist-get meta :forked-from))))
          (if (and parent (gethash parent sessions) (not (gethash parent seen)))
              (setq current parent)
            (throw 'done current)))))))

(defun ai-agent-claude--build-children-map (sessions)
  "Build hash table mapping parent session ID to sorted list of child IDs.
SESSIONS is a hash table of session ID to metadata.  Children are
sorted by timestamp."
  (let ((map (make-hash-table :test 'equal)))
    (maphash (lambda (_id meta)
               (let ((parent (plist-get meta :forked-from)))
                 (when (and parent (gethash parent sessions))
                   (push (plist-get meta :session-id)
                         (gethash parent map)))))
             sessions)
    (maphash (lambda (parent children)
               (puthash parent
                        (sort children
                              (lambda (a b)
                                (string< (or (plist-get (gethash a sessions) :timestamp) "")
                                         (or (plist-get (gethash b sessions) :timestamp) ""))))
                        map))
             map)
    map))

(defun ai-agent-claude--collect-tree-members (root-id children-map)
  "Return hash table of all session IDs reachable from ROOT-ID via CHILDREN-MAP."
  (let ((members (make-hash-table :test 'equal))
        (queue (list root-id)))
    (while queue
      (let ((id (pop queue)))
        (unless (gethash id members)
          (puthash id t members)
          (dolist (child (gethash id children-map))
            (push child queue)))))
    members))

(defun ai-agent-claude--format-branch-timestamp (iso-ts)
  "Format ISO-TS as \"Mon DD HH:MM\" for branch display."
  (when iso-ts
    (condition-case nil
        (format-time-string "%b %d %H:%M"
                            (encode-time (iso8601-parse iso-ts)))
      (error (substring iso-ts 0 (min 16 (length iso-ts)))))))

(defun ai-agent-claude--format-branch-tree (root-id sessions children-map current-id)
  "Format the branch tree rooted at ROOT-ID as an alist.
SESSIONS maps IDs to metadata, CHILDREN-MAP maps parent to child
IDs, CURRENT-ID is the active session.  Returns an alist of
\(display-string . session-id)."
  (ai-agent-claude--format-branch-subtree
   root-id sessions children-map current-id "" ""))

(defun ai-agent-claude--format-branch-subtree
    (id sessions children-map current-id prefix child-prefix)
  "Format branch node ID and its children recursively.
SESSIONS maps IDs to metadata, CHILDREN-MAP maps parent to child
IDs, CURRENT-ID is the active session.  PREFIX is the tree connector
for this node, CHILD-PREFIX is the continuation for children.
Return a list of (display . session-id)."
  (let* ((meta (gethash id sessions))
         (prompt (or (plist-get meta :first-prompt) "(no prompt)"))
         (ts (ai-agent-claude--format-branch-timestamp
              (plist-get meta :timestamp)))
         (marker (if (string= id current-id) " *" ""))
         (display (format "%s%s  %s%s" prefix prompt (or ts "") marker))
         (children (gethash id children-map))
         (len (length children))
         (result (list (cons display id))))
    (cl-loop for child in children
             for i from 0
             for last-p = (= i (1- len))
             do (setq result
                      (nconc result
                             (ai-agent-claude--format-branch-subtree
                              child sessions children-map current-id
                              (concat child-prefix (if last-p "└─ " "├─ "))
                              (concat child-prefix (if last-p "   " "│  "))))))
    result))

(defun ai-agent-claude--find-buffer-for-session (session-id)
  "Return a live Claude buffer whose session matches SESSION-ID, or nil."
  (cl-find-if
   (lambda (buf)
     (when (buffer-live-p buf)
       (with-current-buffer buf
         (let ((status (ai-agent-claude--parse-status-file)))
           (and status
                (string= (plist-get status :session_id) session-id))))))
   (claude-code--find-all-claude-buffers)))

;;;###autoload
(defun ai-agent-claude-switch-branch ()
  "Navigate between branches of the current Claude session.
Shows a tree of all sessions related by branching and lets you
select one to switch to or resume."
  (interactive)
  (unless (claude-code--buffer-p (current-buffer))
    (user-error "Not in a Claude buffer"))
  (let ((status (ai-agent-claude--parse-status-file)))
    (unless status
      (user-error "No status file; is status polling enabled?"))
    (let ((session-id (plist-get status :session_id))
          (transcript (plist-get status :transcript_path)))
      (unless (and session-id transcript)
        (user-error "Status file missing session_id or transcript_path"))
      (let* ((project-dir (file-name-directory transcript))
             (headers (ai-agent-claude--scan-session-headers project-dir))
             (children-map (ai-agent-claude--build-children-map headers))
             (root-id (ai-agent-claude--find-branch-root session-id headers))
             (members (ai-agent-claude--collect-tree-members root-id children-map)))
        (when (<= (hash-table-count members) 1)
          (user-error "No branches for this session"))
        (let* ((sessions (ai-agent-claude--enrich-sessions headers members))
               (tree-children (ai-agent-claude--build-children-map sessions))
               (tree (ai-agent-claude--format-branch-tree
                      root-id sessions tree-children session-id))
               (selection (consult--read
                           (mapcar #'car tree)
                           :prompt "Branch: "
                           :require-match t
                           :sort nil))
               (selected-id (cdr (assoc selection tree))))
          (cond
           ((string= selected-id session-id)
            (message "Already on this session"))
           ((ai-agent-claude--find-buffer-for-session selected-id)
            (switch-to-buffer
             (ai-agent-claude--find-buffer-for-session selected-id)))
           (t
            (ai-agent-claude--resume-session selected-id))))))))

(defun ai-agent-claude--resume-session (session-id)
  "Resume SESSION-ID in a new Claude buffer.
Auto-generates an instance name from the session ID to avoid the
interactive instance-name prompt."
  (cl-letf (((symbol-function 'claude-code--prompt-for-instance-name)
             (lambda (_dir _existing _force)
               (format "branch-%s" (substring session-id 0 8)))))
    (claude-code--start nil (list "--resume" session-id) nil t)))

;;;###autoload
(defun ai-agent-claude-create-branch (&optional isolated)
  "Create a branch of the current Claude session and switch to it.
Forks the current session via `--resume --fork-session' and opens
the new branch in a separate buffer.  By default the fork shares
the parent's working tree, matching the behavior of launching a
second Claude instance in the same project.

With prefix arg ISOLATED, also create a git worktree on a fresh
branch under `ai-agent-claude-fork-worktree-directory' and run
the fork inside it.  The worktree starts at the parent's HEAD,
so uncommitted parent changes are NOT carried over.  Use this
when concurrent destructive git operations across forks are a
concern; otherwise the default is what you want."
  (interactive "P")
  (unless (claude-code--buffer-p (current-buffer))
    (user-error "Not in a Claude buffer"))
  (let* ((session-id (ai-agent-claude--current-session-id))
         (parent-cwd default-directory)
         (fork-id (format-time-string "%H%M%S"))
         (worktree (and isolated
                        (ai-agent-claude--make-fork-worktree
                         (or (ai-agent-claude--git-toplevel)
                             (user-error "Not in a git repo; cannot isolate"))
                         fork-id))))
    (when worktree
      (ai-agent-claude--link-session-into-project
       session-id parent-cwd (car worktree)))
    (cl-letf (((symbol-function 'claude-code--prompt-for-instance-name)
               (lambda (_dir _existing _force)
                 (format "fork-%s" fork-id))))
      (let ((default-directory (or (car worktree) default-directory)))
        (claude-code--start nil
                            (list "--resume" session-id "--fork-session")
                            nil t)))
    (when worktree
      (message "Forked in worktree %s on branch %s"
               (car worktree) (cdr worktree)))))

(defun ai-agent-claude--git-toplevel (&optional dir)
  "Return git toplevel for DIR (or `default-directory'), or nil if none."
  (let ((default-directory (or dir default-directory)))
    (with-temp-buffer
      (when (zerop (call-process "git" nil t nil
                                 "rev-parse" "--show-toplevel"))
        (file-name-as-directory (string-trim (buffer-string)))))))

(defun ai-agent-claude--make-fork-worktree (toplevel fork-id)
  "Create a git worktree of TOPLEVEL identified by FORK-ID.
Returns a cons (PATH . BRANCH-NAME).  Signals an error on failure."
  (let* ((repo-name (file-name-nondirectory (directory-file-name toplevel)))
         (branch-name (format "claude-fork-%s" fork-id))
         (worktree-path (file-name-as-directory
                         (expand-file-name
                          (format "%s-fork-%s" repo-name fork-id)
                          ai-agent-claude-fork-worktree-directory))))
    (make-directory ai-agent-claude-fork-worktree-directory t)
    (ai-agent-claude--git-worktree-add toplevel branch-name worktree-path)
    (cons worktree-path branch-name)))

(defun ai-agent-claude--git-worktree-add (toplevel branch-name worktree-path)
  "Run `git worktree add' in TOPLEVEL for BRANCH-NAME at WORKTREE-PATH."
  (let ((default-directory toplevel))
    (with-temp-buffer
      (let ((exit (call-process "git" nil t nil
                                "worktree" "add" "-b" branch-name
                                (directory-file-name worktree-path))))
        (unless (zerop exit)
          (error "git worktree add failed: %s"
                 (string-trim (buffer-string))))))))

(defun ai-agent-claude--link-session-into-project (session-id source-cwd target-cwd)
  "Symlink SESSION-ID's JSONL from SOURCE-CWD's project dir into TARGET-CWD's.
Lets `--resume SESSION-ID' find the session when the CLI runs from
TARGET-CWD instead of SOURCE-CWD, since Claude Code stores sessions
under `~/.claude/projects/<encoded-cwd>/'."
  (let* ((filename (concat session-id ".jsonl"))
         (src (expand-file-name
               filename
               (ai-agent-claude--project-dir-for source-cwd)))
         (dst-dir (ai-agent-claude--project-dir-for target-cwd))
         (dst (expand-file-name filename dst-dir)))
    (unless (file-exists-p src)
      (error "Session JSONL not found: %s" src))
    (make-directory dst-dir t)
    (unless (file-exists-p dst)
      (make-symbolic-link src dst))))

(defun ai-agent-claude--project-dir-for (cwd)
  "Return the `~/.claude/projects/' directory that Claude Code uses for CWD."
  (expand-file-name (ai-agent-claude--encode-project-cwd cwd)
                    "~/.claude/projects/"))

(defun ai-agent-claude--encode-project-cwd (path)
  "Encode PATH the way Claude Code names dirs under `~/.claude/projects/'."
  (replace-regexp-in-string
   "[^A-Za-z0-9-]" "-"
   (directory-file-name (expand-file-name path))))

(defun ai-agent-claude--current-session-id ()
  "Return the session ID of the current Claude buffer.
Signals an error if the status file is missing or incomplete."
  (let ((status (ai-agent-claude--parse-status-file)))
    (unless status
      (user-error "No status file; is status polling enabled?"))
    (or (plist-get status :session_id)
        (user-error "Status file missing session_id"))))

;;;; Extend unified menu

(transient-define-infix ai-agent-claude--infix-copilot-enabled ()
  "Toggle `ai-agent-claude-copilot-enabled'."
  :class 'ai-agent--boolean-variable
  :variable 'ai-agent-claude-copilot-enabled
  :description "copilot")

(transient-define-infix ai-agent-claude--infix-warn-kill-with-branches ()
  "Toggle `ai-agent-claude-warn-kill-with-branches'."
  :class 'ai-agent--boolean-variable
  :variable 'ai-agent-claude-warn-kill-with-branches
  :description "warn kill with branches")

(eval-and-compile
  (defclass ai-agent-claude--account-variable (transient-lisp-variable)
    ()
    "An infix that displays and selects the active Claude account."))

(cl-defmethod transient-infix-read ((_obj ai-agent-claude--account-variable))
  "Prompt for a Claude account."
  (ai-agent-claude--prompt-account))

(cl-defmethod transient-infix-set ((obj ai-agent-claude--account-variable) value)
  "Set the account variable and persist VALUE to disk."
  (cl-call-next-method obj value)
  (when value
    (ai-agent-claude--save-account value)
    (ai-agent-claude--sync-account-config value)))

(cl-defmethod transient-init-value ((obj ai-agent-claude--account-variable))
  "Initialize OBJ from disk if the variable is nil."
  (unless (symbol-value (oref obj variable))
    (set (oref obj variable) (ai-agent-claude--load-account)))
  (cl-call-next-method obj))

(transient-define-infix ai-agent-claude--infix-account ()
  "Select the active Claude account."
  :class 'ai-agent-claude--account-variable
  :variable 'ai-agent-claude--current-account
  :description "account")

(with-eval-after-load 'ai-agent
  ;; Sessions: after "exit session"
  (transient-append-suffix 'ai-agent-menu "x"
    '("B" "switch branch" ai-agent-claude-switch-branch))
  (transient-append-suffix 'ai-agent-menu "B"
    '("N" "new branch" ai-agent-claude-create-branch))
  ;; Tools: after "debug backtrace"
  (transient-append-suffix 'ai-agent-menu "d"
    '("b" "batch todos" ai-agent-claude-batch-todos))
  (transient-append-suffix 'ai-agent-menu "b"
    '("t" "send todo at point" ai-agent-claude-send-todo-at-point))
  (transient-append-suffix 'ai-agent-menu "t"
    '("l" "logs" agent-log-menu))
  ;; Alerts: after "toggle alert"
  (transient-append-suffix 'ai-agent-menu "T"
    '("p" "start status polling" ai-agent-claude-start-status-polling))
  (transient-append-suffix 'ai-agent-menu "p"
    '("P" "stop status polling" ai-agent-claude-stop-status-polling))
  ;; Options: after "protect buffers"
  (transient-append-suffix 'ai-agent-menu "-p"
    '("-a" ai-agent-claude--infix-account))
  (transient-append-suffix 'ai-agent-menu "-t"
    '("-c" ai-agent-claude--infix-copilot-enabled))
  (transient-append-suffix 'ai-agent-menu "-c"
    '("-w" ai-agent-claude--infix-warn-kill-with-branches)))

(provide 'ai-agent-claude)
;;; ai-agent-claude.el ends here
