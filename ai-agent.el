;;; ai-agent.el --- Shared extensions for AI coding CLI tools -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/ai-agent
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
;; terminal integration for packages like `ai-agent-claude' and
;; `ai-agent-codex'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(eval-and-compile (require 'transient))

;;;; Custom group

(defgroup ai-agent ()
  "Shared extensions for AI coding CLI tools."
  :group 'tools)

;;;; Backend registry

(defvar ai-agent-backends nil
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
  :sync-theme            function (theme) (persist light/dark theme)")

(defvar-local ai-agent--backend nil
  "Cached backend symbol for this buffer.")

(defconst ai-agent--required-backend-keys
  '(:buffer-p :find-all-buffers :extract-instance-name :start-new)
  "Backend plist keys required by the shared session layer.")

(defun ai-agent-register-backend (symbol plist)
  "Register SYMBOL as an AI agent backend with PLIST properties."
  (ai-agent--validate-backend symbol plist)
  (setf (alist-get symbol ai-agent-backends) plist))

(defun ai-agent--validate-backend (symbol plist)
  "Signal an error if SYMBOL's backend PLIST is missing required keys."
  (dolist (key ai-agent--required-backend-keys)
    (unless (plist-get plist key)
      (error "AI backend `%s' is missing required key `%s'" symbol key))))

(defun ai-agent--detect-backend (&optional buffer)
  "Detect which AI backend BUFFER belongs to.
Try each registered backend's :buffer-p predicate.  Return the
backend symbol or nil."
  (let ((buf (or buffer (current-buffer))))
    (or (buffer-local-value 'ai-agent--backend buf)
        (let ((found (cl-find-if
                      (lambda (entry)
                        (funcall (plist-get (cdr entry) :buffer-p) buf))
                      ai-agent-backends)))
          (when found
            (with-current-buffer buf
              (setq ai-agent--backend (car found)))
            (car found))))))

(defun ai-agent--backend-get (backend key)
  "Get KEY from the registered plist for BACKEND."
  (plist-get (alist-get backend ai-agent-backends) key))

(defun ai-agent-backend-icon (backend &optional face)
  "Return the icon string for BACKEND.
FACE is passed to the icon function to control the rendering color;
see `ai-agent-svg-icon'.  The :icon property can be a string or a
function; if a function, it is called with FACE to produce the icon."
  (let ((icon (ai-agent--backend-get backend :icon)))
    (if (functionp icon) (funcall icon face) (or icon ""))))

(defun ai-agent-svg-icon (svg-data &optional face)
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

(defun ai-agent--find-all-buffers ()
  "Return all active AI session buffers across all backends."
  (let (result)
    (dolist (entry ai-agent-backends)
      (let ((bufs (funcall (plist-get (cdr entry) :find-all-buffers))))
        (setq result (nconc result bufs))))
    result))

(defun ai-agent--session-name (buffer-name)
  "Extract the project name from BUFFER-NAME.
Given \"*claude:~/path/to/project/:default*\" or
\"*codex:~/path/to/project/:default*\", return \"project\"."
  (if (string-match "/\\([^/]+\\)/:[^*]+\\*\\'" buffer-name)
      (match-string 1 buffer-name)
    buffer-name))

;;;; Customization

(defcustom ai-agent-protect-buffers t
  "When non-nil, prompt for confirmation before killing AI session buffers."
  :type 'boolean
  :group 'ai-agent)

(defcustom ai-agent-alert-style 'both
  "Style of alert when an AI session finishes responding.
Only takes effect when `ai-agent-alert-on-ready' is non-nil."
  :type '(choice (const :tag "Visual notification only" visual)
                 (const :tag "Sound only" sound)
                 (const :tag "Both visual and sound" both))
  :group 'ai-agent)

(defcustom ai-agent-alert-sound "/System/Library/Sounds/Glass.aiff"
  "Path to the sound file played when a session finishes responding."
  :type 'file
  :group 'ai-agent)

(defcustom ai-agent-alert-on-ready nil
  "When non-nil, alert the user when an AI session finishes responding."
  :type 'boolean
  :group 'ai-agent)

(defcustom ai-agent-sync-theme nil
  "When non-nil, sync AI CLI themes with the current Emacs theme.
Theme changes are persisted through registered backend
`:sync-theme' handlers.  This intentionally updates configuration
files instead of sending slash commands to active terminal sessions,
so it does not inject text into a running conversation."
  :type 'boolean
  :group 'ai-agent)

(defcustom ai-agent-sigwinch-delay 0.5
  "Delay in seconds before sending SIGWINCH to fix terminal rendering."
  :type 'number
  :group 'ai-agent)

;;;; Faces

(defface ai-agent-waiting
  '((t :inherit success))
  "Face for sessions waiting for user input in the session switcher."
  :group 'ai-agent)

(defface ai-agent-waiting-with-background
  '((t :inherit warning))
  "Face for sessions waiting for user input while background work runs.
Applied in the session switcher when the backend's
`:has-background-tasks-p' reports ongoing work, to distinguish
these sessions from `ai-agent-waiting' (truly idle)."
  :group 'ai-agent)

;;;; State variables

(defconst ai-agent--home-row-keys '("a" "s" "d" "f" "j" "k" "l" ";")
  "Home row keys assigned to AI sessions, in allocation order.")

(defconst ai-agent--fallback-keys
  '("g" "h" "q" "r" "t" "y" "u" "i" "o" "p"
    "z" "x" "c" "v" "b" "n" "m")
  "Fallback keys used when home-row keys are exhausted.
Excludes \"w\" and \"e\", which are reserved for actions in
`ai-agent--session-switcher'.")

(defconst ai-agent--session-key-pool
  (append ai-agent--home-row-keys ai-agent--fallback-keys)
  "Full pool of keys for AI session assignment, home row first.")

(defvar ai-agent--session-keys (make-hash-table :test 'eq)
  "Map from live AI session buffer to its assigned key.")

(defvar-local ai-agent--display-name-cache nil
  "Cached display name for the modeline.")

(defvar-local ai-agent--waiting-for-input nil
  "Non-nil when this AI session is waiting for user input.
Set to the time (via `current-time') by the notification handler
and cleared when input is sent.")

(defvar ai-agent--sync-theme-timer nil
  "Pending timer for deferred theme sync, or nil.")

;;;; Forward declarations

(defvar eat-terminal)
(defvar eat-term-scrollback-size)
(declare-function eat-self-input "eat" (n &optional e))
(declare-function eat-term-send-string "eat" (terminal string))
(declare-function eat-term-display-cursor "eat" (terminal))
(declare-function eat-term-set-scrollback-size "eat" (terminal size))
(declare-function alert "alert")

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

(defun ai-agent-sync-theme (&rest _)
  "Sync registered AI backend themes with Emacs in a deferred timer."
  (interactive)
  (when ai-agent-sync-theme
    (unless ai-agent--sync-theme-timer
      (setq ai-agent--sync-theme-timer
            (run-at-time 0 nil #'ai-agent--do-sync-theme)))))

(defun ai-agent-sync-theme-now (&rest _)
  "Sync registered AI backend themes with Emacs immediately.
This is useful before starting a CLI process, so the process reads
the current persisted theme at startup."
  (interactive)
  (when ai-agent-sync-theme
    (when ai-agent--sync-theme-timer
      (cancel-timer ai-agent--sync-theme-timer)
      (setq ai-agent--sync-theme-timer nil))
    (ai-agent--do-sync-theme t)))

(defun ai-agent--do-sync-theme (&optional force)
  "Perform the actual AI backend theme sync.
When FORCE is non-nil, sync even if `ai-agent-sync-theme' is nil."
  (setq ai-agent--sync-theme-timer nil)
  (when (or force ai-agent-sync-theme)
    (let ((theme (ai-agent--theme)))
      (dolist (entry ai-agent-backends)
        (when-let* ((sync-fn (plist-get (cdr entry) :sync-theme)))
          (condition-case err
              (funcall sync-fn theme)
            (error
             (message "ai-agent: failed to sync %s theme: %S"
                      (car entry) err))))))))

(defun ai-agent--theme ()
  "Return \"light\" or \"dark\" based on the current frame background mode."
  (if (eq (frame-parameter nil 'background-mode) 'dark) "dark" "light"))

;;;; Home-row session keys

(defun ai-agent--purge-dead-session-keys ()
  "Remove entries for buffers that are no longer live."
  (let (dead)
    (maphash (lambda (buf _) (unless (buffer-live-p buf) (push buf dead)))
             ai-agent--session-keys)
    (dolist (buf dead)
      (remhash buf ai-agent--session-keys))))

(defun ai-agent--assign-session-key ()
  "Assign a key from `ai-agent--session-key-pool' to the current buffer."
  (when (ai-agent--detect-backend (current-buffer))
    (unless (gethash (current-buffer) ai-agent--session-keys)
      (ai-agent--purge-dead-session-keys)
      (let ((used (hash-table-values ai-agent--session-keys)))
        (when-let* ((key (cl-find-if (lambda (k) (not (member k used)))
                                      ai-agent--session-key-pool)))
          (puthash (current-buffer) key ai-agent--session-keys))))))

(defun ai-agent--release-session-key ()
  "Release the session key for the current buffer."
  (remhash (current-buffer) ai-agent--session-keys))

(defun ai-agent--ensure-all-session-keys ()
  "Ensure every active AI session buffer has a session key."
  (ai-agent--purge-dead-session-keys)
  (dolist (buf (ai-agent--find-all-buffers))
    (unless (gethash buf ai-agent--session-keys)
      (let ((used (hash-table-values ai-agent--session-keys)))
        (when-let* ((key (cl-find-if (lambda (k) (not (member k used)))
                                      ai-agent--session-key-pool)))
          (puthash buf key ai-agent--session-keys))))))

(defun ai-agent--session-key-index (key)
  "Return the index of KEY in `ai-agent--session-key-pool'."
  (or (cl-position key ai-agent--session-key-pool :test #'string=) 99))

;;;; Display names

(defun ai-agent--buffer-session-name (buffer)
  "Return the session name for BUFFER."
  (ai-agent--session-name (buffer-name buffer)))

(defun ai-agent--qualified-session-name (buffer-name)
  "Return a qualified session name from BUFFER-NAME.
Includes instance name when present for disambiguation."
  (let* ((backend (ai-agent--detect-backend (get-buffer buffer-name)))
         (project (ai-agent--session-name buffer-name))
         (instance (when backend
                     (funcall (ai-agent--backend-get backend :extract-instance-name)
                              buffer-name))))
    (if instance
        (format "%s:%s" project instance)
      project)))

(defun ai-agent-display-name (&optional buffer)
  "Return the display name for BUFFER.
Use the project name alone when it is unique among active sessions,
or \"project:instance\" when multiple sessions share the same
project.  Appends the backend's display suffix when provided.
Returns the cached value when available."
  (let ((buf (or buffer (current-buffer))))
    (or (buffer-local-value 'ai-agent--display-name-cache buf)
        (ai-agent--compute-display-name buf))))

(defun ai-agent--compute-display-name (buffer)
  "Compute the display name for BUFFER by scanning active sessions."
  (let* ((name (ai-agent--buffer-session-name buffer))
         (backend (ai-agent--detect-backend buffer))
         (all-bufs (if backend
                       (funcall (ai-agent--backend-get backend :find-all-buffers))
                     (ai-agent--find-all-buffers)))
         (others (cl-remove buffer all-bufs))
         (sibling-names (mapcar #'ai-agent--buffer-session-name others))
         (base (if (member name sibling-names)
                   (ai-agent--qualified-session-name (buffer-name buffer))
                 name)))
    (ai-agent--display-name-with-suffix buffer backend base)))

(defun ai-agent--display-name-with-suffix (buffer backend base)
  "Return BASE plus BACKEND's display suffix for BUFFER, when any."
  (if-let* ((suffix-fn (and backend
                            (ai-agent--backend-get backend
                                                    :display-name-suffix)))
            (suffix (funcall suffix-fn buffer)))
      (format "%s:%s" base suffix)
    base))

(defun ai-agent--refresh-display-names ()
  "Recompute and cache display names for all AI session buffers."
  (dolist (buf (ai-agent--find-all-buffers))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq ai-agent--display-name-cache
              (ai-agent--compute-display-name buf))))))

(defun ai-agent--refresh-display-names-deferred ()
  "Refresh AI display names after the current hook finishes."
  (run-at-time 0 nil #'ai-agent--refresh-display-names))

;;;; Session switcher

;;;###autoload
(defun ai-agent-start-or-switch ()
  "Start a new AI session or switch to an existing one.
If no sessions are active, prompt for which backend to start.
If sessions exist, show a transient menu with home-row keys."
  (interactive)
  (let ((all-bufs (ai-agent--find-all-buffers)))
    (if (null all-bufs)
        (ai-agent--start-new-session)
      (ai-agent--ensure-all-session-keys)
      (transient-setup 'ai-agent--session-switcher))))

(defun ai-agent--start-new-session ()
  "Start a new session, prompting for backend if multiple are registered."
  (interactive)
  (let ((backends ai-agent-backends))
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
        (funcall (ai-agent--backend-get backend-sym :start-new)))))))

(transient-define-prefix ai-agent--session-switcher ()
  "Switch to an AI session or start a new one."
  [["Actions"
    ("w" "jump to waiting" ai-agent-jump-to-waiting)
    ("e" "new session" ai-agent--start-new-session)]
   ["Sessions"
    :class transient-column
    :setup-children ai-agent--session-switcher-children]])

(defun ai-agent--session-switcher-children (_)
  "Build transient suffixes for the session switcher, grouped by account."
  (let ((groups (ai-agent--group-sessions-by-account)))
    (transient-parse-suffixes
     'ai-agent--session-switcher
     (apply #'vector (ai-agent--interleave-group-headers groups)))))

(defun ai-agent--group-sessions-by-account ()
  "Return an alist of (ACCOUNT . SPECS) sorted by account name.
Each SPECS is a list of suffix specs sorted by home-row key."
  (let ((groups (make-hash-table :test 'equal)))
    (maphash
     (lambda (buf key)
       (when (buffer-live-p buf)
         (push (ai-agent--session-suffix-spec buf key)
               (gethash (ai-agent--session-group-key buf) groups))))
     ai-agent--session-keys)
    (ai-agent--hash-to-sorted-alist groups)))

(defun ai-agent--session-group-key (buffer)
  "Return the group key for BUFFER in the session switcher.
Uses the backend's :account function if available, falling back
to the backend's :label or symbol name."
  (let ((backend (ai-agent--detect-backend buffer)))
    (or (when-let* ((account-fn (ai-agent--backend-get backend :account)))
          (funcall account-fn buffer))
        (ai-agent--backend-get backend :label)
        (and backend (symbol-name backend))
        "Sessions")))

(defun ai-agent--session-suffix-spec (buf key)
  "Build a transient suffix spec for BUF bound to KEY."
  (let* ((backend (ai-agent--detect-backend buf))
         (icon (when backend (ai-agent-backend-icon backend)))
         (name (ai-agent-display-name buf))
         (label (if (and icon (not (string-empty-p icon)))
                    (format "%s %s" icon name) name))
         (waiting (buffer-local-value
                   'ai-agent--waiting-for-input buf))
         (cmd (make-symbol (format "ai-switch-%s" key)))
         (spec (list key label cmd)))
    (when waiting
      (setq spec (append spec
                         (list :face (ai-agent--waiting-face buf backend)))))
    (fset cmd (lambda () (interactive) (switch-to-buffer buf)))
    spec))

(defun ai-agent--waiting-face (buffer backend)
  "Return the face for BUFFER's waiting indicator.
Uses `ai-agent-waiting-with-background' when BACKEND reports
that BUFFER has active background tasks, `ai-agent-waiting'
otherwise."
  (if (and backend
           (when-let* ((fn (ai-agent--backend-get
                            backend :has-background-tasks-p)))
             (funcall fn buffer)))
      'ai-agent-waiting-with-background
    'ai-agent-waiting))

(defun ai-agent--hash-to-sorted-alist (groups)
  "Convert GROUPS hash table to an alist sorted by key.
Each value's suffix specs are sorted by session-key pool index."
  (let (alist)
    (maphash
     (lambda (group-key specs)
       (push (cons group-key
                   (sort specs
                         (lambda (a b)
                           (< (ai-agent--session-key-index (car a))
                              (ai-agent--session-key-index (car b))))))
             alist))
     groups)
    (sort alist (lambda (a b) (string< (car a) (car b))))))

(defun ai-agent--accountless-labels ()
  "Return labels for backends without an :account function.
These backends don't support multi-account grouping, so their
sessions appear without a heading."
  (let (labels)
    (dolist (entry ai-agent-backends labels)
      (unless (plist-get (cdr entry) :account)
        (when-let* ((label (plist-get (cdr entry) :label)))
          (push label labels))))))

(defun ai-agent--interleave-group-headers (groups)
  "Interleave :info headers before each group's suffix specs.
GROUPS is an alist of (ACCOUNT . SPECS).  When there is only one
group, no headers are added.  Groups whose key matches an
accountless backend label appear without a heading."
  (if (<= (length groups) 1)
      (mapcan #'cdr groups)
    (let ((no-header (ai-agent--accountless-labels)))
      (mapcan (lambda (entry)
                (if (member (car entry) no-header)
                    (copy-sequence (cdr entry))
                  (cons (list :info (car entry)) (cdr entry))))
              groups))))

;;;; Buffer protection

(defun ai-agent-protect-buffer ()
  "Prompt for confirmation before killing AI session buffers.
Returns t if the buffer should be killed, nil otherwise."
  (or (not ai-agent-protect-buffers)
      (not (ai-agent--detect-backend (current-buffer)))
      (not (process-live-p (get-buffer-process (current-buffer))))
      (yes-or-no-p "Kill AI session buffer? ")))

;;;; Session exit

(defun ai-agent-kill-session-buffer ()
  "Kill the current AI session buffer, bypassing confirmation.
Terminates the CLI process if still running, then kills the
buffer.  Signals an error unless the current buffer is an AI
session."
  (interactive)
  (unless (ai-agent--detect-backend (current-buffer))
    (user-error "Not in an AI session buffer"))
  (ai-agent--force-kill-buffer (current-buffer)))

(defun ai-agent--force-kill-buffer (buffer)
  "Terminate the process in BUFFER and kill it without confirmation."
  (when-let* ((proc (get-buffer-process buffer)))
    (set-process-query-on-exit-flag proc nil)
    (set-process-sentinel proc #'ignore)
    (delete-process proc))
  (let ((kill-buffer-query-functions
         (remq 'ai-agent-protect-buffer kill-buffer-query-functions)))
    (kill-buffer buffer)))

;;;; Alert and notification system

(defun ai-agent-notify (title message)
  "Show notification with TITLE and MESSAGE.
When `ai-agent-alert-on-ready' is non-nil, dispatch to the
configured alert style."
  (message "%s: %s" title message)
  (when ai-agent-alert-on-ready
    (ai-agent--alert-visual title message)
    (ai-agent--alert-sound)))

(defun ai-agent--alert-visual (title message)
  "Show a visual notification with TITLE and MESSAGE."
  (when (memq ai-agent-alert-style '(visual both))
    (when (and (require 'alert nil t) (fboundp 'alert))
      (alert message :title title))))

(defun ai-agent--alert-sound ()
  "Play the configured alert sound."
  (when (memq ai-agent-alert-style '(sound both))
    (when-let* ((sound ai-agent-alert-sound)
                ((file-exists-p sound)))
      (start-process "ai-agent-alert-sound" nil "afplay" sound))))

(defun ai-agent--clear-waiting-for-input (&rest _)
  "Clear the waiting-for-input flag in the current buffer."
  (when (bound-and-true-p ai-agent--waiting-for-input)
    (setq ai-agent--waiting-for-input nil)))

;;;###autoload
(defun ai-agent-jump-to-waiting ()
  "Switch to the AI session that most recently started waiting for input."
  (interactive)
  (let (best-buf best-time)
    (dolist (buf (ai-agent--find-all-buffers))
      (when (buffer-live-p buf)
        (let ((ts (buffer-local-value 'ai-agent--waiting-for-input buf)))
          (when (and ts (or (null best-time) (time-less-p best-time ts)))
            (setq best-buf buf best-time ts)))))
    (if best-buf
        (switch-to-buffer best-buf)
      (message "No sessions waiting for input"))))

;;;###autoload
(defun ai-agent-toggle-alert ()
  "Toggle OS notifications for AI sessions."
  (interactive)
  (setq ai-agent-alert-on-ready (not ai-agent-alert-on-ready))
  (message "AI alert notifications %s"
           (if ai-agent-alert-on-ready "enabled" "disabled")))

(defun ai-agent-alert-indicator ()
  "Return a bell icon reflecting the current alert state."
  (if ai-agent-alert-on-ready "🔔" "🔕"))

;;;; Scroll to bottom

(defun ai-agent--scroll-to-bottom (buffer)
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

(defun ai-agent-fix-rendering ()
  "Send SIGWINCH to fix terminal rendering after startup."
  (interactive)
  (when-let* ((proc (get-buffer-process (current-buffer))))
    (ai-agent--send-sigwinch-after-delay (current-buffer))))

(defun ai-agent--send-sigwinch-after-delay (buffer)
  "Send SIGWINCH to the process in BUFFER after a short delay."
  (run-at-time ai-agent-sigwinch-delay nil
               #'ai-agent--send-sigwinch buffer))

(defun ai-agent--send-sigwinch (buffer)
  "Send SIGWINCH to the process in BUFFER."
  (when (buffer-live-p buffer)
    (when-let* ((proc (get-buffer-process buffer)))
      (signal-process proc 'SIGWINCH))))

;;;; Scrollback truncation fix

(defun ai-agent-disable-scrollback-truncation ()
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

(defun ai-agent--expand-snippet-to-text (template)
  "Expand yasnippet TEMPLATE to plain text in a temporary buffer."
  (with-temp-buffer
    (yas-minor-mode 1)
    (let ((yas-prompt-functions '(yas-no-prompt)))
      (yas-expand-snippet (yas--template-content template)
                          nil nil
                          (yas--template-expand-env template)))
    (mapc #'yas--commit-snippet (yas-active-snippets))
    (buffer-string)))

(defun ai-agent--consult-yasnippet (orig-fn arg)
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
        (let* ((expanded (ai-agent--expand-snippet-to-text template))
               (text (replace-regexp-in-string "\n" "\e\r" expanded)))
          (eat-term-send-string eat-terminal text))))))

(advice-add 'consult-yasnippet :around #'ai-agent--consult-yasnippet)

(defun ai-agent--try-expand-snippet-at-prompt ()
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
            (let* ((expanded (ai-agent--expand-snippet-to-text best-match))
                   (text (replace-regexp-in-string "\n" "\e\r" expanded)))
              (eat-term-send-string eat-terminal text))
            t))))))

(defun ai-agent-snippet-tab ()
  "Try snippet expansion at prompt, otherwise send TAB to eat."
  (interactive)
  (unless (ai-agent--try-expand-snippet-at-prompt)
    (eat-self-input 1 ?\t)))

(defvar ai-agent--snippet-keys-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'ai-agent-snippet-tab)
    (define-key map [tab] #'ai-agent-snippet-tab)
    map)
  "Keymap for `ai-agent--snippet-keys-mode'.")

(define-minor-mode ai-agent--snippet-keys-mode
  "Minor mode providing yasnippet TAB expansion in AI session buffers."
  :keymap ai-agent--snippet-keys-mode-map)

(defun ai-agent-setup-snippet-keys ()
  "Enable yasnippet TAB expansion in the current AI session buffer."
  (when (and (ai-agent--detect-backend (current-buffer))
             (bound-and-true-p eat-terminal)
             (require 'yasnippet nil t))
    (yas-minor-mode 1)
    (ai-agent--snippet-keys-mode 1)))

;;;; Escape key fix

(defun ai-agent--send-escape-in-current-buffer (orig-fn)
  "When already in an AI buffer, send escape directly without prompting.
ORIG-FN is the original escape command."
  (if (ai-agent--detect-backend (current-buffer))
      (when (bound-and-true-p eat-terminal)
        (eat-term-send-string eat-terminal (kbd "ESC")))
    (funcall orig-fn)))

;;;; Command dispatchers

(defun ai-agent--resolve-backend ()
  "Return the backend for the current context.
If in a session buffer, use that backend.  If only one backend is
registered, use it.  Otherwise, prompt."
  (or (ai-agent--detect-backend)
      (if (= (length ai-agent-backends) 1)
          (caar ai-agent-backends)
        (let* ((entries (mapcar (lambda (e)
                                  (cons (or (plist-get (cdr e) :label)
                                            (symbol-name (car e)))
                                        (car e)))
                                ai-agent-backends))
               (labels (mapcar #'car entries))
               (affixate (lambda (cands)
                           (mapcar (lambda (c)
                                     (let* ((sym (cdr (assoc c entries)))
                                            (icon (ai-agent-backend-icon sym)))
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

(defun ai-agent--dispatch (key)
  "Dispatch command KEY to the appropriate backend.
Uses `call-interactively' so the target command's interactive spec
runs and prompts for arguments as needed."
  (let* ((backend (ai-agent--resolve-backend))
         (fn (ai-agent--backend-get backend key)))
    (if fn
        (call-interactively fn)
      (user-error "Backend `%s' does not support `%s'" backend key))))

(defun ai-agent--skill-argument-candidates (skill)
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

(defun ai-agent-parse-skill-frontmatter (file)
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
                    (ai-agent--put-skill-frontmatter-field
                     result
                     (match-string 1 line)
                     (ai-agent--clean-skill-frontmatter-value
                      (match-string 2 line)))))))
        result))))

(defun ai-agent--clean-skill-frontmatter-value (value)
  "Return normalized frontmatter VALUE."
  (let ((val (string-trim value)))
    (if (string-match "^[\"']\\(.*\\)[\"']$" val)
        (match-string 1 val)
      val)))

(defun ai-agent--put-skill-frontmatter-field (plist key value)
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

(defun ai-agent--discover-all-skills ()
  "Discover skills from all registered backends.
Calls each backend's `:discover-skills' function and returns a
combined list of skill plists, each augmented with `:backend'."
  (let (all-skills)
    (dolist (entry ai-agent-backends)
      (when-let* ((discover-fn (plist-get (cdr entry) :discover-skills)))
        (dolist (skill (funcall discover-fn))
          (push (plist-put (copy-sequence skill) :backend (car entry))
                all-skills))))
    (sort all-skills (lambda (a b)
                       (string< (plist-get a :name) (plist-get b :name))))))

(defun ai-agent--skill-candidate (skill)
  "Return a unique completion candidate for SKILL."
  (let* ((backend (plist-get skill :backend))
         (label (or (ai-agent--backend-get backend :label)
                    (symbol-name backend))))
    (propertize (format "%s [%s]" (plist-get skill :name) label)
                'ai-agent-skill skill)))

(defun ai-agent--skill-candidates (skills)
  "Return completion candidates for SKILLS with embedded skill plists."
  (mapcar #'ai-agent--skill-candidate skills))

(defun ai-agent--skill-from-candidate (candidate candidates)
  "Return the skill plist for CANDIDATE from CANDIDATES."
  (or (get-text-property 0 'ai-agent-skill candidate)
      (get-text-property 0 'ai-agent-skill
                         (cl-find candidate candidates :test #'string=))))

;;;###autoload
(defun ai-agent-handoff ()
  "Close the current session and start a new one with the handoff prompt.
Dispatches to the appropriate backend."
  (interactive)
  (ai-agent--dispatch :handoff))

;;;###autoload
(defun ai-agent-run-skill ()
  "Discover and run a skill from any registered backend.
Shows an aggregated list of all skills with an indication of
the backend next to each."
  (interactive)
  (let* ((skills (ai-agent--discover-all-skills))
         (_ (unless skills (user-error "No user-invocable skills found")))
         (skill-candidates (ai-agent--skill-candidates skills))
         (max-cand-len (apply #'max (mapcar #'length skill-candidates)))
         (annotate
          (lambda (cand)
            (when-let* ((skill (ai-agent--skill-from-candidate
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
         (skill (ai-agent--skill-from-candidate candidate skill-candidates))
         (backend (plist-get skill :backend))
         ;; Prompt for arguments using skill metadata
         (hint (plist-get skill :argument-hint))
         (candidates (ai-agent--skill-argument-candidates skill))
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
         (run-fn (ai-agent--backend-get backend :run-skill)))
    (unless run-fn
      (user-error "Backend `%s' does not support `:run-skill'" backend))
    (funcall run-fn (plist-get skill :name) args)))

;;;###autoload
(defun ai-agent-audit-project ()
  "Run a comprehensive project audit via the appropriate backend."
  (interactive)
  (ai-agent--dispatch :audit-project))

;;;###autoload
(defun ai-agent-debug-backtrace ()
  "Analyze a backtrace and start a session in the culprit package."
  (interactive)
  (ai-agent--dispatch :debug-backtrace))

;;;###autoload
(defun ai-agent-setup-kill-on-exit ()
  "Arrange for the buffer to be killed when the session process exits."
  (interactive)
  (ai-agent--dispatch :setup-kill-on-exit))

;;;###autoload
(defun ai-agent-exit ()
  "Exit the current AI session and kill its buffer.
Dispatches to the backend's `:exit' handler, which should
terminate the CLI process and kill the buffer."
  (interactive)
  (ai-agent--dispatch :exit))

;;;###autoload
(defun ai-agent-restart ()
  "Kill the current AI session and resume it in place.
Useful when a setting change requires relaunching the CLI.
Dispatches to the backend's `:restart' handler."
  (interactive)
  (ai-agent--dispatch :restart))

;;;; Transient boolean infix class

(eval-and-compile
  (defclass ai-agent--boolean-variable (transient-lisp-variable)
    ()
    "A `transient-lisp-variable' that toggles a boolean on each press."))

(cl-defmethod transient-infix-read ((obj ai-agent--boolean-variable))
  "Toggle the boolean value of OBJ."
  (not (oref obj value)))

;;;; Transient menu

;;;###autoload (autoload 'ai-agent-menu "ai-agent" nil t)
(transient-define-prefix ai-agent-menu ()
  "Dispatch AI session commands."
  [["Sessions"
    ("e" "start or switch" ai-agent-start-or-switch)
    ("w" "jump to waiting" ai-agent-jump-to-waiting)
    ("h" "handoff" ai-agent-handoff)
    ("x" "exit session" ai-agent-exit)
    ("r" "restart" ai-agent-restart)
    ""
    "Buffer"
    ("K" "setup kill on exit" ai-agent-setup-kill-on-exit)
    ("f" "fix rendering" ai-agent-fix-rendering)
    ("S" "disable scrollback" ai-agent-disable-scrollback-truncation)]
   ["Tools"
    ("s" "run skill" ai-agent-run-skill)
    ("a" "audit project" ai-agent-audit-project)
    ("d" "debug backtrace" ai-agent-debug-backtrace)
    ""
    "Alerts"
    ("T" "toggle alert" ai-agent-toggle-alert)]
   ["Options"
    ("-A" ai-agent--infix-alert-on-ready)
    ("-p" ai-agent--infix-protect-buffers)
    ("-t" ai-agent--infix-sync-theme)]])

(transient-define-infix ai-agent--infix-alert-on-ready ()
  "Toggle `ai-agent-alert-on-ready'."
  :class 'ai-agent--boolean-variable
  :variable 'ai-agent-alert-on-ready
  :description "alert on ready")

(transient-define-infix ai-agent--infix-protect-buffers ()
  "Toggle `ai-agent-protect-buffers'."
  :class 'ai-agent--boolean-variable
  :variable 'ai-agent-protect-buffers
  :description "protect buffers")

(eval-and-compile
  (defclass ai-agent--sync-theme-variable (ai-agent--boolean-variable)
    ()
    "A boolean infix that syncs themes when enabled."))

(cl-defmethod transient-infix-set :after
  ((obj ai-agent--sync-theme-variable) _value)
  "Sync themes after OBJ enables `ai-agent-sync-theme'."
  (when (symbol-value (oref obj variable))
    (ai-agent-sync-theme-now)))

(transient-define-infix ai-agent--infix-sync-theme ()
  "Toggle `ai-agent-sync-theme'."
  :class 'ai-agent--sync-theme-variable
  :variable 'ai-agent-sync-theme
  :description "sync theme")

(add-hook 'enable-theme-functions #'ai-agent-sync-theme)

;;;; Provide

(provide 'ai-agent)
;;; ai-agent.el ends here
