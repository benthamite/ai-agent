;;; agents-test.el --- Tests for agents -*- lexical-binding: t -*-

;; Tests for pure and near-pure helper functions in agents.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agents)

(defun agents-test--backend (&rest keys)
  "Return a minimal valid backend plist extended with KEYS."
  (append
   keys
   (list :buffer-p (lambda (_buffer) nil)
         :find-all-buffers (lambda () nil)
         :extract-instance-name (lambda (_buffer-name) nil)
         :start-new #'ignore
         :label "Test")))

;;;; Theme sync

(ert-deftest agents-test-sync-theme-dispatches-to-backends ()
  "Dispatch theme sync to all registered backend handlers."
  (let ((agents-backends nil)
        (seen nil))
    (agents-register-backend
     'one
     (agents-test--backend
      :sync-theme (lambda (theme) (push (cons 'one theme) seen))))
    (agents-register-backend
     'two
     (agents-test--backend
      :sync-theme (lambda (theme) (push (cons 'two theme) seen))))
    (cl-letf (((symbol-function 'frame-parameter)
               (lambda (_frame param)
                 (when (eq param 'background-mode) 'dark))))
      (agents--do-sync-theme t)
      (should (equal (sort seen (lambda (a b)
                                  (string< (symbol-name (car a))
                                           (symbol-name (car b)))))
                     '((one . "dark") (two . "dark")))))))

(ert-deftest agents-test-sync-theme-before-start-respects-toggle ()
  "Do not sync immediately when `agents-sync-theme' is disabled."
  (let ((agents-sync-theme nil)
        (called nil))
    (cl-letf (((symbol-function 'agents--do-sync-theme)
               (lambda () (setq called t))))
      (agents-sync-theme-now)
      (should-not called))))

;;;; Backend registration

(ert-deftest agents-test-register-backend-requires-session-keys ()
  "Reject backend registrations that are missing required keys."
  (let ((agents-backends nil))
    (should-error
     (agents-register-backend 'bad (list :buffer-p #'ignore)))))

;;;; Session keys and display names

(ert-deftest agents-test-ensure-session-keys-assigns-home-row-keys ()
  "Assign home-row keys to all active backend buffers."
  (let ((agents-backends nil)
        (agents--session-keys (make-hash-table :test 'eq)))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/a/:default*" t)
      (let ((one (current-buffer)))
        (with-temp-buffer
          (rename-buffer "*one:~/repo/b/:default*" t)
          (let ((two (current-buffer)))
            (agents-register-backend
             'one
             (agents-test--backend
              :buffer-p (lambda (buf)
                          (string-prefix-p "*one:" (buffer-name buf)))
              :find-all-buffers (lambda () (list one two))))
            (agents--ensure-all-session-keys)
            (should (equal (gethash one agents--session-keys) "a"))
            (should (equal (gethash two agents--session-keys) "s"))))))))

(ert-deftest agents-test-display-name-appends-backend-suffix ()
  "Append backend display suffixes after the shared base name."
  (let ((agents-backends nil)
        (agents--session-keys (make-hash-table :test 'eq)))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/project/:default*" t)
      (let ((buf (current-buffer)))
        (agents-register-backend
         'one
         (agents-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :find-all-buffers (lambda () (list buf))
          :display-name-suffix (lambda (_buffer) "branch")))
        (should (equal (agents-display-name buf) "project:branch"))))))

(ert-deftest agents-test-session-groups-use-account-key ()
  "Group session switcher suffixes by backend account."
  (let ((agents-backends nil)
        (agents--session-keys (make-hash-table :test 'eq)))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/a/:default*" t)
      (let ((buf (current-buffer)))
        (agents-register-backend
         'one
         (agents-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :find-all-buffers (lambda () (list buf))
          :account (lambda (_buffer) "work")))
        (puthash buf "a" agents--session-keys)
        (should (equal (mapcar #'car (agents--group-sessions-by-account))
                       '("work")))))))

(ert-deftest agents-test-waiting-face-detects-background-work ()
  "Use the background-work face when the backend reports work."
  (let ((agents-backends nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agents-register-backend
         'one
         (agents-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :find-all-buffers (lambda () (list buf))
          :has-background-tasks-p (lambda (_buffer) t)))
        (should (eq (agents--waiting-face buf 'one)
                    'agents-waiting-with-background))))))

;;;; Skills

(ert-deftest agents-test-run-skill-distinguishes-backends ()
  "Run the selected backend skill when names collide."
  (let ((agents-backends nil)
        (ran nil))
    (agents-register-backend
     'one
     (agents-test--backend
      :label "One"
      :discover-skills (lambda () (list (list :name "audit")))
      :run-skill (lambda (name args) (setq ran (list 'one name args)))))
    (agents-register-backend
     'two
     (agents-test--backend
      :label "Two"
      :discover-skills (lambda () (list (list :name "audit")))
      :run-skill (lambda (name args) (setq ran (list 'two name args)))))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _args) "audit [Two]")))
      (agents-run-skill)
      (should (equal ran '(two "audit" nil))))))

(ert-deftest agents-test-post-push-ci-runs-skill-for-head ()
  "Run post-push CI through the selected backend with the current HEAD."
  (let ((agents-backends nil)
        ran)
    (agents-register-backend
     'one
     (agents-test--backend
      :run-skill (lambda (name args) (setq ran (list name args)))))
    (cl-letf (((symbol-function 'process-file)
               (lambda (&rest _args)
                 (insert "abc123\n")
                 0)))
      (agents-post-push-ci)
      (should (equal ran '("post-push-ci" "--no-push --commit abc123"))))))

(ert-deftest agents-test-exit-runs-before-exit-functions ()
  "Abort exit when a before-exit function returns nil."
  (let ((agents-backends nil)
        (agents-before-exit-functions nil)
        ran
        seen)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agents-register-backend
         'one
         (agents-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :exit (lambda () (interactive) (setq ran t))))
        (add-hook 'agents-before-exit-functions
                  (lambda (backend buffer)
                    (setq seen (list backend buffer))
                    nil))
        (agents-exit)
        (should (equal seen (list 'one buf)))
        (should-not ran)))))

(ert-deftest agents-test-exit-proceeds-after-before-exit-functions ()
  "Exit when every before-exit function returns non-nil."
  (let ((agents-backends nil)
        (agents-before-exit-functions nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agents-register-backend
         'one
         (agents-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :exit (lambda () (interactive) (setq ran t))))
        (add-hook 'agents-before-exit-functions (lambda (_backend _buffer) t))
        (agents-exit)
        (should ran)))))

(ert-deftest agents-test-run-skill-before-exit-submits-codex-skill ()
  "Submit a Codex skill and abort the first exit in matching directories."
  (let ((agents-backends nil)
        (agents-before-exit-skill-name "session-retro")
        (agents-before-exit-skill-directories nil)
        events)
    (with-temp-buffer
      (let* ((dir (file-name-as-directory default-directory))
             (buf (current-buffer))
             (agents-before-exit-skill-directories (list dir)))
        (agents-register-backend
         'codex
         (agents-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :directory (lambda (_buffer) dir)
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (should-not (agents-run-skill-before-exit 'codex buf))
        (should (equal (nreverse events)
                       '((command "$session-retro") return)))
        (should agents--before-exit-skill-sent)
        (should (agents-run-skill-before-exit 'codex buf))))))

(ert-deftest agents-test-run-skill-before-exit-uses-claude-slash ()
  "Submit Claude skills with slash syntax."
  (let ((agents-backends nil)
        (agents-before-exit-skill-name "session-retro")
        (events nil))
    (with-temp-buffer
      (let* ((dir (file-name-as-directory default-directory))
             (buf (current-buffer))
             (agents-before-exit-skill-directories (list dir)))
        (agents-register-backend
         'claude-code
         (agents-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :directory (lambda (_buffer) dir)
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (should-not (agents-run-skill-before-exit 'claude-code buf))
        (should (equal (nreverse events)
                       '((command "/session-retro") return)))))))

(ert-deftest agents-test-run-skill-before-exit-skips-other-directories ()
  "Do not submit before-exit skills outside configured directories."
  (let ((agents-backends nil)
        (agents-before-exit-skill-name "session-retro")
        (agents-before-exit-skill-directories '("/tmp/not-this-repo/"))
        called)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agents-register-backend
         'codex
         (agents-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :directory (lambda (_buffer) default-directory)
          :send-command (lambda (&rest _args) (setq called t))))
        (should (agents-run-skill-before-exit 'codex buf))
        (should-not called)))))

(ert-deftest agents-test-run-skill-before-exit-skips-unknown-backends ()
  "Do not abort exit when BACKEND has no skill command prefix."
  (let ((agents-backends nil)
        (agents-before-exit-skill-name "session-retro")
        called)
    (with-temp-buffer
      (let* ((dir (file-name-as-directory default-directory))
             (buf (current-buffer))
             (agents-before-exit-skill-directories (list dir)))
        (agents-register-backend
         'other
         (agents-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :directory (lambda (_buffer) dir)
          :send-command (lambda (&rest _args) (setq called t))))
        (should (agents-run-skill-before-exit 'other buf))
        (should-not called)))))

(ert-deftest agents-test-discover-all-skills-skips-non-invocable ()
  "Do not expose skills marked `user-invocable: false'."
  (let ((agents-backends nil))
    (agents-register-backend
     'one
     (agents-test--backend
      :discover-skills (lambda ()
                         (list (list :name "visible")
                               (list :name "hidden"
                                     :user-invocable nil)))))
    (should (equal (mapcar (lambda (skill) (plist-get skill :name))
                           (agents--discover-all-skills))
                   '("visible")))))

;;;; Alerts

(ert-deftest agents-test-alert-sound-error-is-nonfatal ()
  "Report sound playback errors without signaling."
  (let ((sound-file (make-temp-file "agents-test-sound" nil ".aiff"))
        messages)
    (unwind-protect
        (let ((agents-alert-style 'sound)
              (agents-alert-sound sound-file))
          (cl-letf (((symbol-function 'play-sound-file)
                     (lambda (_file) (error "no sound support")))
                    ((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (push (apply #'format format-string args) messages))))
            (should (condition-case nil
                        (progn
                          (agents--alert-sound)
                          t)
                      (error nil)))
            (should (member "AI alert sound failed: no sound support" messages))))
      (delete-file sound-file))))

(ert-deftest agents-test-parse-skill-frontmatter-argument-metadata ()
  "Parse shared skill argument metadata from frontmatter."
  (let ((file (make-temp-file "skill" nil ".md")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "---\n")
            (insert "name: convert\n")
            (insert "description: Convert citations\n")
            (insert "argument-hint: FILE\n")
            (insert "argument-choices: a, b\n")
            (insert "argument-default: a\n")
            (insert "argument-multiple: false\n")
            (insert "user-invocable: false\n")
            (insert "model: gpt-5.5\n")
            (insert "---\n"))
          (let ((meta (agents-parse-skill-frontmatter file)))
            (should (equal (plist-get meta :name) "convert"))
            (should (equal (plist-get meta :argument-choices) '("a" "b")))
            (should (equal (plist-get meta :argument-default) "a"))
            (should-not (plist-get meta :argument-multiple))
            (should-not (plist-get meta :user-invocable))
            (should (equal (plist-get meta :model) "gpt-5.5"))))
      (delete-file file))))

(provide 'agents-test)
;;; agents-test.el ends here
