;;; agents.el --- Shared extensions for AI coding CLI tools -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/agents
;; Version: 0.1
;; Package-Requires: ((emacs "30.0") (transient "0.9") (consult "1.0"))

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

;; Shared abstractions for AI coding CLI tool extensions.
;; Provides backend-agnostic session management, notifications, and
;; terminal integration for packages like `agents-claude' and
;; `agents-codex'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(eval-and-compile (require 'transient))

;;;; Custom group

(defgroup agents ()
  "Shared extensions for AI coding CLI tools."
  :group 'tools)

(defcustom agents-before-exit-functions nil
  "Abnormal hook run before `agents-exit' exits a session.
Each function is called with two arguments: the resolved BACKEND
symbol and the session BUFFER.  If any function returns nil, the
exit is aborted."
  :type 'hook
  :group 'agents)

(defcustom agents-before-exit-skill-name nil
  "Skill name to submit before exiting matching AI sessions.
When nil or empty, `agents-run-skill-before-exit' does nothing."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'agents)

(defcustom agents-before-exit-skill-directories nil
  "Directories whose sessions should run `agents-before-exit-skill-name'."
  :type '(repeat directory)
  :group 'agents)

(defcustom agents-skill-command-prefix-alist
  '((claude-code . "/")
    (codex . "$"))
  "Alist mapping backend symbols to interactive skill command prefixes."
  :type '(alist :key-type symbol :value-type string)
  :group 'agents)

(defvar-local agents--before-exit-skill-sent nil
  "Non-nil when the configured before-exit skill was sent in this buffer.")

;;;; Backend registry

(defvar agents-backends nil
  "Alist of registered AI backends.
Each entry is (SYMBOL . PLIST) where PLIST has keys:
  :buffer-p              function (buffer) -> bool
  :find-all-buffers      function () -> list of buffers
  :find-buffers-for-dir  function (dir) -> list of buffers
  :directory             function (buffer) -> directory string
  :extract-directory     function (buffer-name) -> directory string
  :extract-instance-name function (buffer-name) -> instance or nil
  :send-command          function (cmd &optional buffer)
  :start                 function (arg extra-switches
                           &optional force-prompt force-switch)
  :start-new             function () -> buffer (start a new session)
  :program               string (CLI binary name)
  :send-return           function (&optional buffer)
  :icon                  string or function (&optional face)
                           returning a propertized string
  :label                 string (display name,
                           e.g. \"Claude Code\" or \"Codex\")
  :display-name-suffix   function (buffer) -> string or nil
                           (extra suffix appended after base name)

Optional session metadata:
  :account               function (buffer) -> string or nil
                           (account name for session grouping)
  :has-background-tasks-p function (buffer) -> bool
                           (non-nil if the session has ongoing
                           background work while idle for input)

Optional command keys for dispatching shared commands:
  :discover-skills       function () -> list of skill plists
  :handoff               function () (close session, start new with handoff)
  :run-skill             function (name &optional args) (run a skill)
  :audit-project         function () (run audit skills on a project)
  :debug-backtrace       function () (analyze backtrace, start session)
  :setup-kill-on-exit    function () (auto-kill buffer on process exit)
  :exit                  function () (exit session and kill buffer)
  :restart               function () (restart current session)
  :sync-theme            function (theme) (persist light/dark theme)")

(defvar-local agents--backend nil
  "Cached backend symbol for this buffer.")

(defconst agents--required-backend-keys
  '(:buffer-p :find-all-buffers :extract-instance-name :start-new)
  "Backend plist keys required by the shared session layer.")

(defun agents-register-backend (symbol plist)
  "Register SYMBOL as an AI agent backend with PLIST properties."
  (agents--validate-backend symbol plist)
  (setf (alist-get symbol agents-backends) plist))

(defun agents--validate-backend (symbol plist)
  "Signal an error if SYMBOL's backend PLIST is missing required keys."
  (dolist (key agents--required-backend-keys)
    (unless (plist-get plist key)
      (error "AI backend `%s' is missing required key `%s'" symbol key))))

(defun agents--detect-backend (&optional buffer)
  "Detect which AI backend BUFFER belongs to.
Try each registered backend's :buffer-p predicate.  Return the
backend symbol or nil."
  (let ((buf (or buffer (current-buffer))))
    (or (buffer-local-value 'agents--backend buf)
        (let ((found (cl-find-if
                      (lambda (entry)
                        (funcall (plist-get (cdr entry) :buffer-p) buf))
                      agents-backends)))
          (when found
            (with-current-buffer buf
              (setq agents--backend (car found)))
            (car found))))))

(defun agents--backend-get (backend key)
  "Get KEY from the registered plist for BACKEND."
  (plist-get (alist-get backend agents-backends) key))

(defun agents-backend-icon (backend &optional face)
  "Return the icon string for BACKEND.
FACE is passed to the icon function to control the rendering color;
see `agents-svg-icon'.  The :icon property can be a string or a
function; if a function, it is called with FACE to produce the icon."
  (let ((icon (agents--backend-get backend :icon)))
    (if (functionp icon) (funcall icon face) (or icon ""))))

(defun agents-svg-icon (svg-data &optional face)
  "Return a propertized string displaying SVG-DATA as an inline icon.
FACE determines the color and height; it defaults to `default'.
The SVG should use \"currentColor\" for fill or stroke attributes,
which this function replaces with the foreground color of FACE.
For mode-line display, pass `mode-line-active' (not `mode-line',
whose foreground may not match the active mode-line in Emacs 29+).
Falls back to an empty string when SVG support is unavailable."
  (if (not (image-type-available-p 'svg))
      ""
    (let* ((face (or face 'default))
           (fg (face-foreground face nil t))
           (h (window-font-height nil face))
           (colored (replace-regexp-in-string "currentColor" (or fg "#000") svg-data t t))
           (img (create-image colored 'svg t :height h :ascent 'center)))
      (propertize " " 'display img 'rear-nonsticky '(display)))))

(defun agents--find-all-buffers ()
  "Return all active AI session buffers across all backends."
  (let (result)
    (dolist (entry agents-backends)
      (let ((bufs (funcall (plist-get (cdr entry) :find-all-buffers))))
        (setq result (nconc result bufs))))
    result))

(defun agents--session-name (buffer-name)
  "Extract the project name from BUFFER-NAME.
Given \"*claude:~/path/to/project/:default*\" or
\"*codex:~/path/to/project/:default*\", return \"project\"."
  (if (string-match "/\\([^/]+\\)/:[^*]+\\*\\'" buffer-name)
      (match-string 1 buffer-name)
    buffer-name))

;;;; Customization

(defcustom agents-protect-buffers t
  "When non-nil, prompt for confirmation before killing AI session buffers."
  :type 'boolean
  :group 'agents)

(defcustom agents-alert-style 'both
  "Style of alert when an AI session finishes responding.
Only takes effect when `agents-alert-on-ready' is non-nil."
  :type '(choice (const :tag "Visual notification only" visual)
                 (const :tag "Sound only" sound)
                 (const :tag "Both visual and sound" both))
  :group 'agents)

(defcustom agents-alert-sound nil
  "Path to the sound file played when a session finishes responding.
When nil, sound alerts are disabled even if `agents-alert-style'
is `sound' or `both'."
  :type '(choice (const :tag "No sound" nil) file)
  :group 'agents)

(defcustom agents-alert-sound-player nil
  "External program used to play `agents-alert-sound'.
When nil, `agents--alert-sound' uses `play-sound-file' when
that function is available."
  :type '(choice (const :tag "Use Emacs sound support" nil) string)
  :group 'agents)

(defcustom agents-backtrace-file
  (expand-file-name "agents-backtrace.el" temporary-file-directory)
  "File where `agents-save-backtrace' writes Emacs backtraces."
  :type 'file
  :group 'agents)

(defcustom agents-alert-on-ready nil
  "When non-nil, alert the user when an AI session finishes responding."
  :type 'boolean
  :group 'agents)

(defcustom agents-sync-theme nil
  "When non-nil, sync AI CLI themes with the current Emacs theme.
Theme changes are persisted through registered backend
`:sync-theme' handlers.  This intentionally updates configuration
files instead of sending slash commands to active terminal sessions,
so it does not inject text into a running conversation."
  :type 'boolean
  :group 'agents)

(defcustom agents-sigwinch-delay 0.5
  "Delay in seconds before sending SIGWINCH to fix terminal rendering."
  :type 'number
  :group 'agents)

;;;; Faces

(defface agents-waiting
  '((t :inherit success))
  "Face for sessions waiting for user input in the session switcher."
  :group 'agents)

(defface agents-waiting-with-background
  '((t :inherit warning))
  "Face for sessions waiting for user input while background work runs.
Applied in the session switcher when the backend's
`:has-background-tasks-p' reports ongoing work, to distinguish
these sessions from `agents-waiting' (truly idle)."
  :group 'agents)

;;;; State variables

(defconst agents--home-row-keys '("a" "s" "d" "f" "j" "k" "l" ";")
  "Home row keys assigned to AI sessions, in allocation order.")

(defconst agents--fallback-keys
  '("g" "h" "q" "r" "t" "y" "u" "i" "o" "p"
    "z" "x" "c" "v" "b" "n" "m")
  "Fallback keys used when home-row keys are exhausted.
Excludes \"w\" and \"e\", which are reserved for actions in
`agents--session-switcher'.")

(defconst agents--session-key-pool
  (append agents--home-row-keys agents--fallback-keys)
  "Full pool of keys for AI session assignment, home row first.")

(defvar agents--session-keys (make-hash-table :test 'eq)
  "Map from live AI session buffer to its assigned key.")

(defvar-local agents--display-name-cache nil
  "Cached display name for the modeline.")

(defvar-local agents--waiting-for-input nil
  "Non-nil when this AI session is waiting for user input.
Set to the time (via `current-time') by the notification handler
and cleared when input is sent.")

(defvar agents--sync-theme-timer nil
  "Pending timer for deferred theme sync, or nil.")

;;;; Forward declarations

(defvar eat-terminal)
(defvar eat-term-scrollback-size)
(declare-function eat-self-input "eat" (n &optional e))
(declare-function eat-term-send-string "eat" (terminal string))
(declare-function eat-term-display-cursor "eat" (terminal))
(declare-function eat-term-set-scrollback-size "eat" (terminal size))
(declare-function alert "alert")
(declare-function elpaca-get "elpaca")
(declare-function elpaca-source-dir "elpaca")
(declare-function find-library-name "find-func")

(declare-function consult--read "consult")
(declare-function consult--prefix-group "consult")
(declare-function consult--lookup-cdr "consult")
(declare-function consult-yasnippet--candidates "consult-yasnippet")
(declare-function consult-yasnippet--annotate "consult-yasnippet")

(declare-function yas--template-content "yasnippet")
(declare-function yas--template-expand-env "yasnippet")
(declare-function yas--template-key "yasnippet")
(declare-function yas--all-templates "yasnippet")
(declare-function yas--get-snippet-tables "yasnippet")
(declare-function yas-minor-mode "yasnippet")
(declare-function yas-expand-snippet "yasnippet")
(declare-function yas-active-snippets "yasnippet")
(declare-function yas--commit-snippet "yasnippet")
(declare-function map-values "map")

(defvar yas-minor-mode)
(defvar yas-prompt-functions)
(defvar yas--tables)

;;;; Theme sync

(defun agents-sync-theme (&rest _)
  "Sync registered AI backend themes with Emacs in a deferred timer."
  (interactive)
  (when agents-sync-theme
    (unless agents--sync-theme-timer
      (setq agents--sync-theme-timer
            (run-at-time 0 nil #'agents--do-sync-theme)))))

(defun agents-sync-theme-now (&rest _)
  "Sync registered AI backend themes with Emacs immediately.
This is useful before starting a CLI process, so the process reads
the current persisted theme at startup."
  (interactive)
  (when agents-sync-theme
    (when agents--sync-theme-timer
      (cancel-timer agents--sync-theme-timer)
      (setq agents--sync-theme-timer nil))
    (agents--do-sync-theme t)))

(defun agents--do-sync-theme (&optional force)
  "Perform the actual AI backend theme sync.
When FORCE is non-nil, sync even if `agents-sync-theme' is nil."
  (setq agents--sync-theme-timer nil)
  (when (or force agents-sync-theme)
    (let ((theme (agents--theme)))
      (dolist (entry agents-backends)
        (when-let* ((sync-fn (plist-get (cdr entry) :sync-theme)))
          (condition-case err
              (funcall sync-fn theme)
            (error
             (message "agents: failed to sync %s theme: %S"
                      (car entry) err))))))))

(defun agents--theme ()
  "Return \"light\" or \"dark\" based on the current frame background mode."
  (if (eq (frame-parameter nil 'background-mode) 'dark) "dark" "light"))

;;;; Home-row session keys

(defun agents--purge-dead-session-keys ()
  "Remove entries for buffers that are no longer live."
  (let (dead)
    (maphash (lambda (buf _) (unless (buffer-live-p buf) (push buf dead)))
             agents--session-keys)
    (dolist (buf dead)
      (remhash buf agents--session-keys))))

(defun agents--assign-session-key ()
  "Assign a key from `agents--session-key-pool' to the current buffer."
  (when (agents--detect-backend (current-buffer))
    (unless (gethash (current-buffer) agents--session-keys)
      (agents--purge-dead-session-keys)
      (let ((used (hash-table-values agents--session-keys)))
        (when-let* ((key (cl-find-if (lambda (k) (not (member k used)))
                                      agents--session-key-pool)))
          (puthash (current-buffer) key agents--session-keys))))))

(defun agents--release-session-key ()
  "Release the session key for the current buffer."
  (remhash (current-buffer) agents--session-keys))

(defun agents--ensure-all-session-keys ()
  "Ensure every active AI session buffer has a session key."
  (agents--purge-dead-session-keys)
  (dolist (buf (agents--find-all-buffers))
    (unless (gethash buf agents--session-keys)
      (let ((used (hash-table-values agents--session-keys)))
        (when-let* ((key (cl-find-if (lambda (k) (not (member k used)))
                                      agents--session-key-pool)))
          (puthash buf key agents--session-keys))))))

(defun agents--session-key-index (key)
  "Return the index of KEY in `agents--session-key-pool'."
  (or (cl-position key agents--session-key-pool :test #'string=) 99))

;;;; Display names

(defun agents--buffer-session-name (buffer)
  "Return the session name for BUFFER."
  (agents--session-name (buffer-name buffer)))

(defun agents--qualified-session-name (buffer-name)
  "Return a qualified session name from BUFFER-NAME.
Includes instance name when present for disambiguation."
  (let* ((backend (agents--detect-backend (get-buffer buffer-name)))
         (project (agents--session-name buffer-name))
         (instance (when backend
                     (funcall (agents--backend-get backend :extract-instance-name)
                              buffer-name))))
    (if instance
        (format "%s:%s" project instance)
      project)))

(defun agents-display-name (&optional buffer)
  "Return the display name for BUFFER.
Use the project name alone when it is unique among active sessions,
or \"project:instance\" when multiple sessions share the same
project.  Appends the backend's display suffix when provided.
Returns the cached value when available."
  (let ((buf (or buffer (current-buffer))))
    (or (buffer-local-value 'agents--display-name-cache buf)
        (agents--compute-display-name buf))))

(defun agents--compute-display-name (buffer)
  "Compute the display name for BUFFER by scanning active sessions."
  (let* ((name (agents--buffer-session-name buffer))
         (backend (agents--detect-backend buffer))
         (all-bufs (if backend
                       (funcall (agents--backend-get backend :find-all-buffers))
                     (agents--find-all-buffers)))
         (others (cl-remove buffer all-bufs))
         (sibling-names (mapcar #'agents--buffer-session-name others))
         (base (if (member name sibling-names)
                   (agents--qualified-session-name (buffer-name buffer))
                 name)))
    (agents--display-name-with-suffix buffer backend base)))

(defun agents--display-name-with-suffix (buffer backend base)
  "Return BASE plus BACKEND's display suffix for BUFFER, when any."
  (if-let* ((suffix-fn (and backend
                            (agents--backend-get backend
                                                    :display-name-suffix)))
            (suffix (funcall suffix-fn buffer)))
      (format "%s:%s" base suffix)
    base))

(defun agents--refresh-display-names ()
  "Recompute and cache display names for all AI session buffers."
  (dolist (buf (agents--find-all-buffers))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq agents--display-name-cache
              (agents--compute-display-name buf))))))

(defun agents--refresh-display-names-deferred ()
  "Refresh AI display names after the current hook finishes."
  (run-at-time 0 nil #'agents--refresh-display-names))

;;;; Session switcher

;;;###autoload
(defun agents-start-or-switch ()
  "Start a new AI session or switch to an existing one.
If no sessions are active, prompt for which backend to start.
If sessions exist, show a transient menu with home-row keys."
  (interactive)
  (let ((all-bufs (agents--find-all-buffers)))
    (if (null all-bufs)
        (agents--start-new-session)
      (agents--ensure-all-session-keys)
      (transient-setup 'agents--session-switcher))))

(defun agents--start-new-session ()
  "Start a new session, prompting for backend if multiple are registered."
  (interactive)
  (let ((backends agents-backends))
    (cond
     ((null backends) (user-error "No AI backends registered"))
     ((= (length backends) 1)
      (funcall (plist-get (cdar backends) :start-new)))
     (t
      (let* ((names (mapcar (lambda (e)
                              (cons (or (plist-get (cdr e) :label)
                                        (symbol-name (car e)))
                                    (car e)))
                            backends))
             (choice (completing-read "Backend: " (mapcar #'car names) nil t))
             (backend-sym (cdr (assoc choice names))))
        (funcall (agents--backend-get backend-sym :start-new)))))))

(transient-define-prefix agents--session-switcher ()
  "Switch to an AI session or start a new one."
  [["Actions"
    ("w" "jump to waiting" agents-jump-to-waiting)
    ("e" "new session" agents--start-new-session)]
   ["Sessions"
    :class transient-column
    :setup-children agents--session-switcher-children]])

(defun agents--session-switcher-children (_)
  "Build transient suffixes for the session switcher, grouped by account."
  (let ((groups (agents--group-sessions-by-account)))
    (transient-parse-suffixes
     'agents--session-switcher
     (apply #'vector (agents--interleave-group-headers groups)))))

(defun agents--group-sessions-by-account ()
  "Return an alist of (ACCOUNT . SPECS) sorted by account name.
Each SPECS is a list of suffix specs sorted by home-row key."
  (let ((groups (make-hash-table :test 'equal)))
    (maphash
     (lambda (buf key)
       (when (buffer-live-p buf)
         (push (agents--session-suffix-spec buf key)
               (gethash (agents--session-group-key buf) groups))))
     agents--session-keys)
    (agents--hash-to-sorted-alist groups)))

(defun agents--session-group-key (buffer)
  "Return the group key for BUFFER in the session switcher.
Uses the backend's :account function if available, falling back
to the backend's :label or symbol name."
  (let ((backend (agents--detect-backend buffer)))
    (or (when-let* ((account-fn (agents--backend-get backend :account)))
          (funcall account-fn buffer))
        (agents--backend-get backend :label)
        (and backend (symbol-name backend))
        "Sessions")))

(defun agents--session-suffix-spec (buf key)
  "Build a transient suffix spec for BUF bound to KEY."
  (let* ((backend (agents--detect-backend buf))
         (icon (when backend (agents-backend-icon backend)))
         (name (agents-display-name buf))
         (label (if (and icon (not (string-empty-p icon)))
                    (format "%s %s" icon name) name))
         (waiting (buffer-local-value
                   'agents--waiting-for-input buf))
         (cmd (make-symbol (format "ai-switch-%s" key)))
         (spec (list key label cmd)))
    (when waiting
      (setq spec (append spec
                         (list :face (agents--waiting-face buf backend)))))
    (fset cmd (lambda () (interactive) (switch-to-buffer buf)))
    spec))

(defun agents--waiting-face (buffer backend)
  "Return the face for BUFFER's waiting indicator.
Uses `agents-waiting-with-background' when BACKEND reports
that BUFFER has active background tasks, `agents-waiting'
otherwise."
  (if (and backend
           (when-let* ((fn (agents--backend-get
                            backend :has-background-tasks-p)))
             (funcall fn buffer)))
      'agents-waiting-with-background
    'agents-waiting))

(defun agents--hash-to-sorted-alist (groups)
  "Convert GROUPS hash table to an alist sorted by key.
Each value's suffix specs are sorted by session-key pool index."
  (let (alist)
    (maphash
     (lambda (group-key specs)
       (push (cons group-key
                   (sort specs
                         (lambda (a b)
                           (< (agents--session-key-index (car a))
                              (agents--session-key-index (car b))))))
             alist))
     groups)
    (sort alist (lambda (a b) (string< (car a) (car b))))))

(defun agents--accountless-labels ()
  "Return labels for backends without an :account function.
These backends don't support multi-account grouping, so their
sessions appear without a heading."
  (let (labels)
    (dolist (entry agents-backends labels)
      (unless (plist-get (cdr entry) :account)
        (when-let* ((label (plist-get (cdr entry) :label)))
          (push label labels))))))

(defun agents--interleave-group-headers (groups)
  "Interleave :info headers before each group's suffix specs.
GROUPS is an alist of (ACCOUNT . SPECS).  When there is only one
group, no headers are added.  Groups whose key matches an
accountless backend label appear without a heading."
  (if (<= (length groups) 1)
      (mapcan #'cdr groups)
    (let ((no-header (agents--accountless-labels)))
      (mapcan (lambda (entry)
                (if (member (car entry) no-header)
                    (copy-sequence (cdr entry))
                  (cons (list :info (car entry)) (cdr entry))))
              groups))))

;;;; Buffer protection

(defun agents-protect-buffer ()
  "Prompt for confirmation before killing AI session buffers.
Returns t if the buffer should be killed, nil otherwise."
  (or (not agents-protect-buffers)
      (not (agents--detect-backend (current-buffer)))
      (not (process-live-p (get-buffer-process (current-buffer))))
      (yes-or-no-p "Kill AI session buffer? ")))

;;;; Session exit

(defun agents-kill-session-buffer ()
  "Kill the current AI session buffer, bypassing confirmation.
Terminates the CLI process if still running, then kills the
buffer.  Signals an error unless the current buffer is an AI
session."
  (interactive)
  (unless (agents--detect-backend (current-buffer))
    (user-error "Not in an AI session buffer"))
  (agents--force-kill-buffer (current-buffer)))

(defun agents--force-kill-buffer (buffer)
  "Terminate the process in BUFFER and kill it without confirmation."
  (when-let* ((proc (get-buffer-process buffer)))
    (set-process-query-on-exit-flag proc nil)
    (set-process-sentinel proc #'ignore)
    (delete-process proc))
  (let ((kill-buffer-query-functions
         (remq 'agents-protect-buffer kill-buffer-query-functions)))
    (kill-buffer buffer)))

;;;; Alert and notification system

(defun agents-notify (title message)
  "Show notification with TITLE and MESSAGE.
When `agents-alert-on-ready' is non-nil, dispatch to the
configured alert style."
  (message "%s: %s" title message)
  (when agents-alert-on-ready
    (agents--alert-visual title message)
    (agents--alert-sound)))

(defun agents--alert-visual (title message)
  "Show a visual notification with TITLE and MESSAGE."
  (when (memq agents-alert-style '(visual both))
    (when (and (require 'alert nil t) (fboundp 'alert))
      (alert message :title title))))

(defun agents--alert-sound ()
  "Play the configured alert sound."
  (when (memq agents-alert-style '(sound both))
    (when-let* ((sound agents-alert-sound))
      (if (not (file-exists-p sound))
          (message "AI alert sound file not found: %s" sound)
        (cond
         ((fboundp 'play-sound-file)
          (condition-case err
              (play-sound-file sound)
            (error
             (message "AI alert sound failed: %s"
                      (error-message-string err)))))
         ((and agents-alert-sound-player
               (executable-find agents-alert-sound-player))
          (start-process "agents-alert-sound" nil
                         agents-alert-sound-player sound))
         (agents-alert-sound-player
          (message "AI alert sound player not found: %s"
                   agents-alert-sound-player))
         (t
          (message "No Emacs sound support or `agents-alert-sound-player'")))))))

(defun agents--clear-waiting-for-input (&rest _)
  "Clear the waiting-for-input flag in the current buffer."
  (when (bound-and-true-p agents--waiting-for-input)
    (setq agents--waiting-for-input nil)))

;;;###autoload
(defun agents-jump-to-waiting ()
  "Switch to the AI session that most recently started waiting for input."
  (interactive)
  (let (best-buf best-time)
    (dolist (buf (agents--find-all-buffers))
      (when (buffer-live-p buf)
        (let ((ts (buffer-local-value 'agents--waiting-for-input buf)))
          (when (and ts (or (null best-time) (time-less-p best-time ts)))
            (setq best-buf buf best-time ts)))))
    (if best-buf
        (switch-to-buffer best-buf)
      (message "No sessions waiting for input"))))

;;;###autoload
(defun agents-toggle-alert ()
  "Toggle OS notifications for AI sessions."
  (interactive)
  (setq agents-alert-on-ready (not agents-alert-on-ready))
  (message "AI alert notifications %s"
           (if agents-alert-on-ready "enabled" "disabled")))

(defun agents-alert-indicator ()
  "Return a bell icon reflecting the current alert state."
  (if agents-alert-on-ready "🔔" "🔕"))

;;;; Scroll to bottom

(defun agents--scroll-to-bottom (buffer)
  "Scroll BUFFER and its windows to the terminal cursor."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (bound-and-true-p eat-terminal)
        (let ((cursor-pos (eat-term-display-cursor eat-terminal)))
          (goto-char cursor-pos)
          (dolist (window (get-buffer-window-list nil nil t))
            (set-window-point window cursor-pos)
            (with-selected-window window
              (goto-char cursor-pos)
              (recenter -1))))))))

;;;; Terminal rendering fix

(defun agents-fix-rendering ()
  "Send SIGWINCH to fix terminal rendering after startup."
  (interactive)
  (when-let* ((proc (get-buffer-process (current-buffer))))
    (agents--send-sigwinch-after-delay (current-buffer))))

(defun agents--send-sigwinch-after-delay (buffer)
  "Send SIGWINCH to the process in BUFFER after a short delay."
  (run-at-time agents-sigwinch-delay nil
               #'agents--send-sigwinch buffer))

(defun agents--send-sigwinch (buffer)
  "Send SIGWINCH to the process in BUFFER."
  (when (buffer-live-p buffer)
    (when-let* ((proc (get-buffer-process buffer)))
      (signal-process proc 'SIGWINCH))))

;;;; Scrollback truncation fix

(defun agents-disable-scrollback-truncation ()
  "Disable eat's default scrollback limit for the current buffer.
Without this, eat truncates terminal output to
`eat-term-scrollback-size' lines, causing older AI session output
to vanish."
  (interactive)
  (when (bound-and-true-p eat-terminal)
    (if (fboundp 'eat-term-set-scrollback-size)
        (eat-term-set-scrollback-size eat-terminal most-positive-fixnum)
      (setq-local eat-term-scrollback-size nil))))

;;;; Snippet insertion

(defun agents--expand-snippet-to-text (template)
  "Expand yasnippet TEMPLATE to plain text in a temporary buffer."
  (with-temp-buffer
    (yas-minor-mode 1)
    (let ((yas-prompt-functions '(yas-no-prompt)))
      (yas-expand-snippet (yas--template-content template)
                          nil nil
                          (yas--template-expand-env template)))
    (mapc #'yas--commit-snippet (yas-active-snippets))
    (buffer-string)))

(defun agents--consult-yasnippet (orig-fn arg)
  "In eat-mode buffers, send snippet content via the terminal.
ORIG-FN is `consult-yasnippet'; ARG is the prefix argument."
  (if (not (derived-mode-p 'eat-mode))
      (funcall orig-fn arg)
    (let* ((candidates
            (consult-yasnippet--candidates
             (if arg
                 (progn (require 'map)
                        (yas--all-templates (map-values yas--tables)))
               (yas--all-templates (yas--get-snippet-tables)))))
           (template
            (consult--read
             candidates
             :prompt "Choose a snippet: "
             :annotate (consult-yasnippet--annotate candidates)
             :lookup 'consult--lookup-cdr
             :require-match t
             :group 'consult--prefix-group
             :category 'yasnippet)))
      (when template
        (let* ((expanded (agents--expand-snippet-to-text template))
               (text (replace-regexp-in-string "\n" "\e\r" expanded)))
          (eat-term-send-string eat-terminal text))))))

(with-eval-after-load 'consult-yasnippet
  (advice-add 'consult-yasnippet :around #'agents--consult-yasnippet))

(defun agents--try-expand-snippet-at-prompt ()
  "Try to expand a yasnippet key at the eat terminal prompt.
Search backward from `point-max' for a prompt marker, extract the
user's input, and check whether it ends with a snippet key.  If
found, erase the key and send the expanded text.  Return non-nil
if a snippet was expanded."
  (when (and (derived-mode-p 'eat-mode)
             (bound-and-true-p eat-terminal)
             (bound-and-true-p yas-minor-mode))
    (save-excursion
      (goto-char (point-max))
      (when (re-search-backward "^[❯>$][[:space:]]" nil t)
        (let* ((prompt-start (match-end 0))
               (prompt-end (progn (end-of-line) (point)))
               (input (string-trim-right
                       (buffer-substring-no-properties prompt-start prompt-end)))
               (templates (yas--all-templates (yas--get-snippet-tables)))
               (best-match nil)
               (best-key nil))
          (dolist (template templates)
            (let ((key (yas--template-key template)))
              (when (and key
                         (> (length key) 0)
                         (<= (length key) (length input))
                         (string= key (substring input (- (length input) (length key))))
                         (or (null best-key)
                             (> (length key) (length best-key))))
                (setq best-match template
                      best-key key))))
          (when best-match
            (eat-term-send-string eat-terminal
                                  (make-string (length best-key) ?\x7f))
            (let* ((expanded (agents--expand-snippet-to-text best-match))
                   (text (replace-regexp-in-string "\n" "\e\r" expanded)))
              (eat-term-send-string eat-terminal text))
            t))))))

(defun agents-snippet-tab ()
  "Try snippet expansion at prompt, otherwise send TAB to eat."
  (interactive)
  (unless (agents--try-expand-snippet-at-prompt)
    (eat-self-input 1 ?\t)))

(defvar agents--snippet-keys-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'agents-snippet-tab)
    (define-key map [tab] #'agents-snippet-tab)
    map)
  "Keymap for `agents--snippet-keys-mode'.")

(define-minor-mode agents--snippet-keys-mode
  "Minor mode providing yasnippet TAB expansion in AI session buffers."
  :keymap agents--snippet-keys-mode-map)

(defun agents-setup-snippet-keys ()
  "Enable yasnippet TAB expansion in the current AI session buffer."
  (when (and (agents--detect-backend (current-buffer))
             (bound-and-true-p eat-terminal)
             (require 'yasnippet nil t))
    (yas-minor-mode 1)
    (agents--snippet-keys-mode 1)))

;;;; Escape key fix

(defun agents--send-escape-in-current-buffer (orig-fn)
  "When already in an AI buffer, send escape directly without prompting.
ORIG-FN is the original escape command."
  (if (agents--detect-backend (current-buffer))
      (when (bound-and-true-p eat-terminal)
        (eat-term-send-string eat-terminal (kbd "ESC")))
    (funcall orig-fn)))

;;;; Command dispatchers

(defun agents--resolve-backend ()
  "Return the backend for the current context.
If in a session buffer, use that backend.  If only one backend is
registered, use it.  Otherwise, prompt."
  (or (agents--detect-backend)
      (if (= (length agents-backends) 1)
          (caar agents-backends)
        (let* ((entries (mapcar (lambda (e)
                                  (cons (or (plist-get (cdr e) :label)
                                            (symbol-name (car e)))
                                        (car e)))
                                agents-backends))
               (labels (mapcar #'car entries))
               (affixate (lambda (cands)
                           (mapcar (lambda (c)
                                     (let* ((sym (cdr (assoc c entries)))
                                            (icon (agents-backend-icon sym)))
                                       (list c
                                             (if (string-empty-p icon) ""
                                               (concat icon " "))
                                             "")))
                                   cands)))
               (choice (completing-read
                        "Backend: "
                        (lambda (str pred action)
                          (if (eq action 'metadata)
                              `(metadata (affixation-function . ,affixate))
                            (complete-with-action action labels str pred)))
                        nil t)))
          (cdr (assoc choice entries))))))

(defun agents--dispatch (key)
  "Dispatch command KEY to the appropriate backend.
Uses `call-interactively' so the target command's interactive spec
runs and prompts for arguments as needed."
  (let* ((backend (agents--resolve-backend))
         (fn (agents--backend-get backend key)))
    (if fn
        (call-interactively fn)
      (user-error "Backend `%s' does not support `%s'" backend key))))

(defun agents--run-before-exit-functions (backend buffer)
  "Return non-nil if BACKEND session BUFFER should exit."
  (catch 'abort
    (dolist (fn agents-before-exit-functions t)
      (unless (funcall fn backend buffer)
        (throw 'abort nil)))))

(defun agents-run-skill-before-exit (backend buffer)
  "Run `agents-before-exit-skill-name' before exiting BUFFER.
BACKEND is the resolved `agents' backend.  Return nil when a
skill command was submitted and exit should be delayed."
  (with-current-buffer buffer
    (if (or agents--before-exit-skill-sent
            (not (agents--before-exit-skill-configured-p))
            (not (agents--before-exit-skill-directory-p backend buffer)))
        t
      (let ((command (agents--before-exit-skill-command backend))
            (send-command-fn (agents--backend-get backend :send-command)))
        (if (not (and command send-command-fn))
            t
          (setq-local agents--before-exit-skill-sent t)
          (funcall send-command-fn command buffer)
          (when-let* ((send-return-fn (agents--backend-get backend :send-return)))
            (funcall send-return-fn buffer))
          (message "Started %s; run agents-exit again to close this session."
                   command)
          nil)))))

(defun agents--before-exit-skill-configured-p ()
  "Return non-nil when a before-exit skill is configured."
  (and agents-before-exit-skill-name
       (not (string-empty-p agents-before-exit-skill-name))))

(defun agents--before-exit-skill-directory-p (backend buffer)
  "Return non-nil if BACKEND session BUFFER is in a configured directory."
  (when-let* ((directory (agents--buffer-directory backend buffer)))
    (cl-some (lambda (candidate)
               (file-in-directory-p directory (file-truename candidate)))
             agents-before-exit-skill-directories)))

(defun agents--buffer-directory (backend buffer)
  "Return the normalized directory for BACKEND session BUFFER."
  (when-let* ((directory-fn (agents--backend-get backend :directory))
              (directory (funcall directory-fn buffer)))
    (file-name-as-directory (file-truename directory))))

(defun agents--before-exit-skill-command (backend)
  "Return the interactive before-exit skill command for BACKEND."
  (when-let* ((prefix (alist-get backend agents-skill-command-prefix-alist)))
    (concat prefix agents-before-exit-skill-name)))

(defun agents--skill-argument-candidates (skill)
  "Return completion candidates for SKILL's arguments.
SKILL is a plist.  If the skill has an :argument-source glob,
resolve it relative to the skill's directory and return file stems.
If it has :argument-choices, return those.  Otherwise return nil."
  (or (when-let* ((source (plist-get skill :argument-source))
                  (skill-dir (file-name-directory (plist-get skill :path))))
        (let ((pattern (expand-file-name source skill-dir)))
          (mapcar (lambda (f)
                    (file-name-sans-extension (file-name-nondirectory f)))
                  (file-expand-wildcards pattern))))
      (plist-get skill :argument-choices)))

(defun agents-parse-skill-frontmatter (file)
  "Parse skill frontmatter from FILE and return a plist.
Recognizes :name, :description, :argument-hint, :argument-source,
:argument-choices, :argument-default, :argument-multiple,
:user-invocable, and :model."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (when (looking-at-p "---")
      (forward-line 1)
      (let ((start (point))
            (result nil))
        (when (re-search-forward "^---$" nil t)
          (dolist (line (split-string
                         (buffer-substring-no-properties
                          start (line-beginning-position))
                         "\n" t))
            (when (string-match "^\\([a-z0-9_-]+\\): *\\(.*\\)$" line)
              (setq result
                    (agents--put-skill-frontmatter-field
                     result
                     (match-string 1 line)
                     (agents--clean-skill-frontmatter-value
                      (match-string 2 line)))))))
        result))))

(defun agents--clean-skill-frontmatter-value (value)
  "Return normalized frontmatter VALUE."
  (let ((val (string-trim value)))
    (if (string-match "^[\"']\\(.*\\)[\"']$" val)
        (match-string 1 val)
      val)))

(defun agents--put-skill-frontmatter-field (plist key value)
  "Return PLIST with frontmatter KEY set to VALUE when recognized."
  (pcase key
    ("name" (plist-put plist :name value))
    ("description" (plist-put plist :description value))
    ("argument-hint" (plist-put plist :argument-hint value))
    ("argument-source" (plist-put plist :argument-source value))
    ("argument-choices"
     (plist-put plist :argument-choices
                (mapcar #'string-trim (split-string value "," t))))
    ("argument-default" (plist-put plist :argument-default value))
    ("argument-multiple"
     (plist-put plist :argument-multiple
                (not (string= (downcase value) "false"))))
    ("user-invocable"
     (plist-put plist :user-invocable
                (not (string= (downcase value) "false"))))
    ("model" (plist-put plist :model value))
    (_ plist)))

(defun agents--discover-all-skills ()
  "Discover skills from all registered backends.
Calls each backend's `:discover-skills' function and returns a
combined list of skill plists, each augmented with `:backend'."
  (let (all-skills)
    (dolist (entry agents-backends)
      (when-let* ((discover-fn (plist-get (cdr entry) :discover-skills)))
        (dolist (skill (funcall discover-fn))
          (unless (and (plist-member skill :user-invocable)
                       (not (plist-get skill :user-invocable)))
            (push (plist-put (copy-sequence skill) :backend (car entry))
                  all-skills)))))
    (sort all-skills (lambda (a b)
                       (string< (plist-get a :name) (plist-get b :name))))))

(defun agents--skill-candidate (skill)
  "Return a unique completion candidate for SKILL."
  (let* ((backend (plist-get skill :backend))
         (label (or (agents--backend-get backend :label)
                    (symbol-name backend))))
    (propertize (format "%s [%s]" (plist-get skill :name) label)
                'agents-skill skill)))

(defun agents--skill-candidates (skills)
  "Return completion candidates for SKILLS with embedded skill plists."
  (mapcar #'agents--skill-candidate skills))

(defun agents--skill-from-candidate (candidate candidates)
  "Return the skill plist for CANDIDATE from CANDIDATES."
  (or (get-text-property 0 'agents-skill candidate)
      (get-text-property 0 'agents-skill
                         (cl-find candidate candidates :test #'string=))))

;;;###autoload
(defun agents-handoff ()
  "Close the current session and start a new one with the handoff prompt.
Dispatches to the appropriate backend."
  (interactive)
  (agents--dispatch :handoff))

;;;###autoload
(defun agents-run-skill ()
  "Discover and run a skill from any registered backend.
Shows an aggregated list of all skills with an indication of
the backend next to each."
  (interactive)
  (let* ((skills (agents--discover-all-skills))
         (_ (unless skills (user-error "No user-invocable skills found")))
         (skill-candidates (agents--skill-candidates skills))
         (max-cand-len (apply #'max (mapcar #'length skill-candidates)))
         (annotate
          (lambda (cand)
            (when-let* ((skill (agents--skill-from-candidate
                                cand skill-candidates)))
              (let ((desc (or (plist-get skill :description) "")))
                (concat (make-string (- (+ max-cand-len 2) (length cand)) ?\s)
                        (propertize desc 'face 'completions-annotations))))))
         (candidate (completing-read
                     "Skill: "
                     (lambda (str pred action)
                       (if (eq action 'metadata)
                           `(metadata (annotation-function . ,annotate))
                         (complete-with-action
                          action skill-candidates str pred)))
                     nil t))
         (skill (agents--skill-from-candidate candidate skill-candidates))
         (backend (plist-get skill :backend))
         ;; Prompt for arguments using skill metadata
         (hint (plist-get skill :argument-hint))
         (candidates (agents--skill-argument-candidates skill))
         (default (plist-get skill :argument-default))
         (multiple-p (plist-get skill :argument-multiple))
         (args (cond
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
                (hint
                 (let ((input (read-string (format "Arguments %s: " hint))))
                   (unless (string-empty-p input) input)))))
         (run-fn (agents--backend-get backend :run-skill)))
    (unless run-fn
      (user-error "Backend `%s' does not support `:run-skill'" backend))
    (funcall run-fn (plist-get skill :name) args)))

;;;###autoload
;;;###autoload
(defun agents-post-push-ci (&optional commit)
  "Run the post-push CI closeout skill for COMMIT.
When COMMIT is nil, use the current Git HEAD.  The selected backend
must support `:run-skill'."
  (interactive)
  (let* ((backend (agents--resolve-backend))
         (run-fn (agents--backend-get backend :run-skill))
         (sha (or commit (agents--git-head)))
         (args (format "--no-push --commit %s" sha)))
    (unless run-fn
      (user-error "Backend `%s' does not support `:run-skill'" backend))
    (funcall run-fn "post-push-ci" args)))

(defun agents--git-head ()
  "Return the current Git HEAD SHA."
  (with-temp-buffer
    (unless (zerop (process-file "git" nil t nil "rev-parse" "HEAD"))
      (user-error "Could not resolve Git HEAD"))
    (string-trim (buffer-string))))

;;;###autoload
(defun agents-audit-project ()
  "Run a comprehensive project audit via the appropriate backend."
  (interactive)
  (agents--dispatch :audit-project))

;;;###autoload
(defun agents-debug-backtrace ()
  "Analyze a backtrace and start a session in the culprit package."
  (interactive)
  (agents--dispatch :debug-backtrace))

;;;###autoload
(defun agents-save-backtrace ()
  "Save the current Emacs backtrace and return its file path."
  (interactive)
  (unless (string-match-p "\\*Backtrace\\*" (buffer-name))
    (user-error "Not in a backtrace buffer"))
  (let ((file (expand-file-name agents-backtrace-file))
        (contents (buffer-string)))
    (make-directory (file-name-directory file) t)
    (with-temp-buffer
      (insert contents)
      (write-region (point-min) (point-max) file nil 'silent))
    (kill-new file)
    (kill-buffer)
    (message "Backtrace saved to %s" (abbreviate-file-name file))
    file))

(defun agents--package-source-directory (package)
  "Return a source directory for PACKAGE, or nil."
  (or (when-let* ((entry (and (fboundp 'elpaca-get) (elpaca-get package)))
                  ((fboundp 'elpaca-source-dir)))
        (elpaca-source-dir entry))
      (when (require 'find-func nil t)
        (condition-case nil
            (file-name-directory (find-library-name (symbol-name package)))
          (error nil)))))

;;;###autoload
(defun agents-setup-kill-on-exit ()
  "Arrange for the buffer to be killed when the session process exits."
  (interactive)
  (agents--dispatch :setup-kill-on-exit))

;;;###autoload
(defun agents-exit ()
  "Exit the current AI session and kill its buffer.
Dispatches to the backend's `:exit' handler, which should
terminate the CLI process and kill the buffer."
  (interactive)
  (let* ((backend (agents--resolve-backend))
         (buffer (current-buffer))
         (fn (agents--backend-get backend :exit)))
    (unless fn
      (user-error "Backend `%s' does not support `:exit'" backend))
    (when (agents--run-before-exit-functions backend buffer)
      (call-interactively fn))))

;;;###autoload
(defun agents-restart ()
  "Kill the current AI session and resume it in place.
Useful when a setting change requires relaunching the CLI.
Dispatches to the backend's `:restart' handler."
  (interactive)
  (agents--dispatch :restart))

;;;; Transient boolean infix class

(eval-and-compile
  (defclass agents--boolean-variable (transient-lisp-variable)
    ()
    "A `transient-lisp-variable' that toggles a boolean on each press."))

(cl-defmethod transient-infix-read ((obj agents--boolean-variable))
  "Toggle the boolean value of OBJ."
  (not (oref obj value)))

;;;; Transient menu

;;;###autoload (autoload 'agents-menu "agents" nil t)
(transient-define-prefix agents-menu ()
  "Dispatch AI session commands."
  [["Sessions"
    ("e" "start or switch" agents-start-or-switch)
    ("w" "jump to waiting" agents-jump-to-waiting)
    ("h" "handoff" agents-handoff)
    ("x" "exit session" agents-exit)
    ("r" "restart" agents-restart)
    ""
    "Buffer"
    ("K" "setup kill on exit" agents-setup-kill-on-exit)
    ("f" "fix rendering" agents-fix-rendering)
    ("S" "disable scrollback" agents-disable-scrollback-truncation)]
   ["Tools"
    ("s" "run skill" agents-run-skill)
    ("c" "post-push CI" agents-post-push-ci)
    ("a" "audit project" agents-audit-project)
    ("d" "debug backtrace" agents-debug-backtrace)
    ""
    "Alerts"
    ("T" "toggle alert" agents-toggle-alert)]
   ["Options"
    ("-A" agents--infix-alert-on-ready)
    ("-p" agents--infix-protect-buffers)
    ("-t" agents--infix-sync-theme)]])

(transient-define-infix agents--infix-alert-on-ready ()
  "Toggle `agents-alert-on-ready'."
  :class 'agents--boolean-variable
  :variable 'agents-alert-on-ready
  :description "alert on ready")

(transient-define-infix agents--infix-protect-buffers ()
  "Toggle `agents-protect-buffers'."
  :class 'agents--boolean-variable
  :variable 'agents-protect-buffers
  :description "protect buffers")

(eval-and-compile
  (defclass agents--sync-theme-variable (agents--boolean-variable)
    ()
    "A boolean infix that syncs themes when enabled."))

(cl-defmethod transient-infix-set :after
  ((obj agents--sync-theme-variable) _value)
  "Sync themes after OBJ enables `agents-sync-theme'."
  (when (symbol-value (oref obj variable))
    (agents-sync-theme-now)))

(transient-define-infix agents--infix-sync-theme ()
  "Toggle `agents-sync-theme'."
  :class 'agents--sync-theme-variable
  :variable 'agents-sync-theme
  :description "sync theme")

(add-hook 'enable-theme-functions #'agents-sync-theme)
(add-hook 'agents-before-exit-functions #'agents-run-skill-before-exit)

;;;; Provide

(provide 'agents)
;;; agents.el ends here
