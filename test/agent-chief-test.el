;;; agent-chief-test.el --- Tests for agent-chief -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-chief)

(ert-deftest agent-chief-test-extract-json-from-fenced-output ()
  "Extract a JSON object from fenced model output."
  (should
   (equal (agent-chief--extract-decision-json
           "```json\n{\"notify\":false,\"message\":\"\"}\n```")
          "{\"notify\":false,\"message\":\"\"}")))

(ert-deftest agent-chief-test-extract-json-skips-echoed-schema ()
  "Skip invalid JSON-like objects before the model's decision."
  (should
   (equal
    (agent-chief--extract-decision-json
     (concat
      "Return {\"notify\":true|false,\"message\":\"shape\"}\n"
      "codex\n"
      "{\"notify\":true,\"title\":\"Focus\",\"message\":\"Go\",\"state_update\":\"\"}\n"
      "tokens used\n16,134"))
    "{\"notify\":true,\"title\":\"Focus\",\"message\":\"Go\",\"state_update\":\"\"}")))

(ert-deftest agent-chief-test-extract-json-respects-braces-in-strings ()
  "Do not treat braces inside JSON strings as object delimiters."
  (should
   (equal
    (agent-chief--extract-decision-json
     "{\"notify\":false,\"message\":\"literal { brace }\"}")
    "{\"notify\":false,\"message\":\"literal { brace }\"}")))

(ert-deftest agent-chief-test-parse-decision-requires-notify ()
  "Reject decisions without a notify field."
  (should-error
   (agent-chief--parse-decision "{\"message\":\"hi\"}")))

(ert-deftest agent-chief-test-handle-decision-notifies-and-records-state ()
  "Notify and append state updates when requested by DECISION."
  (let ((agent-chief-state-file (make-temp-file "agent-chief" nil ".org"))
        (calls nil))
    (unwind-protect
        (progn
          (let ((agent-chief-notify-function
                 (lambda (title message)
                   (push (list title message) calls))))
            (agent-chief--handle-decision
             '(:notify t
               :title "Focus"
               :message "Start the planned review."
               :state_update "Pablo should start with review.")))
          (should (equal calls '(("Focus" "Start the planned review."))))
          (with-temp-buffer
            (insert-file-contents agent-chief-state-file)
            (should (string-match-p "Model state update" (buffer-string)))
            (should (string-match-p "Pablo should start" (buffer-string)))))
      (when (file-exists-p agent-chief-state-file)
        (delete-file agent-chief-state-file)))))

(ert-deftest agent-chief-test-build-prompt-includes-context-functions ()
  "Include configured context snippets in the tick prompt."
  (let ((agent-chief-state-file "/tmp/missing-agent-chief-state")
        (agent-chief-context-functions
         (list (lambda () "Calendar: write block at 10")
               (lambda () "")
               (lambda () nil))))
    (let ((prompt (agent-chief--build-prompt)))
      (should (string-match-p "Calendar: write block at 10" prompt))
      (should (string-match-p "state file is empty or missing" prompt)))))

(ert-deftest agent-chief-test-run-backend-dispatches-to-codex ()
  "Dispatch a chief tick to the Codex non-interactive runner."
  (let ((agent-chief-backend 'codex)
        (agent-chief-directory "/tmp/")
        called)
    (cl-letf (((symbol-function 'require) #'ignore)
              ((symbol-function 'agent-codex--run-prompt)
               (lambda (prompt &rest kwargs)
                 (setq called (list prompt kwargs)))))
      (agent-chief--run-backend "Prompt" #'ignore)
      (should (equal (car called) "Prompt"))
      (should (equal (plist-get (cadr called) :dir) "/tmp/")))))

(ert-deftest agent-chief-test-start-replaces-existing-timer ()
  "Starting the loop cancels any existing chief timer."
  (let ((agent-chief--timer 'old)
        (cancelled nil)
        (scheduled nil))
    (cl-letf (((symbol-function 'timerp) (lambda (value) (eq value 'old)))
              ((symbol-function 'cancel-timer)
               (lambda (timer) (setq cancelled timer)))
              ((symbol-function 'run-at-time)
               (lambda (delay repeat function &rest _args)
                 (setq scheduled (list delay repeat function))
                 'new)))
      (agent-chief-start t)
      (should (eq cancelled 'old))
      (should (eq agent-chief--timer 'new))
      (should (equal scheduled
                     (list agent-chief-interval
                           agent-chief-interval
                           #'agent-chief-tick))))))

(provide 'agent-chief-test)
;;; agent-chief-test.el ends here
