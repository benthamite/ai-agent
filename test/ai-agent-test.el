;;; ai-agent-test.el --- Tests for ai-agent -*- lexical-binding: t -*-

;; Tests for pure and near-pure helper functions in ai-agent.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ai-agent)

(defun ai-agent-test--backend (&rest keys)
  "Return a minimal valid backend plist extended with KEYS."
  (append
   keys
   (list :buffer-p (lambda (_buffer) nil)
         :find-all-buffers (lambda () nil)
         :extract-instance-name (lambda (_buffer-name) nil)
         :start-new #'ignore
         :label "Test")))

;;;; Theme sync

(ert-deftest ai-agent-test-sync-theme-dispatches-to-backends ()
  "Dispatch theme sync to all registered backend handlers."
  (let ((ai-agent-backends nil)
        (seen nil))
    (ai-agent-register-backend
     'one
     (ai-agent-test--backend
      :sync-theme (lambda (theme) (push (cons 'one theme) seen))))
    (ai-agent-register-backend
     'two
     (ai-agent-test--backend
      :sync-theme (lambda (theme) (push (cons 'two theme) seen))))
    (cl-letf (((symbol-function 'frame-parameter)
               (lambda (_frame param)
                 (when (eq param 'background-mode) 'dark))))
      (ai-agent--do-sync-theme t)
      (should (equal (sort seen (lambda (a b)
                                  (string< (symbol-name (car a))
                                           (symbol-name (car b)))))
                     '((one . "dark") (two . "dark")))))))

(ert-deftest ai-agent-test-sync-theme-before-start-respects-toggle ()
  "Do not sync immediately when `ai-agent-sync-theme' is disabled."
  (let ((ai-agent-sync-theme nil)
        (called nil))
    (cl-letf (((symbol-function 'ai-agent--do-sync-theme)
               (lambda () (setq called t))))
      (ai-agent-sync-theme-now)
      (should-not called))))

;;;; Backend registration

(ert-deftest ai-agent-test-register-backend-requires-session-keys ()
  "Reject backend registrations that are missing required keys."
  (let ((ai-agent-backends nil))
    (should-error
     (ai-agent-register-backend 'bad (list :buffer-p #'ignore)))))

;;;; Session keys and display names

(ert-deftest ai-agent-test-ensure-session-keys-assigns-home-row-keys ()
  "Assign home-row keys to all active backend buffers."
  (let ((ai-agent-backends nil)
        (ai-agent--session-keys (make-hash-table :test 'eq)))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/a/:default*" t)
      (let ((one (current-buffer)))
        (with-temp-buffer
          (rename-buffer "*one:~/repo/b/:default*" t)
          (let ((two (current-buffer)))
            (ai-agent-register-backend
             'one
             (ai-agent-test--backend
              :buffer-p (lambda (buf)
                          (string-prefix-p "*one:" (buffer-name buf)))
              :find-all-buffers (lambda () (list one two))))
            (ai-agent--ensure-all-session-keys)
            (should (equal (gethash one ai-agent--session-keys) "a"))
            (should (equal (gethash two ai-agent--session-keys) "s"))))))))

(ert-deftest ai-agent-test-display-name-appends-backend-suffix ()
  "Append backend display suffixes after the shared base name."
  (let ((ai-agent-backends nil)
        (ai-agent--session-keys (make-hash-table :test 'eq)))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/project/:default*" t)
      (let ((buf (current-buffer)))
        (ai-agent-register-backend
         'one
         (ai-agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :find-all-buffers (lambda () (list buf))
          :display-name-suffix (lambda (_buffer) "branch")))
        (should (equal (ai-agent-display-name buf) "project:branch"))))))

(ert-deftest ai-agent-test-session-groups-use-account-key ()
  "Group session switcher suffixes by backend account."
  (let ((ai-agent-backends nil)
        (ai-agent--session-keys (make-hash-table :test 'eq)))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/a/:default*" t)
      (let ((buf (current-buffer)))
        (ai-agent-register-backend
         'one
         (ai-agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :find-all-buffers (lambda () (list buf))
          :account (lambda (_buffer) "work")))
        (puthash buf "a" ai-agent--session-keys)
        (should (equal (mapcar #'car (ai-agent--group-sessions-by-account))
                       '("work")))))))

(ert-deftest ai-agent-test-waiting-face-detects-background-work ()
  "Use the background-work face when the backend reports work."
  (let ((ai-agent-backends nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (ai-agent-register-backend
         'one
         (ai-agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :find-all-buffers (lambda () (list buf))
          :has-background-tasks-p (lambda (_buffer) t)))
        (should (eq (ai-agent--waiting-face buf 'one)
                    'ai-agent-waiting-with-background))))))

;;;; Skills

(ert-deftest ai-agent-test-run-skill-distinguishes-backends ()
  "Run the selected backend skill when names collide."
  (let ((ai-agent-backends nil)
        (ran nil))
    (ai-agent-register-backend
     'one
     (ai-agent-test--backend
      :label "One"
      :discover-skills (lambda () (list (list :name "audit")))
      :run-skill (lambda (name args) (setq ran (list 'one name args)))))
    (ai-agent-register-backend
     'two
     (ai-agent-test--backend
      :label "Two"
      :discover-skills (lambda () (list (list :name "audit")))
      :run-skill (lambda (name args) (setq ran (list 'two name args)))))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _args) "audit [Two]")))
      (ai-agent-run-skill)
      (should (equal ran '(two "audit" nil))))))

(ert-deftest ai-agent-test-post-push-ci-runs-skill-for-head ()
  "Run post-push CI through the selected backend with the current HEAD."
  (let ((ai-agent-backends nil)
        ran)
    (ai-agent-register-backend
     'one
     (ai-agent-test--backend
      :run-skill (lambda (name args) (setq ran (list name args)))))
    (cl-letf (((symbol-function 'process-file)
               (lambda (&rest _args)
                 (insert "abc123\n")
                 0)))
      (ai-agent-post-push-ci)
      (should (equal ran '("post-push-ci" "--no-push --commit abc123"))))))

(ert-deftest ai-agent-test-exit-runs-before-exit-functions ()
  "Abort exit when a before-exit function returns nil."
  (let ((ai-agent-backends nil)
        (ai-agent-before-exit-functions nil)
        ran
        seen)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (ai-agent-register-backend
         'one
         (ai-agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :exit (lambda () (interactive) (setq ran t))))
        (add-hook 'ai-agent-before-exit-functions
                  (lambda (backend buffer)
                    (setq seen (list backend buffer))
                    nil))
        (ai-agent-exit)
        (should (equal seen (list 'one buf)))
        (should-not ran)))))

(ert-deftest ai-agent-test-exit-proceeds-after-before-exit-functions ()
  "Exit when every before-exit function returns non-nil."
  (let ((ai-agent-backends nil)
        (ai-agent-before-exit-functions nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (ai-agent-register-backend
         'one
         (ai-agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :exit (lambda () (interactive) (setq ran t))))
        (add-hook 'ai-agent-before-exit-functions (lambda (_backend _buffer) t))
        (ai-agent-exit)
        (should ran)))))

(ert-deftest ai-agent-test-run-skill-before-exit-submits-codex-skill ()
  "Submit a Codex skill and abort the first exit in matching directories."
  (let ((ai-agent-backends nil)
        (ai-agent-before-exit-skill-name "session-retro")
        (ai-agent-before-exit-skill-directories nil)
        events)
    (with-temp-buffer
      (let* ((dir (file-name-as-directory default-directory))
             (buf (current-buffer))
             (ai-agent-before-exit-skill-directories (list dir)))
        (ai-agent-register-backend
         'codex
         (ai-agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :directory (lambda (_buffer) dir)
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (should-not (ai-agent-run-skill-before-exit 'codex buf))
        (should (equal (nreverse events)
                       '((command "$session-retro") return)))
        (should ai-agent--before-exit-skill-sent)
        (should (ai-agent-run-skill-before-exit 'codex buf))))))

(ert-deftest ai-agent-test-run-skill-before-exit-uses-claude-slash ()
  "Submit Claude skills with slash syntax."
  (let ((ai-agent-backends nil)
        (ai-agent-before-exit-skill-name "session-retro")
        (events nil))
    (with-temp-buffer
      (let* ((dir (file-name-as-directory default-directory))
             (buf (current-buffer))
             (ai-agent-before-exit-skill-directories (list dir)))
        (ai-agent-register-backend
         'claude-code
         (ai-agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :directory (lambda (_buffer) dir)
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (should-not (ai-agent-run-skill-before-exit 'claude-code buf))
        (should (equal (nreverse events)
                       '((command "/session-retro") return)))))))

(ert-deftest ai-agent-test-run-skill-before-exit-skips-other-directories ()
  "Do not submit before-exit skills outside configured directories."
  (let ((ai-agent-backends nil)
        (ai-agent-before-exit-skill-name "session-retro")
        (ai-agent-before-exit-skill-directories '("/tmp/not-this-repo/"))
        called)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (ai-agent-register-backend
         'codex
         (ai-agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :directory (lambda (_buffer) default-directory)
          :send-command (lambda (&rest _args) (setq called t))))
        (should (ai-agent-run-skill-before-exit 'codex buf))
        (should-not called)))))

(ert-deftest ai-agent-test-run-skill-before-exit-skips-unknown-backends ()
  "Do not abort exit when BACKEND has no skill command prefix."
  (let ((ai-agent-backends nil)
        (ai-agent-before-exit-skill-name "session-retro")
        called)
    (with-temp-buffer
      (let* ((dir (file-name-as-directory default-directory))
             (buf (current-buffer))
             (ai-agent-before-exit-skill-directories (list dir)))
        (ai-agent-register-backend
         'other
         (ai-agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :directory (lambda (_buffer) dir)
          :send-command (lambda (&rest _args) (setq called t))))
        (should (ai-agent-run-skill-before-exit 'other buf))
        (should-not called)))))

(ert-deftest ai-agent-test-discover-all-skills-skips-non-invocable ()
  "Do not expose skills marked `user-invocable: false'."
  (let ((ai-agent-backends nil))
    (ai-agent-register-backend
     'one
     (ai-agent-test--backend
      :discover-skills (lambda ()
                         (list (list :name "visible")
                               (list :name "hidden"
                                     :user-invocable nil)))))
    (should (equal (mapcar (lambda (skill) (plist-get skill :name))
                           (ai-agent--discover-all-skills))
                   '("visible")))))

;;;; Alerts

(ert-deftest ai-agent-test-alert-sound-error-is-nonfatal ()
  "Report sound playback errors without signaling."
  (let ((sound-file (make-temp-file "ai-agent-test-sound" nil ".aiff"))
        messages)
    (unwind-protect
        (let ((ai-agent-alert-style 'sound)
              (ai-agent-alert-sound sound-file))
          (cl-letf (((symbol-function 'play-sound-file)
                     (lambda (_file) (error "no sound support")))
                    ((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (push (apply #'format format-string args) messages))))
            (should (condition-case nil
                        (progn
                          (ai-agent--alert-sound)
                          t)
                      (error nil)))
            (should (member "AI alert sound failed: no sound support" messages))))
      (delete-file sound-file))))

(ert-deftest ai-agent-test-parse-skill-frontmatter-argument-metadata ()
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
          (let ((meta (ai-agent-parse-skill-frontmatter file)))
            (should (equal (plist-get meta :name) "convert"))
            (should (equal (plist-get meta :argument-choices) '("a" "b")))
            (should (equal (plist-get meta :argument-default) "a"))
            (should-not (plist-get meta :argument-multiple))
            (should-not (plist-get meta :user-invocable))
            (should (equal (plist-get meta :model) "gpt-5.5"))))
      (delete-file file))))

(provide 'ai-agent-test)
;;; ai-agent-test.el ends here
