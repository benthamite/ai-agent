;;; agent-test.el --- Tests for agent -*- lexical-binding: t -*-

;; Tests for pure and near-pure helper functions in agent.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent)

(defun agent-test--backend (&rest keys)
  "Return a minimal valid backend plist extended with KEYS."
  (append
   keys
   (list :buffer-p (lambda (_buffer) nil)
         :find-all-buffers (lambda () nil)
         :extract-instance-name (lambda (_buffer-name) nil)
         :start-new #'ignore
         :label "Test")))

;;;; Theme sync

(ert-deftest agent-test-sync-theme-dispatches-to-backends ()
  "Dispatch theme sync to all registered backend handlers."
  (let ((agent-backends nil)
        (seen nil))
    (agent-register-backend
     'one
     (agent-test--backend
      :sync-theme (lambda (theme) (push (cons 'one theme) seen))))
    (agent-register-backend
     'two
     (agent-test--backend
      :sync-theme (lambda (theme) (push (cons 'two theme) seen))))
    (cl-letf (((symbol-function 'frame-parameter)
               (lambda (_frame param)
                 (when (eq param 'background-mode) 'dark))))
      (agent--do-sync-theme t)
      (should (equal (sort seen (lambda (a b)
                                  (string< (symbol-name (car a))
                                           (symbol-name (car b)))))
                     '((one . "dark") (two . "dark")))))))

(ert-deftest agent-test-sync-theme-before-start-respects-toggle ()
  "Do not sync immediately when `agent-sync-theme' is disabled."
  (let ((agent-sync-theme nil)
        (called nil))
    (cl-letf (((symbol-function 'agent--do-sync-theme)
               (lambda () (setq called t))))
      (agent-sync-theme-now)
      (should-not called))))

;;;; Backend registration

(ert-deftest agent-test-register-backend-requires-session-keys ()
  "Reject backend registrations that are missing required keys."
  (let ((agent-backends nil))
    (should-error
     (agent-register-backend 'bad (list :buffer-p #'ignore)))))

;;;; Session keys and display names

(ert-deftest agent-test-ensure-session-keys-assigns-home-row-keys ()
  "Assign home-row keys to all active backend buffers."
  (let ((agent-backends nil)
        (agent--session-keys (make-hash-table :test 'eq)))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/a/:default*" t)
      (let ((one (current-buffer)))
        (with-temp-buffer
          (rename-buffer "*one:~/repo/b/:default*" t)
          (let ((two (current-buffer)))
            (agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (buf)
                          (string-prefix-p "*one:" (buffer-name buf)))
              :find-all-buffers (lambda () (list one two))))
            (agent--ensure-all-session-keys)
            (should (equal (gethash one agent--session-keys) "a"))
            (should (equal (gethash two agent--session-keys) "s"))))))))

(ert-deftest agent-test-display-name-appends-backend-suffix ()
  "Append backend display suffixes after the shared base name."
  (let ((agent-backends nil)
        (agent--session-keys (make-hash-table :test 'eq)))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/project/:default*" t)
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :find-all-buffers (lambda () (list buf))
          :display-name-suffix (lambda (_buffer) "branch")))
        (should (equal (agent-display-name buf) "project:branch"))))))

(ert-deftest agent-test-session-groups-use-account-key ()
  "Group session switcher suffixes by backend account."
  (let ((agent-backends nil)
        (agent--session-keys (make-hash-table :test 'eq)))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/a/:default*" t)
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :find-all-buffers (lambda () (list buf))
          :account (lambda (_buffer) "work")))
        (puthash buf "a" agent--session-keys)
        (should (equal (mapcar #'car (agent--group-sessions-by-account))
                       '("work")))))))

(ert-deftest agent-test-waiting-face-detects-background-work ()
  "Use the background-work face when the backend reports work."
  (let ((agent-backends nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :find-all-buffers (lambda () (list buf))
          :has-background-tasks-p (lambda (_buffer) t)))
        (should (eq (agent--waiting-face buf 'one)
                    'agent-waiting-with-background))))))

;;;; Skills

(ert-deftest agent-test-run-skill-distinguishes-backends ()
  "Run the selected backend skill when names collide."
  (let ((agent-backends nil)
        (ran nil))
    (agent-register-backend
     'one
     (agent-test--backend
      :label "One"
      :discover-skills (lambda () (list (list :name "audit")))
      :run-skill (lambda (name args) (setq ran (list 'one name args)))))
    (agent-register-backend
     'two
     (agent-test--backend
      :label "Two"
      :discover-skills (lambda () (list (list :name "audit")))
      :run-skill (lambda (name args) (setq ran (list 'two name args)))))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _args) "audit [Two]")))
      (agent-run-skill)
      (should (equal ran '(two "audit" nil))))))

(ert-deftest agent-test-post-push-ci-runs-skill-for-head ()
  "Run post-push CI through the selected backend with the current HEAD."
  (let ((agent-backends nil)
        ran)
    (agent-register-backend
     'one
     (agent-test--backend
      :run-skill (lambda (name args) (setq ran (list name args)))))
    (cl-letf (((symbol-function 'process-file)
               (lambda (&rest _args)
                 (insert "abc123\n")
                 0)))
      (agent-post-push-ci)
      (should (equal ran '("post-push-ci" "--no-push --commit abc123"))))))

(ert-deftest agent-test-exit-runs-before-exit-functions ()
  "Abort exit when a before-exit function returns nil."
  (let ((agent-backends nil)
        (agent-before-exit-functions nil)
        ran
        seen)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :exit (lambda () (interactive) (setq ran t))))
        (add-hook 'agent-before-exit-functions
                  (lambda (backend buffer)
                    (setq seen (list backend buffer))
                    nil))
        (agent-exit)
        (should (equal seen (list 'one buf)))
        (should-not ran)))))

(ert-deftest agent-test-exit-proceeds-after-before-exit-functions ()
  "Exit when every before-exit function returns non-nil."
  (let ((agent-backends nil)
        (agent-before-exit-functions nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :exit (lambda () (interactive) (setq ran t))))
        (add-hook 'agent-before-exit-functions (lambda (_backend _buffer) t))
        (agent-exit)
        (should ran)))))

(ert-deftest agent-test-run-skill-before-exit-submits-codex-skill ()
  "Submit a Codex skill and abort the first exit globally by default."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        events)
    (with-temp-buffer
      (let* ((dir (file-name-as-directory default-directory))
             (buf (current-buffer))
             (agent-before-exit-skill-directories nil))
        (agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :directory (lambda (_buffer) dir)
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (should-not (agent-run-skill-before-exit 'codex buf))
        (should (equal (nreverse events)
                       '((command "$session-retro") return)))
        (should agent--before-exit-skill-sent)
        (should agent--before-exit-skill-exit-pending)
        (should (agent-run-skill-before-exit 'codex buf))))))

(ert-deftest agent-test-run-skill-before-exit-submits-in-matching-directory ()
  "Submit a Codex skill in explicitly configured directories."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (events nil))
    (with-temp-buffer
      (let* ((dir (file-name-as-directory default-directory))
             (buf (current-buffer))
             (agent-before-exit-skill-directories (list dir)))
        (agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :directory (lambda (_buffer) dir)
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (should-not (agent-run-skill-before-exit 'codex buf))
        (should (equal (nreverse events)
                       '((command "$session-retro") return)))))))

(ert-deftest agent-test-run-skill-before-exit-prefers-submit-command ()
  "Submit before-exit skills through a backend's atomic submit function."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        events)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :submit-command (lambda (cmd &optional _buffer)
                            (push (list 'submit cmd) events))
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (should-not (agent-run-skill-before-exit 'codex buf))
        (should (equal (nreverse events)
                       '((submit "$session-retro"))))))))

(ert-deftest agent-test-run-skill-before-exit-uses-claude-slash ()
  "Submit Claude skills with slash syntax."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (events nil))
    (with-temp-buffer
      (let* ((dir (file-name-as-directory default-directory))
             (buf (current-buffer))
             (agent-before-exit-skill-directories (list dir)))
        (agent-register-backend
         'claude-code
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :directory (lambda (_buffer) dir)
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (should-not (agent-run-skill-before-exit 'claude-code buf))
        (should (equal (nreverse events)
                       '((command "/session-retro") return)))))))

(ert-deftest agent-test-run-skill-before-exit-skips-other-directories ()
  "Do not submit before-exit skills outside configured directories."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories '("/tmp/not-this-repo/"))
        called)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :directory (lambda (_buffer) default-directory)
          :send-command (lambda (&rest _args) (setq called t))))
        (should (agent-run-skill-before-exit 'codex buf))
        (should-not called)))))

(ert-deftest agent-test-run-skill-before-exit-skips-short-sessions ()
  "Do not submit before-exit skills before the minimum duration."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        (agent-before-exit-skill-min-duration-seconds 60)
        called)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'codex
         (agent-test--backend
          :duration-ms (lambda (_buffer) 30000)
          :send-command (lambda (&rest _args) (setq called t))))
        (should (agent-run-skill-before-exit 'codex buf))
        (should-not called)
        (should-not agent--before-exit-skill-sent)
        (should-not agent--before-exit-skill-exit-pending)))))

(ert-deftest agent-test-run-skill-before-exit-honors-buffer-local-inhibit ()
  "Do not submit before-exit skills when the session inhibits them."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        called)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (setq-local agent-before-exit-skill-inhibit t)
        (agent-register-backend
         'codex
         (agent-test--backend
          :send-command (lambda (&rest _args) (setq called t))))
        (should (agent-run-skill-before-exit 'codex buf))
        (should-not called)
        (should-not agent--before-exit-skill-sent)
        (should-not agent--before-exit-skill-exit-pending)))))

(ert-deftest agent-test-run-skill-before-exit-allows-long-sessions ()
  "Submit before-exit skills after the minimum duration."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        (agent-before-exit-skill-min-duration-seconds 60)
        events)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'codex
         (agent-test--backend
          :duration-ms (lambda (_buffer) 60000)
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (should-not (agent-run-skill-before-exit 'codex buf))
        (should (equal (nreverse events)
                       '((command "$session-retro") return)))))))

(ert-deftest agent-test-run-skill-before-exit-matches-expanded-directory ()
  "Match sessions under configured directories that use `~'."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (events nil))
    (with-temp-buffer
      (let* ((dir (expand-file-name "~/tmp/agent-before-exit-test/"))
             (buf (current-buffer))
             (agent-before-exit-skill-directories '("~/tmp/")))
        (agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :directory (lambda (_buffer) dir)
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (should-not (agent-run-skill-before-exit 'codex buf))
        (should (equal (nreverse events)
                       '((command "$session-retro") return)))))))

(ert-deftest agent-test-run-skill-before-exit-skips-unknown-backends ()
  "Do not abort exit when BACKEND has no skill command prefix."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        called)
    (with-temp-buffer
      (let* ((dir (file-name-as-directory default-directory))
             (buf (current-buffer))
             (agent-before-exit-skill-directories (list dir)))
        (agent-register-backend
         'other
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :directory (lambda (_buffer) dir)
          :send-command (lambda (&rest _args) (setq called t))))
        (should (agent-run-skill-before-exit 'other buf))
        (should-not called)))))

(ert-deftest agent-test-exit-after-before-exit-skill-closes-pending-session ()
  "Exit a session when its before-exit skill has finished."
  (let ((agent-backends nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (setq-local agent--before-exit-skill-exit-pending t)
        (agent-register-backend
         'one
         (agent-test--backend
          :exit (lambda () (interactive) (setq ran t))))
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (_time _repeat function &rest args)
                     (apply function args))))
          (should (agent-exit-after-before-exit-skill 'one buf))
          (should ran)
          (should-not agent--before-exit-skill-exit-pending))))))

(ert-deftest agent-test-exit-after-before-exit-skill-ignores-ordinary-ready ()
  "Do not exit sessions without a pending before-exit skill."
  (let ((agent-backends nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :exit (lambda () (interactive) (setq ran t))))
        (should-not (agent-exit-after-before-exit-skill 'one buf))
        (should-not ran)))))

(ert-deftest agent-test-exit-after-before-exit-skill-honors-backend-veto ()
  "Do not close while a backend reports unaccepted prompt input."
  (let ((agent-backends nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (setq-local agent--before-exit-skill-exit-pending t)
        (agent-register-backend
         'one
         (agent-test--backend
          :before-exit-ready-to-close-p (lambda (_buffer) nil)
          :exit (lambda () (interactive) (setq ran t))))
        (should-not (agent-exit-after-before-exit-skill 'one buf))
        (should-not ran)
        (should agent--before-exit-skill-exit-pending)))))

(ert-deftest agent-test-discover-all-skills-skips-non-invocable ()
  "Do not expose skills marked `user-invocable: false'."
  (let ((agent-backends nil))
    (agent-register-backend
     'one
     (agent-test--backend
      :discover-skills (lambda ()
                         (list (list :name "visible")
                               (list :name "hidden"
                                     :user-invocable nil)))))
    (should (equal (mapcar (lambda (skill) (plist-get skill :name))
                           (agent--discover-all-skills))
                   '("visible")))))

;;;; Prompt capture

(ert-deftest agent-test-prompt-capture-file-is-session-specific ()
  "Build prompt capture paths from stable session identity."
  (let ((agent-backends nil)
        (agent-prompt-capture-directory temporary-file-directory))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/project/:default*" t)
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :directory (lambda (_buffer) "/tmp/project/")
          :account (lambda (_buffer) "work")
          :extract-instance-name (lambda (_buffer-name) "default")))
        (should
         (string-prefix-p
          (expand-file-name "one-" temporary-file-directory)
          (agent--prompt-capture-file 'one buf)))))))

(ert-deftest agent-test-read-captured-prompts-skips-empty-entries ()
  "Read nonempty Org prompt capture entries."
  (let ((file (make-temp-file "agent-prompts" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Empty\n")
            (insert ":PROPERTIES:\n:CREATED: [2026-05-17 Sun 10:00]\n:END:\n\n")
            (insert "* Use this\n")
            (insert ":PROPERTIES:\n:CREATED: [2026-05-17 Sun 10:01]\n:END:\n\n")
            (insert "First line\nSecond line\n"))
          (let ((prompts (agent--read-captured-prompts file)))
            (should (= (length prompts) 1))
            (should (equal (plist-get (car prompts) :title) "Use this"))
            (should (equal (plist-get (car prompts) :text)
                           "First line\nSecond line"))))
      (delete-file file))))

(ert-deftest agent-test-insert-captured-prompt-sends-selected-text ()
  "Insert the selected persisted prompt into the session."
  (let ((agent-backends nil)
        (agent-prompt-capture-directory
         (make-temp-file "agent-prompts" t))
        sent)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*one:~/repo/project/:default*" t)
          (let ((buf (current-buffer)))
            (agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (candidate) (eq candidate buf))
              :find-all-buffers (lambda () (list buf))
              :directory (lambda (_buffer) "/tmp/project/")
              :send-command (lambda (text target)
                              (setq sent (list text target)))))
            (let ((file (agent--prompt-capture-file 'one buf)))
              (make-directory (file-name-directory file) t)
              (with-temp-file file
                (insert "* Prompt A\n\nAlpha\n")
                (insert "* Prompt B\n\nBeta\n")))
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt candidates &rest _)
                         (cadr candidates))))
              (agent-insert-captured-prompt buf)
              (should (equal sent (list "Beta" buf)))))))
      (delete-directory agent-prompt-capture-directory t)))

;;;; Alerts

(ert-deftest agent-test-alert-sound-error-is-nonfatal ()
  "Report sound playback errors without signaling."
  (let ((sound-file (make-temp-file "agent-test-sound" nil ".aiff"))
        messages)
    (unwind-protect
        (let ((agent-alert-style 'sound)
              (agent-alert-sound sound-file))
          (cl-letf (((symbol-function 'play-sound-file)
                     (lambda (_file) (error "no sound support")))
                    ((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (push (apply #'format format-string args) messages))))
            (should (condition-case nil
                        (progn
                          (agent--alert-sound)
                          t)
                      (error nil)))
            (should (member "AI alert sound failed: no sound support" messages))))
      (delete-file sound-file))))

(ert-deftest agent-test-parse-skill-frontmatter-argument-metadata ()
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
          (let ((meta (agent-parse-skill-frontmatter file)))
            (should (equal (plist-get meta :name) "convert"))
            (should (equal (plist-get meta :argument-choices) '("a" "b")))
            (should (equal (plist-get meta :argument-default) "a"))
            (should-not (plist-get meta :argument-multiple))
            (should-not (plist-get meta :user-invocable))
            (should (equal (plist-get meta :model) "gpt-5.5"))))
      (delete-file file))))

(provide 'agent-test)
;;; agent-test.el ends here
