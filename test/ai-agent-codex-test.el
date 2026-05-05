;;; ai-agent-codex-test.el --- Tests for ai-agent-codex -*- lexical-binding: t -*-

;; Tests for pure and near-pure helper functions in ai-agent-codex.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ai-agent-codex)

;;;; Theme sync

(ert-deftest ai-agent-codex-test-sync-theme-updates-existing-tui-section ()
  "Persist theme changes to an existing Codex `[tui]' section."
  (let* ((dir (make-temp-file "codex-theme" t))
         (config (expand-file-name "config.toml" dir))
         (codex-hooks-config-path config))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "model = \"gpt-5.5\"\n\n[tui]\ntheme = \"light\"\n"))
          (should (ai-agent-codex--sync-theme "dark"))
          (should (string-match-p
                   "^\\[tui\\]\ntheme = \"dark\""
                   (with-temp-buffer
                     (insert-file-contents config)
                     (buffer-string)))))
      (delete-directory dir t))))

(ert-deftest ai-agent-codex-test-sync-theme-adds-tui-section ()
  "Create a Codex `[tui]' section when the config has none."
  (let* ((dir (make-temp-file "codex-theme" t))
         (config (expand-file-name "config.toml" dir))
         (codex-hooks-config-path config))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "model = \"gpt-5.5\"\n"))
          (should (ai-agent-codex--sync-theme "light"))
          (should (string-match-p
                   "\\[tui\\]\ntheme = \"light\""
                   (with-temp-buffer
                     (insert-file-contents config)
                     (buffer-string)))))
      (delete-directory dir t))))

(ert-deftest ai-agent-codex-test-sync-theme-skips-unchanged-config ()
  "Avoid rewriting Codex config when the theme already matches."
  (let* ((dir (make-temp-file "codex-theme" t))
         (config (expand-file-name "config.toml" dir))
         (codex-hooks-config-path config))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "[tui]\ntheme = \"dark\"\n"))
          (should-not (ai-agent-codex--sync-theme "dark")))
      (delete-directory dir t))))

(ert-deftest ai-agent-codex-test-sync-theme-to-config-allows-legacy-call ()
  "Accept the old no-argument theme config writer call."
  (let* ((dir (make-temp-file "codex-theme" t))
         (config (expand-file-name "config.toml" dir))
         (codex-hooks-config-path config))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "[tui]\ntheme = \"light\"\n"))
          (cl-letf (((symbol-function 'frame-parameter)
                     (lambda (_frame param)
                       (when (eq param 'background-mode) 'dark))))
            (should (ai-agent-codex--sync-theme-to-config)))
          (should (string-match-p
                   "^\\[tui\\]\ntheme = \"dark\""
                   (with-temp-buffer
                     (insert-file-contents config)
                     (buffer-string)))))
      (delete-directory dir t))))

;;;; Skill runner

(ert-deftest ai-agent-codex-test-parse-skill-frontmatter-argument-metadata ()
  "Parse Codex skill argument metadata with the shared parser."
  (let ((file (make-temp-file "codex-skill" nil ".md")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "---\n")
            (insert "name: proofread\n")
            (insert "description: Proofread a file\n")
            (insert "argument-hint: FILE\n")
            (insert "argument-source: references/*.org\n")
            (insert "---\n"))
          (let ((meta (ai-agent-codex--parse-skill-frontmatter file)))
            (should (equal (plist-get meta :name) "proofread"))
            (should (equal (plist-get meta :argument-hint) "FILE"))
            (should (equal (plist-get meta :argument-source)
                           "references/*.org"))))
      (delete-file file))))

(ert-deftest ai-agent-codex-test-discover-skills-skips-non-invocable ()
  "Do not expose Codex skills marked `user-invocable: false'."
  (let* ((dir (make-temp-file "codex-skills" t))
         (visible (expand-file-name "visible/SKILL.md" dir))
         (hidden (expand-file-name "hidden/SKILL.md" dir))
         (ai-agent-codex-skill-directories (list dir)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory visible) t)
          (make-directory (file-name-directory hidden) t)
          (with-temp-file visible
            (insert "---\nname: visible\n---\n"))
          (with-temp-file hidden
            (insert "---\nname: hidden\nuser-invocable: false\n---\n"))
          (should (equal (mapcar (lambda (skill) (plist-get skill :name))
                                 (ai-agent-codex--discover-skills))
                         '("visible"))))
      (delete-directory dir t))))

(ert-deftest ai-agent-codex-test-build-exec-command ()
  "Build a current `codex exec' command line."
  (let ((codex-program "codex")
        (codex-program-switches '("--search"))
        (codex-model "gpt-5.5")
        (codex-profile "work")
        (codex-sandbox-mode 'workspace-write)
        (codex-approval-policy 'on-request)
        (codex-default-images '("image.png"))
        (ai-agent-codex-exec-approval-policy 'never)
        (ai-agent-codex-exec-sandbox-mode nil)
        (ai-agent-codex-exec-skip-git-repo-check t))
    (should (equal
             (ai-agent-codex--build-exec-command "prompt" "/tmp/project")
             '("codex" "--search" "exec" "--model" "gpt-5.5"
               "--profile" "work" "--sandbox" "workspace-write"
               "--ask-for-approval" "never" "--image" "image.png"
               "--cd" "/tmp/project" "--color" "never"
               "--skip-git-repo-check" "prompt")))))

(ert-deftest ai-agent-codex-test-run-skill-uses-codex-exec ()
  "Run discovered skills through the non-interactive Codex path."
  (let* ((dir (make-temp-file "codex-skills" t))
         (skill-file (expand-file-name "proofread/SKILL.md" dir))
         (ai-agent-codex-skill-directories (list dir))
         captured-prompt
         captured-dir)
    (unwind-protect
        (progn
          (make-directory (file-name-directory skill-file) t)
          (with-temp-file skill-file
            (insert "---\nname: proofread\n---\nProofread the file.\n"))
          (cl-letf (((symbol-function 'ai-agent-codex--run-prompt)
                     (lambda (prompt &rest kwargs)
                       (setq captured-prompt prompt
                             captured-dir (plist-get kwargs :dir))
                       (funcall (plist-get kwargs :callback)
                                '(:exit-code 0 :duration 0.1 :text "ok"))))
                    ((symbol-function 'ai-agent-codex--display-result)
                     #'ignore))
            (ai-agent-codex-run-skill "proofread" "file.org"))
          (should (string-match-p (regexp-quote skill-file) captured-prompt))
          (should (string-match-p "Arguments: file.org" captured-prompt))
          (should (equal captured-dir default-directory)))
      (delete-directory dir t))))

(provide 'ai-agent-codex-test)
;;; ai-agent-codex-test.el ends here
