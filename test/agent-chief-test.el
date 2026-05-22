;;; agent-chief-test.el --- Tests for agent-chief -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-chief)

(defun agent-chief-test--backend (&rest keys)
  "Return a minimal valid backend plist extended with KEYS."
  (append
   keys
   (list :buffer-p (lambda (_buffer) nil)
         :find-all-buffers (lambda () nil)
         :extract-instance-name (lambda (_buffer-name) nil)
         :start-new #'ignore
         :label "Test")))

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

(ert-deftest agent-chief-test-handle-decision-notifies-without-recording-state ()
  "Notify but do not persist model state updates by default."
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
          (should (zerop (nth 7 (file-attributes agent-chief-state-file)))))
      (when (file-exists-p agent-chief-state-file)
        (delete-file agent-chief-state-file)))))

(ert-deftest agent-chief-test-handle-decision-records-state-when-enabled ()
  "Append model state updates only when explicitly enabled."
  (let ((agent-chief-state-file (make-temp-file "agent-chief" nil ".org"))
        (agent-chief-record-model-state-updates t))
    (unwind-protect
        (progn
          (agent-chief--handle-decision
           '(:notify :false
             :title ""
             :message ""
             :state_update "Pablo should start with review."))
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

(ert-deftest agent-chief-test-normalizes-legacy-json-system-prompt ()
  "Replace the old JSON-only prompt when building current prompts."
  (let ((agent-chief-system-prompt agent-chief--legacy-json-system-prompt)
        (agent-chief-state-file "/tmp/missing-agent-chief-state"))
    (let ((prompt (agent-chief--build-prompt)))
      (should (equal agent-chief-system-prompt
                     agent-chief--default-system-prompt))
      (should (string-match-p "Return exactly this JSON shape" prompt))
      (should-not (string-match-p "Return exactly one JSON object" prompt)))))

(ert-deftest agent-chief-test-state-context-labels-old-plans-historical ()
  "Tell the model not to treat stale plan headings as active obligations."
  (let ((agent-chief-state-file (make-temp-file "agent-chief" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file agent-chief-state-file
            (insert "* Plan 2026-05-20 [2026-05-20 Wed 18:54]\n\n"
                    "make progress with bench-scraper by 19:00\n"))
          (let ((context (agent-chief--state-context)))
            (should (string-match-p "older Plan headings are historical"
                                    context))
            (should (string-match-p "bench-scraper" context))))
      (when (file-exists-p agent-chief-state-file)
        (delete-file agent-chief-state-file)))))

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

(ert-deftest agent-chief-test-session-heartbeat-submits-to-chief-buffer ()
  "Submit heartbeat prompts to the configured chief session."
  (let ((agent-backends nil)
        (agent-chief-backend 'codex)
        (agent-chief-directory "/tmp/")
        (agent-chief-session-buffer nil)
        (agent-chief--running nil)
        started-buffer
        submitted)
    (unwind-protect
        (progn
          (agent-register-backend
           'codex
           (agent-chief-test--backend
            :find-buffers-for-dir (lambda (_dir)
                                    (and started-buffer
                                         (list started-buffer)))
            :extract-instance-name (lambda (_name) "chief")
            :start (lambda (&rest _args)
                     (setq started-buffer
                           (get-buffer-create "*codex:/tmp/:chief*")))
            :submit-command (lambda (prompt buffer)
                              (setq submitted (list prompt buffer)))))
          (cl-letf (((symbol-function 'require) #'ignore))
            (agent-chief-session-heartbeat))
          (should (eq (cadr submitted) started-buffer))
          (should (string-match-p "Chief-of-staff heartbeat" (car submitted)))
          (with-current-buffer started-buffer
            (should agent-chief--session-awaiting-heartbeat)))
      (when (buffer-live-p started-buffer)
        (kill-buffer started-buffer)))))

(ert-deftest agent-chief-test-start-session-asks-for-plan-in-session ()
  "Start the chief session without prompting in the minibuffer."
  (let ((agent-backends nil)
        (agent-chief-backend 'codex)
        (agent-chief-directory "/tmp/")
        (agent-chief-session-buffer nil)
        (agent-chief--timer nil)
        started-buffer
        submitted
        minibuffer-prompted)
    (unwind-protect
        (progn
          (agent-register-backend
           'codex
           (agent-chief-test--backend
            :find-buffers-for-dir (lambda (_dir)
                                    (and started-buffer
                                         (list started-buffer)))
            :extract-instance-name (lambda (_name) "chief")
            :start (lambda (&rest _args)
                     (setq started-buffer
                           (get-buffer-create "*codex:/tmp/:chief*")))
            :submit-command (lambda (prompt buffer)
                              (push (list prompt buffer) submitted))))
          (cl-letf (((symbol-function 'require) #'ignore)
                    ((symbol-function 'read-string)
                     (lambda (&rest _args)
                       (setq minibuffer-prompted t)
                       "should not happen"))
                    ((symbol-function 'run-at-time)
                     (lambda (&rest _args) 'timer))
                    ((symbol-function 'pop-to-buffer) #'ignore))
            (agent-chief-start-session))
          (should-not minibuffer-prompted)
          (should (equal (cadar submitted) started-buffer))
          (should (string-match-p "Ask me for today's plan"
                                  (caar submitted)))
          (should-not (string-match-p "JSON" (caar submitted)))
          (should-not (string-match-p "State file" (caar submitted))))
      (when (buffer-live-p started-buffer)
        (kill-buffer started-buffer)))))

(ert-deftest agent-chief-test-set-day-plan-forwards-to-session ()
  "Record the day plan and submit it to the live chief session."
  (let ((agent-backends nil)
        (agent-chief-backend 'codex)
        (agent-chief-state-file (make-temp-file "agent-chief" nil ".org"))
        (agent-chief-session-buffer (get-buffer-create "*chief-test*"))
        submitted)
    (unwind-protect
        (progn
          (agent-register-backend
           'codex
           (agent-chief-test--backend
            :submit-command (lambda (prompt buffer)
                              (setq submitted (list prompt buffer)))))
          (with-current-buffer agent-chief-session-buffer
            (setq-local agent-chief--session-backend 'codex))
          (agent-chief-set-day-plan "Write the report by 15:00")
          (should (equal (cadr submitted) agent-chief-session-buffer))
          (should (string-match-p "Write the report" (car submitted)))
          (with-temp-buffer
            (insert-file-contents agent-chief-state-file)
            (should (string-match-p "Write the report" (buffer-string)))))
      (when (buffer-live-p agent-chief-session-buffer)
        (kill-buffer agent-chief-session-buffer))
      (when (file-exists-p agent-chief-state-file)
        (delete-file agent-chief-state-file)))))

(ert-deftest agent-chief-test-session-ready-notifies-on-nudge ()
  "Notify when a chief heartbeat response contains a nudge marker."
  (let ((agent-chief-session-buffer (get-buffer-create "*chief-test*"))
        (agent-chief--running t)
        calls)
    (unwind-protect
        (with-current-buffer agent-chief-session-buffer
          (erase-buffer)
          (setq-local agent-chief--session-awaiting-heartbeat t)
          (setq agent-chief--session-start-marker (copy-marker (point-min)))
          (insert "prompt says CHIEF_NO_NUDGE\n")
          (insert "CHIEF_NUDGE: Switch to the report now.\n")
          (let ((agent-chief-notify-function
                 (lambda (title message)
                   (push (list title message) calls))))
            (agent-chief--handle-backend-event
             (list :type 'notification
                   :buffer-name (buffer-name agent-chief-session-buffer))))
          (should (equal calls
                         '(("Chief of staff"
                            "Switch to the report now."))))
          (should-not agent-chief--session-awaiting-heartbeat)
          (should-not agent-chief--running))
      (when (buffer-live-p agent-chief-session-buffer)
        (kill-buffer agent-chief-session-buffer)))))

(ert-deftest agent-chief-test-session-ready-suppresses-no-nudge ()
  "Do not notify when the last chief marker is CHIEF_NO_NUDGE."
  (let ((agent-chief-session-buffer (get-buffer-create "*chief-test*"))
        (agent-chief--running t)
        calls)
    (unwind-protect
        (with-current-buffer agent-chief-session-buffer
          (erase-buffer)
          (setq-local agent-chief--session-awaiting-heartbeat t)
          (setq agent-chief--session-start-marker (copy-marker (point-min)))
          (insert "prompt says CHIEF_NUDGE: example\n")
          (insert "CHIEF_NO_NUDGE\n")
          (let ((agent-chief-notify-function
                 (lambda (&rest args) (push args calls))))
            (agent-chief--handle-backend-event
             (list :type 'notification
                   :buffer-name (buffer-name agent-chief-session-buffer))))
          (should-not calls)
          (should-not agent-chief--session-awaiting-heartbeat)
          (should-not agent-chief--running))
      (when (buffer-live-p agent-chief-session-buffer)
        (kill-buffer agent-chief-session-buffer)))))

(ert-deftest agent-chief-test-session-ready-suppresses-human-no-nudge ()
  "Do not notify when the chief replies with the human no-nudge marker."
  (let ((agent-chief-session-buffer (get-buffer-create "*chief-test*"))
        (agent-chief--running t)
        calls)
    (unwind-protect
        (with-current-buffer agent-chief-session-buffer
          (erase-buffer)
          (setq-local agent-chief--session-awaiting-heartbeat t)
          (setq agent-chief--session-start-marker (copy-marker (point-min)))
          (insert "No nudge.\n")
          (let ((agent-chief-notify-function
                 (lambda (&rest args) (push args calls))))
            (agent-chief--handle-backend-event
             (list :type 'notification
                   :buffer-name (buffer-name agent-chief-session-buffer))))
          (should-not calls)
          (should-not agent-chief--session-awaiting-heartbeat)
          (should-not agent-chief--running))
      (when (buffer-live-p agent-chief-session-buffer)
        (kill-buffer agent-chief-session-buffer)))))

(ert-deftest agent-chief-test-session-ready-notifies-on-human-nudge ()
  "Notify when the chief heartbeat response contains the human nudge marker."
  (let ((agent-chief-session-buffer (get-buffer-create "*chief-test*"))
        (agent-chief--running t)
        calls)
    (unwind-protect
        (with-current-buffer agent-chief-session-buffer
          (erase-buffer)
          (setq-local agent-chief--session-awaiting-heartbeat t)
          (setq agent-chief--session-start-marker (copy-marker (point-min)))
          (insert "Nudge: Switch to the report now.\n")
          (let ((agent-chief-notify-function
                 (lambda (title message)
                   (push (list title message) calls))))
            (agent-chief--handle-backend-event
             (list :type 'notification
                   :buffer-name (buffer-name agent-chief-session-buffer))))
          (should (equal calls
                         '(("Chief of staff"
                            "Switch to the report now.")))))
      (when (buffer-live-p agent-chief-session-buffer)
        (kill-buffer agent-chief-session-buffer)))))

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
