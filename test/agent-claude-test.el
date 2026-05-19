;;; agent-claude-test.el --- Tests for agent-claude -*- lexical-binding: t -*-

;; Tests for pure and near-pure helper functions in agent-claude.el.

;;; Code:

(require 'ert)
(require 'json)
(require 'agent-claude)

;;;; Prompt submission

(ert-deftest agent-claude-test-submit-command-targets-explicit-buffer ()
  "Submit commands to the explicit Claude buffer without prompting."
  (let (events)
    (with-temp-buffer
      (let ((buf (current-buffer))
            (claude-code-terminal-backend 'eat))
        (cl-letf (((symbol-function 'claude-code--buffer-p)
                   (lambda (candidate) (eq candidate buf)))
                  ((symbol-function 'claude-code--get-or-prompt-for-buffer)
                   (lambda () (error "Should not prompt for a buffer")))
                  ((symbol-function 'claude-code--term-send-string)
                   (lambda (_backend string)
                     (push (list (current-buffer) string) events)))
                  ((symbol-function 'display-buffer) #'ignore)
                  ((symbol-function 'sit-for) #'ignore))
          (should (eq (agent-claude-submit-command "/session-retro" buf)
                      buf))
          (should (equal (nreverse events)
                         (list (list buf "/session-retro")
                               (list buf (kbd "RET"))))))))))

;;;; Slack message action routing

(ert-deftest agent-claude-test-act-on-slack-message-inserts-url-for-review ()
  "Start Claude Code without an initial prompt and insert the Slack URL."
  (let ((project '(:id "project" :directory "/tmp/project"))
        (url "https://example.slack.com/archives/C1/p123")
        (buffer (generate-new-buffer " *claude-test*"))
        started
        sent)
    (unwind-protect
        (cl-letf (((symbol-function 'claude-code--start)
                   (lambda (arg extra-switches force-prompt force-switch-to-buffer)
                     (setq started
                           (list arg extra-switches force-prompt
                                 force-switch-to-buffer
                                 (claude-code--directory)))
                     buffer))
                  ((symbol-function 'agent-claude-send-command)
                   (lambda (cmd target)
                     (setq sent (list cmd target))
                     target)))
          (should (eq (agent-claude--act-on-slack-message-start-session
                       project url)
                      buffer))
          (should (equal started
                         (list nil nil nil t "/tmp/project")))
          (should (equal sent (list url buffer))))
      (kill-buffer buffer))))

;;;; Session name extraction

(ert-deftest agent-claude-test-session-name-standard ()
  "Extract project name from a standard Claude buffer name."
  (should (equal (agent-claude--session-name
                  "*claude:~/path/to/project/:default*")
                 "project")))

(ert-deftest agent-claude-test-session-name-named-instance ()
  "Extract project name regardless of instance name."
  (should (equal (agent-claude--session-name
                  "*claude:~/repos/my-app/:worktree-1*")
                 "my-app")))

(ert-deftest agent-claude-test-session-name-deep-path ()
  "Extract project name from a deeply nested path."
  (should (equal (agent-claude--session-name
                  "*claude:~/My Drive/repos/org/subdir/:main*")
                 "subdir")))

(ert-deftest agent-claude-test-session-name-non-matching ()
  "Return buffer name unchanged when it does not match the pattern."
  (should (equal (agent-claude--session-name "*scratch*")
                 "*scratch*")))

(ert-deftest agent-claude-test-session-name-no-trailing-star ()
  "Return buffer name unchanged when trailing asterisk is missing."
  (should (equal (agent-claude--session-name
                  "*claude:~/path/to/project/:default")
                 "*claude:~/path/to/project/:default")))

;;;; Sanitize buffer name

(ert-deftest agent-claude-test-sanitize-buffer-name-replaces-special ()
  "Non-alphanumeric characters (except _ and -) are replaced with underscores."
  (with-temp-buffer
    (rename-buffer "*claude:~/foo/bar/:default*" t)
    (should (equal (agent-claude--sanitize-buffer-name)
                   "_claude___foo_bar__default_"))))

(ert-deftest agent-claude-test-sanitize-buffer-name-preserves-safe ()
  "Alphanumeric characters, underscores, and hyphens are preserved."
  (with-temp-buffer
    (rename-buffer "hello_world-123" t)
    (should (equal (agent-claude--sanitize-buffer-name)
                   "hello_world-123"))))

(ert-deftest agent-claude-test-sanitize-buffer-name-spaces ()
  "Spaces are replaced with underscores."
  (with-temp-buffer
    (rename-buffer "my buffer name" t)
    (should (equal (agent-claude--sanitize-buffer-name)
                   "my_buffer_name"))))

(ert-deftest agent-claude-test-status-file-name-avoids-sanitizer-collisions ()
  "Distinct buffer names get distinct status filenames."
  (should-not
   (equal (agent-claude--status-file-name "*claude:~/foo/bar/:default*")
          (agent-claude--status-file-name "*claude:~/foo_bar/:default*"))))

;;;; Theme sync

(defun agent-claude-test--json-theme (file)
  "Return the `theme' value from JSON FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (gethash "theme" (json-parse-buffer))))

(ert-deftest agent-claude-test-sync-theme-writes-config-files ()
  "Persist theme changes to Claude Code JSON config files."
  (let* ((dir (make-temp-file "claude-theme" t))
         (settings (expand-file-name ".claude/settings.json" dir))
         (legacy (expand-file-name ".claude.json" dir))
         (account (expand-file-name "account/.claude.json" dir)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory settings) t)
          (make-directory (file-name-directory account) t)
          (with-temp-file settings
            (insert "{\"theme\":\"light\",\"other\":1}"))
          (with-temp-file legacy
            (insert "{\"theme\":\"light\",\"other\":1}"))
          (with-temp-file account
            (insert "{\"theme\":\"light\"}"))
          (cl-letf (((symbol-function 'agent-claude--theme-config-files)
                     (lambda () (list settings legacy account))))
            (should (= (agent-claude--sync-theme "dark") 3))
            (should (equal (agent-claude-test--json-theme settings)
                           "dark"))
            (should (equal (agent-claude-test--json-theme legacy)
                           "dark"))
            (should (equal (agent-claude-test--json-theme account)
                           "dark"))))
      (delete-directory dir t))))

(ert-deftest agent-claude-test-theme-config-files-prefers-settings ()
  "Sync modern settings files before legacy `.claude.json' files."
  (let* ((dir (make-temp-file "claude-theme" t))
         (settings (expand-file-name "settings.json" dir))
         (missing-settings (expand-file-name "missing/settings.json" dir))
         (legacy (expand-file-name ".claude.json" dir))
         (missing-legacy (expand-file-name "missing/.claude.json" dir)))
    (unwind-protect
        (progn
          (with-temp-file settings (insert "{}"))
          (with-temp-file legacy (insert "{}"))
          (cl-letf (((symbol-function 'agent-claude--all-claude-settings-paths)
                     (lambda () (list settings missing-settings)))
                    ((symbol-function 'agent-claude--all-claude-json-paths)
                     (lambda () (list legacy missing-legacy))))
            (should (equal (agent-claude--theme-config-files)
                           (list settings legacy)))))
      (delete-directory dir t))))

(ert-deftest agent-claude-test-sync-theme-skips-unchanged-config ()
  "Avoid rewriting Claude Code JSON files when the theme already matches."
  (let* ((dir (make-temp-file "claude-theme" t))
         (canonical (expand-file-name ".claude.json" dir)))
    (unwind-protect
        (progn
          (with-temp-file canonical
            (insert "{\"theme\":\"dark\"}"))
          (cl-letf (((symbol-function 'agent-claude--theme-config-files)
                     (lambda () (list canonical))))
            (should (= (agent-claude--sync-theme "dark") 0))))
      (delete-directory dir t))))

(ert-deftest agent-claude-test-sync-theme-errors-on-invalid-json ()
  "Do not overwrite an existing invalid Claude Code JSON file."
  (let* ((dir (make-temp-file "claude-theme" t))
         (canonical (expand-file-name ".claude.json" dir)))
    (unwind-protect
        (progn
          (with-temp-file canonical
            (insert "{"))
          (cl-letf (((symbol-function 'agent-claude--theme-config-files)
                     (lambda () (list canonical))))
            (should-error (agent-claude--sync-theme "dark")))
          (should (equal (with-temp-buffer
                           (insert-file-contents canonical)
                           (buffer-string))
                         "{")))
      (delete-directory dir t))))

;;;; Batch format prompt

(ert-deftest agent-claude-test-batch-format-prompt-title-only ()
  "Return title alone when body is empty."
  (should (equal (agent-claude--batch-format-prompt
                  '(:title "Fix the bug" :body ""))
                 "Fix the bug")))

(ert-deftest agent-claude-test-batch-format-prompt-title-and-body ()
  "Return title and body separated by blank line."
  (should (equal (agent-claude--batch-format-prompt
                  '(:title "Fix the bug" :body "See error in log"))
                 "Fix the bug\n\nSee error in log")))

(ert-deftest agent-claude-test-batch-format-prompt-nil-body ()
  "Return title alone when body is nil."
  (should (equal (agent-claude--batch-format-prompt
                  '(:title "Refactor module" :body nil))
                 "Refactor module")))

;;;; Status accessors

(ert-deftest agent-claude-test-status-model-present ()
  "Return display_name when model data is present."
  (let ((agent-claude--status-data
         '(:model (:display_name "Claude Opus 4"))))
    (should (equal (agent-claude-status-model) "Claude Opus 4"))))

(ert-deftest agent-claude-test-status-model-nil ()
  "Return nil when status data has no model."
  (let ((agent-claude--status-data nil))
    (should-not (agent-claude-status-model))))

(ert-deftest agent-claude-test-status-cost-present ()
  "Return total_cost_usd when cost data is present."
  (let ((agent-claude--status-data
         '(:cost (:total_cost_usd 0.42))))
    (should (= (agent-claude-status-cost) 0.42))))

(ert-deftest agent-claude-test-status-cost-nil ()
  "Return nil when status data has no cost."
  (let ((agent-claude--status-data nil))
    (should-not (agent-claude-status-cost))))

(ert-deftest agent-claude-test-status-context-percent ()
  "Return used_percentage from context_window data."
  (let ((agent-claude--status-data
         '(:context_window (:used_percentage 73.5))))
    (should (= (agent-claude-status-context-percent) 73.5))))

(ert-deftest agent-claude-test-status-context-percent-nil ()
  "Return nil when no context_window data."
  (let ((agent-claude--status-data nil))
    (should-not (agent-claude-status-context-percent))))

(ert-deftest agent-claude-test-status-token-count ()
  "Return total_input_tokens from context_window data."
  (let ((agent-claude--status-data
         '(:context_window (:total_input_tokens 50000))))
    (should (= (agent-claude-status-token-count) 50000))))

(ert-deftest agent-claude-test-status-token-count-nil ()
  "Return nil when no context_window data."
  (let ((agent-claude--status-data nil))
    (should-not (agent-claude-status-token-count))))

(ert-deftest agent-claude-test-status-lines-added ()
  "Return total_lines_added from cost data."
  (let ((agent-claude--status-data
         '(:cost (:total_lines_added 120))))
    (should (= (agent-claude-status-lines-added) 120))))

(ert-deftest agent-claude-test-status-lines-removed ()
  "Return total_lines_removed from cost data."
  (let ((agent-claude--status-data
         '(:cost (:total_lines_removed 30))))
    (should (= (agent-claude-status-lines-removed) 30))))

(ert-deftest agent-claude-test-status-duration-ms ()
  "Return total_duration_ms from cost data."
  (let ((agent-claude--status-data
         '(:cost (:total_duration_ms 12500))))
    (should (= (agent-claude-status-duration-ms) 12500))))

(ert-deftest agent-claude-test-status-cache-read-tokens ()
  "Return cache_read_input_tokens from current_usage."
  (let ((agent-claude--status-data
         '(:context_window (:current_usage (:cache_read_input_tokens 8000)))))
    (should (= (agent-claude-status-cache-read-tokens) 8000))))

(ert-deftest agent-claude-test-status-cache-read-tokens-nil ()
  "Return nil when current_usage is missing."
  (let ((agent-claude--status-data
         '(:context_window (:used_percentage 50))))
    (should-not (agent-claude-status-cache-read-tokens))))

(ert-deftest agent-claude-test-status-cache-total-tokens-all-fields ()
  "Sum input_tokens, cache_creation_input_tokens, and cache_read_input_tokens."
  (let ((agent-claude--status-data
         '(:context_window
           (:current_usage (:input_tokens 100
                            :cache_creation_input_tokens 200
                            :cache_read_input_tokens 300)))))
    (should (= (agent-claude-status-cache-total-tokens) 600))))

(ert-deftest agent-claude-test-status-cache-total-tokens-partial ()
  "Missing sub-fields default to zero in the sum."
  (let ((agent-claude--status-data
         '(:context_window
           (:current_usage (:cache_read_input_tokens 500)))))
    (should (= (agent-claude-status-cache-total-tokens) 500))))

(ert-deftest agent-claude-test-status-cache-total-tokens-nil ()
  "Return nil when current_usage is absent."
  (let ((agent-claude--status-data
         '(:context_window (:used_percentage 50))))
    (should-not (agent-claude-status-cache-total-tokens))))

;;;; Alert indicator

(ert-deftest agent-claude-test-alert-indicator-active ()
  "Return bell-on icon when alert is enabled."
  (let ((agent-alert-on-ready t))
    (should (equal (agent-claude-alert-indicator) "🔔"))))

(ert-deftest agent-claude-test-alert-indicator-inactive ()
  "Return bell-off icon when alert is disabled."
  (let ((agent-alert-on-ready nil))
    (should (equal (agent-claude-alert-indicator) "🔕"))))

(ert-deftest agent-claude-test-alert-indicator-uses-shared-state ()
  "Reflect the shared `agent-alert-on-ready' state."
  (let ((agent-alert-on-ready t))
    (should (equal (agent-claude-alert-indicator) "🔔"))))

;;;; Transient menu

(ert-deftest agent-claude-test-agent-log-wrapper-is-command ()
  "Expose log browsing as a command without requiring `agent-log'."
  (should (commandp 'agent-claude-agent-log-menu)))

;;;; Display names

(ert-deftest agent-claude-test-display-name-adds-branch-suffix ()
  "Append Claude branch suffixes via the shared display-name hook."
  (with-temp-buffer
    (rename-buffer "*claude:~/repo/unique-claude-display-test/:default*" t)
    (let ((agent-claude--original-session-id "original-session")
          (agent-claude--status-data
           '(:session_id "branched-session-id")))
      (should (equal (agent-claude-display-name (current-buffer))
                     "unique-claude-display-test:branched")))))

;;;; Batch parse stream JSON

(ert-deftest agent-claude-test-batch-parse-stream-json-assistant-text ()
  "Extract assistant text from stream-json output."
  (let* ((line1 (json-encode '(:type "assistant"
                                :message (:content [(:type "text" :text "Hello world")]))))
         (line2 (json-encode '(:type "result"
                                :total_cost_usd 0.05
                                :session_id "sess-123"
                                :num_turns 1
                                :subtype "success")))
         (raw (concat line1 "\n" line2))
         (result (agent-claude--batch-parse-stream-json raw)))
    (should (equal (plist-get result :text) "Hello world"))
    (should (= (plist-get result :cost) 0.05))
    (should (equal (plist-get result :session-id) "sess-123"))))

(ert-deftest agent-claude-test-batch-parse-stream-json-multiple-blocks ()
  "Multiple assistant text blocks are joined with double newlines."
  (let* ((line1 (json-encode '(:type "assistant"
                                :message (:content [(:type "text" :text "Part one")]))))
         (line2 (json-encode '(:type "assistant"
                                :message (:content [(:type "text" :text "Part two")]))))
         (line3 (json-encode '(:type "result" :total_cost_usd 0.1
                                :session_id "s1" :num_turns 2 :subtype "success")))
         (raw (concat line1 "\n" line2 "\n" line3))
         (result (agent-claude--batch-parse-stream-json raw)))
    (should (equal (plist-get result :text) "Part one\n\nPart two"))))

(ert-deftest agent-claude-test-batch-parse-stream-json-no-text ()
  "Produce fallback message when no assistant text is captured."
  (let* ((line (json-encode '(:type "result" :total_cost_usd 0.0
                               :session_id "s99" :num_turns 0 :subtype "timeout")))
         (raw line)
         (result (agent-claude--batch-parse-stream-json raw)))
    (should (string-match-p "No assistant text captured" (plist-get result :text)))
    (should (string-match-p "s99" (plist-get result :text)))))

(ert-deftest agent-claude-test-batch-parse-stream-json-cost-usd-fallback ()
  "Use cost_usd when total_cost_usd is absent."
  (let* ((line (json-encode '(:type "result" :cost_usd 0.03
                               :session_id "s1" :num_turns 1 :subtype "ok")))
         (result (agent-claude--batch-parse-stream-json line)))
    (should (= (plist-get result :cost) 0.03))))

(ert-deftest agent-claude-test-batch-parse-stream-json-malformed-lines ()
  "Malformed JSON lines are silently skipped."
  (let* ((good (json-encode '(:type "result" :total_cost_usd 0.01
                               :session_id "s1" :num_turns 1 :subtype "ok")))
         (raw (concat "not valid json\n" good))
         (result (agent-claude--batch-parse-stream-json raw)))
    (should (= (plist-get result :cost) 0.01))))

(ert-deftest agent-claude-test-batch-parse-stream-json-empty-input ()
  "Empty input returns zero cost and fallback text."
  (let ((result (agent-claude--batch-parse-stream-json "")))
    (should (= (plist-get result :cost) 0))
    (should (string-match-p "No assistant text captured" (plist-get result :text)))))

(ert-deftest agent-claude-test-skill-result-does-not-modify-new-user-buffer ()
  "Display skill output in a result buffer, not an unrelated new buffer."
  (let ((existing (get-buffer-create "*agent-existing*"))
        (unrelated (get-buffer-create "*agent-unrelated*"))
        (result-buffer "*Claude Skill: proofread*"))
    (unwind-protect
        (progn
          (with-current-buffer unrelated
            (erase-buffer)
            (insert "#+title: User buffer\nBody\n"))
          (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
            (agent-claude--skill-display-result
             "proofread"
             '(:cost 0.0 :duration 0.1 :text "ok")
             (list existing)))
          (with-current-buffer unrelated
            (should (equal (buffer-string) "#+title: User buffer\nBody\n")))
          (should (get-buffer result-buffer)))
      (when (buffer-live-p unrelated)
        (kill-buffer unrelated))
      (when (buffer-live-p existing)
        (kill-buffer existing))
      (when-let* ((buf (get-buffer result-buffer)))
        (kill-buffer buf)))))

;;;; Batch build args

(ert-deftest agent-claude-test-batch-build-args-minimal ()
  "Build args with only required settings (no optional overrides)."
  (let ((claude-code-program "claude")
        (agent-claude-batch-max-turns 10)
        (agent-claude-batch-permission-mode nil)
        (agent-claude-batch-allowed-tools nil)
        (agent-claude-batch-system-prompt nil)
        (agent-claude-batch-model nil))
    (should (equal (agent-claude--build-cli-args "do stuff")
                   '("claude" "-p" "do stuff"
                     "--output-format" "stream-json"
                     "--verbose"
                     "--max-turns" "10")))))

(ert-deftest agent-claude-test-batch-build-args-with-tools ()
  "Include --allowedTools when batch-allowed-tools is set."
  (let ((claude-code-program "claude")
        (agent-claude-batch-max-turns 5)
        (agent-claude-batch-permission-mode nil)
        (agent-claude-batch-allowed-tools '("Read" "Write"))
        (agent-claude-batch-system-prompt nil)
        (agent-claude-batch-model nil))
    (let ((args (agent-claude--build-cli-args "test")))
      (should (member "--allowedTools" args))
      (should (member "Read,Write" args)))))

(ert-deftest agent-claude-test-batch-build-args-with-system-prompt ()
  "Include --append-system-prompt when batch-system-prompt is set."
  (let ((claude-code-program "claude")
        (agent-claude-batch-max-turns 5)
        (agent-claude-batch-permission-mode nil)
        (agent-claude-batch-allowed-tools nil)
        (agent-claude-batch-system-prompt "Be concise")
        (agent-claude-batch-model nil))
    (let ((args (agent-claude--build-cli-args "test")))
      (should (member "--append-system-prompt" args))
      (should (member "Be concise" args)))))

(ert-deftest agent-claude-test-batch-build-args-with-model ()
  "Include --model when batch-model is set."
  (let ((claude-code-program "claude")
        (agent-claude-batch-max-turns 5)
        (agent-claude-batch-permission-mode nil)
        (agent-claude-batch-allowed-tools nil)
        (agent-claude-batch-system-prompt nil)
        (agent-claude-batch-model "opus"))
    (let ((args (agent-claude--build-cli-args "test")))
      (should (member "--model" args))
      (should (member "opus" args)))))

(ert-deftest agent-claude-test-batch-build-args-all-options ()
  "All optional flags appear when all batch variables are set."
  (let ((claude-code-program "/usr/bin/claude")
        (agent-claude-batch-max-turns 20)
        (agent-claude-batch-permission-mode "bypassPermissions")
        (agent-claude-batch-allowed-tools '("Bash" "Read"))
        (agent-claude-batch-system-prompt "Be thorough")
        (agent-claude-batch-model "sonnet"))
    (let ((args (agent-claude--build-cli-args "hello")))
      (should (equal (car args) "/usr/bin/claude"))
      (should (member "--permission-mode" args))
      (should (member "bypassPermissions" args))
      (should (member "--allowedTools" args))
      (should (member "Bash,Read" args))
      (should (member "--append-system-prompt" args))
      (should (member "Be thorough" args))
      (should (member "--model" args))
      (should (member "sonnet" args))
      (should (member "--max-turns" args))
      (should (member "20" args)))))

(ert-deftest agent-claude-test-batch-env-preserves-api-key-without-account ()
  "Preserve `ANTHROPIC_API_KEY' when no account config is active."
  (let ((process-environment '("ANTHROPIC_API_KEY=key" "CLAUDE_CODE=1"))
        (agent-claude-accounts nil)
        (agent-claude--current-account nil))
    (should (member "ANTHROPIC_API_KEY=key"
                    (agent-claude--batch-process-environment)))))

(ert-deftest agent-claude-test-batch-env-strips-api-key-with-account ()
  "Strip conflicting auth when `CLAUDE_CONFIG_DIR' is set."
  (let ((process-environment '("ANTHROPIC_API_KEY=key" "CLAUDE_CODE=1"))
        (agent-claude-accounts '(("work" . "/tmp/claude-work")))
        (agent-claude--current-account "work"))
    (let ((env (agent-claude--batch-process-environment)))
      (should (member "CLAUDE_CONFIG_DIR=/tmp/claude-work" env))
      (should-not (member "ANTHROPIC_API_KEY=key" env))
      (should-not (member "CLAUDE_CODE=1" env)))))

(ert-deftest agent-claude-test-diff-file-in-session-uses-directory-boundary ()
  "Do not treat sibling paths with the same prefix as inside a session."
  (let* ((session-dir (make-temp-file "agent-proj" t))
         (sibling-dir (concat (directory-file-name session-dir) "-other")))
    (unwind-protect
        (progn
          (make-directory sibling-dir)
          (with-temp-buffer
            (setq default-directory (file-name-as-directory sibling-dir))
            (cl-letf (((symbol-function 'monet--session-directory)
                       (lambda (_session) session-dir)))
              (should-not
               (agent-claude--diff-file-in-session-p
                (current-buffer) 'session)))))
      (delete-directory session-dir t)
      (delete-directory sibling-dir t))))

;;;; Has statusline key

(ert-deftest agent-claude-test-has-statusline-key-present ()
  "Return non-nil when buffer contains a statusLine JSON key."
  (with-temp-buffer
    (insert "{\n  \"statusLine\": {}\n}")
    (should (agent-claude--has-statusline-key-p))))

(ert-deftest agent-claude-test-has-statusline-key-absent ()
  "Return nil when buffer lacks a statusLine JSON key."
  (with-temp-buffer
    (insert "{\n  \"someOtherKey\": true\n}")
    (should-not (agent-claude--has-statusline-key-p))))

(ert-deftest agent-claude-test-has-statusline-key-empty ()
  "Return nil in an empty buffer."
  (with-temp-buffer
    (should-not (agent-claude--has-statusline-key-p))))

;;;; Has stop hook

(ert-deftest agent-claude-test-has-stop-hook-present ()
  "Return non-nil when buffer contains a Stop JSON key."
  (with-temp-buffer
    (insert "{\n  \"hooks\": {\n    \"Stop\": []\n  }\n}")
    (should (agent-claude--has-stop-hook-p))))

(ert-deftest agent-claude-test-has-stop-hook-absent ()
  "Return nil when buffer lacks a Stop JSON key."
  (with-temp-buffer
    (insert "{\n  \"hooks\": {}\n}")
    (should-not (agent-claude--has-stop-hook-p))))

(ert-deftest agent-claude-test-has-stop-hook-empty ()
  "Return nil in an empty buffer."
  (with-temp-buffer
    (should-not (agent-claude--has-stop-hook-p))))

;;;; Settings setup

(defun agent-claude-test--executable ()
  "Return a temporary executable file path."
  (let ((file (make-temp-file "agent-exec")))
    (set-file-modes file #o755)
    file))

(ert-deftest agent-claude-test-ensure-statusline-config-valid-empty-json ()
  "Write a valid statusLine object into an empty settings object."
  (let ((settings (make-temp-file "statusline-test" nil ".json"))
        (script (agent-claude-test--executable)))
    (unwind-protect
        (let ((agent-claude-statusline-script script))
          (with-temp-file settings (insert "{}"))
          (should (agent-claude-ensure-statusline-config settings))
          (let* ((data (agent-claude--read-json-object settings))
                 (statusline (gethash "statusLine" data)))
            (should (hash-table-p statusline))
            (should (string-match-p (regexp-quote script)
                                    (gethash "command" statusline)))
            (should (string-match-p "AGENT_CLAUDE_STATUS_DIR="
                                    (gethash "command" statusline)))
            (should (= (gethash "padding" statusline) 0))))
      (delete-file settings)
      (delete-file script))))

(ert-deftest agent-claude-test-ensure-statusline-config-replaces-stale-agent-command ()
  "Replace stale agent-owned statusLine commands."
  (let ((settings (make-temp-file "statusline-test" nil ".json"))
        (script (agent-claude-test--executable)))
    (unwind-protect
        (let ((agent-claude-statusline-script script))
          (with-temp-file settings
            (insert "{"
                    "\"statusLine\":{"
                    "\"type\":\"command\","
                    "\"command\":\"~/My\\\\ Drive/dotfiles/emacs/extras/etc/claude-code-statusline.sh\","
                    "\"padding\":0"
                    "}}"))
          (should (agent-claude-ensure-statusline-config settings))
          (let* ((data (agent-claude--read-json-object settings))
                 (statusline (gethash "statusLine" data))
                 (command (gethash "command" statusline)))
            (should (string-match-p (regexp-quote script) command))
            (should (string-match-p "AGENT_CLAUDE_STATUS_DIR=" command))))
      (delete-file settings)
      (delete-file script))))

(ert-deftest agent-claude-test-ensure-statusline-config-preserves-custom-command ()
  "Do not replace unrelated user statusLine commands."
  (let ((settings (make-temp-file "statusline-test" nil ".json"))
        (script (agent-claude-test--executable)))
    (unwind-protect
        (let ((agent-claude-statusline-script script))
          (with-temp-file settings
            (insert "{"
                    "\"statusLine\":{"
                    "\"type\":\"command\","
                    "\"command\":\"/usr/bin/custom-statusline\","
                    "\"padding\":0"
                    "}}"))
          (should-not (agent-claude-ensure-statusline-config settings))
          (let* ((data (agent-claude--read-json-object settings))
                 (statusline (gethash "statusLine" data)))
            (should (equal (gethash "command" statusline)
                           "/usr/bin/custom-statusline"))))
      (delete-file settings)
      (delete-file script))))

(ert-deftest agent-claude-test-ensure-hooks-config-valid-empty-json ()
  "Write Stop and Notification hooks into an empty settings object."
  (let ((settings (make-temp-file "hooks-test" nil ".json"))
        (wrapper (agent-claude-test--executable)))
    (unwind-protect
        (let ((agent-claude-hook-wrapper wrapper))
          (with-temp-file settings (insert "{}"))
          (should (agent-claude-ensure-stop-hook-config settings))
          (should (agent-claude-ensure-notification-hook-config settings))
          (let* ((data (agent-claude--read-json-object settings))
                 (hooks (gethash "hooks" data)))
            (should (hash-table-p hooks))
            (should (gethash "Stop" hooks))
            (should (gethash "Notification" hooks))))
      (delete-file settings)
      (delete-file wrapper))))

;;;; Batch collect todos

(ert-deftest agent-claude-test-batch-collect-todos-buffer-scope ()
  "Collect TODO entries from the entire buffer."
  (with-temp-buffer
    (org-mode)
    (insert "* TODO First task\nSome body text\n* TODO Second task\nMore body\n* DONE Finished\nDone body\n")
    (let ((entries (agent-claude--batch-collect-todos 'buffer)))
      (should (= (length entries) 2))
      (should (equal (plist-get (nth 0 entries) :title) "First task"))
      (should (string-match-p "Some body text" (plist-get (nth 0 entries) :body)))
      (should (equal (plist-get (nth 1 entries) :title) "Second task")))))

(ert-deftest agent-claude-test-batch-collect-todos-skips-done ()
  "DONE entries are excluded from the collected list."
  (with-temp-buffer
    (org-mode)
    (insert "* DONE Completed\nBody\n* TODO Active\nActive body\n")
    (let ((entries (agent-claude--batch-collect-todos 'buffer)))
      (should (= (length entries) 1))
      (should (equal (plist-get (nth 0 entries) :title) "Active")))))

(ert-deftest agent-claude-test-batch-collect-todos-empty-body ()
  "TODO entries with no body text get an empty string body."
  (with-temp-buffer
    (org-mode)
    (insert "* TODO No body entry\n* TODO Another entry\n")
    (let ((entries (agent-claude--batch-collect-todos 'buffer)))
      (should (= (length entries) 2))
      (should (equal (plist-get (nth 0 entries) :title) "No body entry"))
      (should (string-empty-p (plist-get (nth 0 entries) :body))))))

(ert-deftest agent-claude-test-batch-collect-todos-no-todos ()
  "Return nil when buffer has no TODO entries."
  (with-temp-buffer
    (org-mode)
    (insert "* Regular heading\nSome text\n* Another heading\n")
    (let ((entries (agent-claude--batch-collect-todos 'buffer)))
      (should (null entries)))))

(ert-deftest agent-claude-test-batch-collect-todos-subtree-scope ()
  "Collect only TODO entries within the current subtree."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** TODO Child task\nChild body\n** DONE Done child\n* TODO Outside\nOutside body\n")
    (goto-char (point-min))
    (save-restriction
      (org-narrow-to-subtree)
      (let ((entries (agent-claude--batch-collect-todos 'subtree)))
        (should (= (length entries) 1))
        (should (equal (plist-get (nth 0 entries) :title) "Child task"))))))

(provide 'agent-claude-test)
;;; agent-claude-test.el ends here
