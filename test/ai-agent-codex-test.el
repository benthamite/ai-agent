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

(ert-deftest ai-agent-codex-test-run-skill-prefers-current-codex-buffer ()
  "Send skills to the current Codex buffer when already in one."
  (let (sent-buffer sent-command displayed)
    (with-temp-buffer
      (let ((target (current-buffer)))
        (cl-letf (((symbol-function 'codex--buffer-p)
                   (lambda (buffer) (eq buffer target)))
                  ((symbol-function 'codex--get-or-prompt-for-buffer)
                   (lambda () (error "should not prompt")))
                  ((symbol-function 'codex--do-send-command)
                   (lambda (command)
                     (setq sent-buffer (current-buffer)
                           sent-command command)))
                  ((symbol-function 'display-buffer)
                   (lambda (buffer &rest _args) (setq displayed buffer))))
          (ai-agent-codex-run-skill "proofread" "file.org")
          (should (eq sent-buffer target))
          (should (eq displayed target))
          (should (equal sent-command "/proofread file.org")))))))

(provide 'ai-agent-codex-test)
;;; ai-agent-codex-test.el ends here
