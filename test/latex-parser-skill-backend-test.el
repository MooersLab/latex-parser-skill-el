;;; latex-parser-skill-backend-test.el --- Backend tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Offline tests of the built-in backends.  The claude-code backend
;; runs a shell script that stands in for the claude program.  The
;; HTTP backends run against a stubbed `url-retrieve'.

;;; Code:

(require 'test-helper)

;;;; Prompt

(ert-deftest lps-prompt-has-skill-rules-and-contract ()
  (let ((p (latex-parser-skill-system-prompt)))
    (should (string-match-p "Remove Sound Descriptions" p))
    (should (string-match-p "Output contract" p))
    (should-not (string-prefix-p "---" p))))

(ert-deftest lps-prompt-strips-front-matter ()
  (let* ((file (make-temp-file "lps-skill" nil ".md"
                               "---\nname: x\ndescription: y\n---\n\n# Body\nRule.\n"))
         (latex-parser-skill-prompt-file file))
    (unwind-protect
        (should (string-prefix-p "# Body\nRule." (latex-parser-skill-system-prompt)))
      (delete-file file))))

(ert-deftest lps-prompt-matches-installed-skill ()
  "Detect drift between the bundled prompt and an installed skill.
Runs only when LPS_SKILL_FILE names a SKILL.md file, as `make
check-prompt' does, so that a plain test run never depends on the
skills installed on one computer."
  (let ((skill (getenv "LPS_SKILL_FILE")))
    (skip-unless (and skill (file-readable-p skill)))
    (let ((bundled (with-temp-buffer
                     (insert-file-contents
                      (latex-parser-skill-data-file "prompts/transcript-parser.md"))
                     (string-trim (buffer-string))))
          (installed (with-temp-buffer
                       (insert-file-contents skill)
                       (goto-char (point-min))
                       (when (looking-at "---\n\\(?:.\\|\n\\)*?\n---\n")
                         (delete-region (point-min) (match-end 0)))
                       (string-trim (buffer-string)))))
      (should (equal bundled installed)))))

(ert-deftest lps-messages ()
  (should (string-suffix-p "\n\nHELLO" (latex-parser-skill-parse-message "HELLO")))
  (let ((m (latex-parser-skill-repair-message "LATEX" "line 1 [error] Bad")))
    (should (string-match-p "line 1 \\[error\\] Bad" m))
    (should (string-suffix-p "LATEX" m))))

;;;; Registry

(ert-deftest lps-registry ()
  (should (latex-parser-skill-backend-get 'claude-code))
  (should (latex-parser-skill-backend-get 'anthropic-api))
  (should (latex-parser-skill-backend-get 'openai-compatible))
  (should (latex-parser-skill-backend-get 'gptel))
  (should-error (latex-parser-skill-backend-get 'no-such-backend) :type 'user-error))

(ert-deftest lps-remote-flags ()
  (should (latex-parser-skill-backend-remote-p 'claude-code))
  (should (latex-parser-skill-backend-remote-p 'anthropic-api))
  (let ((latex-parser-skill-openai-url "http://localhost:11434/v1/chat/completions"))
    (should-not (latex-parser-skill-backend-remote-p 'openai-compatible)))
  (let ((latex-parser-skill-openai-url "https://api.example.org/v1/chat/completions"))
    (should (latex-parser-skill-backend-remote-p 'openai-compatible))))

;;;; claude-code

(ert-deftest lps-claude-command-bundled ()
  (let ((latex-parser-skill-claude-prompt-source 'bundled)
        (latex-parser-skill-claude-model nil)
        (latex-parser-skill-claude-extra-args nil)
        (latex-parser-skill-claude-executable "claude"))
    (let ((cmd (latex-parser-skill-claude-command "SYS")))
      (should (equal (seq-take cmd 2) '("claude" "-p")))
      (should (equal (cadr (member "--system-prompt" cmd)) "SYS"))
      (should (equal (cadr (member "--tools" cmd)) ""))
      (should (equal (cadr (member "--output-format" cmd)) "text"))
      (should (member "--no-session-persistence" cmd))
      (should-not (member "--model" cmd)))))

(ert-deftest lps-claude-command-skill-and-model ()
  (let ((latex-parser-skill-claude-prompt-source 'skill)
        (latex-parser-skill-claude-model "opus")
        (latex-parser-skill-claude-extra-args '("--verbose"))
        (latex-parser-skill-claude-executable "claude"))
    (let ((cmd (latex-parser-skill-claude-command "SYS")))
      (should (string-match-p "transcript-parser skill" (nth 2 cmd)))
      (should-not (member "--system-prompt" cmd))
      (should (member "--append-system-prompt" cmd))
      (should (equal (cadr (member "--model" cmd)) "opus"))
      (should (equal (car (last cmd)) "--verbose")))))

(defun lps-test-claude-run (&optional env)
  "Run the fake claude program with ENV and return (OK . VALUE)."
  (let* ((latex-parser-skill-claude-executable (lps-test-fixture "fake-claude.sh"))
         (latex-parser-skill-claude-model nil)
         (latex-parser-skill-claude-extra-args nil)
         (process-environment (append env process-environment))
         (result nil))
    (latex-parser-skill-backend-request
     'claude-code "SYS" "first line of input\nsecond line"
     (lambda (r) (setq result (cons t r)))
     (lambda (m) (setq result (cons nil m))))
    (lps-test-wait (lambda () result))
    result))

(ert-deftest lps-claude-process-success ()
  (let* ((args-file (make-temp-file "lps-args"))
         (r (lps-test-claude-run (list (concat "FAKE_CLAUDE_ARGS=" args-file)))))
    (unwind-protect
        (progn
          (should (car r))
          (should (string-match-p "first line of input" (cdr r)))
          (should (string-match-p "--system-prompt"
                                  (with-temp-buffer
                                    (insert-file-contents args-file)
                                    (buffer-string)))))
      (delete-file args-file))))

(ert-deftest lps-claude-process-failure ()
  (let ((r (lps-test-claude-run '("FAKE_CLAUDE_FAIL=1"))))
    (should-not (car r))
    (should (string-match-p "status 3" (cdr r)))
    (should (string-match-p "simulated failure" (cdr r)))))

(ert-deftest lps-claude-timeout-and-cancel ()
  (let ((latex-parser-skill-timeout 1))
    (let ((r (lps-test-claude-run '("FAKE_CLAUDE_SLEEP=5"))))
      (should-not (car r))
      (should (string-match-p "No reply" (cdr r))))))

(ert-deftest lps-claude-missing-executable ()
  (let ((latex-parser-skill-claude-executable "no-such-claude-program"))
    (should-error (latex-parser-skill--claude-request "s" "t" #'ignore #'ignore)
                  :type 'user-error)))

;;;; HTTP backends

(defmacro lps-test-with-http (status body &rest forms)
  "Run FORMS with `url-retrieve' answering STATUS and BODY.
The variable `lps-test-http-request' holds the request data."
  (declare (indent 2))
  `(let ((lps-test-http-request nil))
     (cl-letf (((symbol-function 'url-retrieve)
                (lambda (url callback &optional cbargs _silent _cookies)
                  (setq lps-test-http-request
                        (list :url url
                              :method url-request-method
                              :headers url-request-extra-headers
                              :data (decode-coding-string url-request-data 'utf-8)))
                  (let ((buf (generate-new-buffer " *lps-http*")))
                    (with-current-buffer buf
                      (insert (format "HTTP/1.1 %d OK\nContent-Type: application/json\n\n%s"
                                      ,status ,body))
                      (run-at-time 0 nil
                                   (lambda ()
                                     (with-current-buffer buf
                                       (apply callback nil cbargs))))
                      buf)))))
       ,@forms)))

(defvar lps-test-http-request nil
  "Request data captured by `lps-test-with-http'.")

(defun lps-test-http-run (backend)
  "Send a request through BACKEND and return (OK . VALUE)."
  (let (result)
    (latex-parser-skill-backend-request
     backend "SYS" "USER"
     (lambda (r) (setq result (cons t r)))
     (lambda (m) (setq result (cons nil m))))
    (lps-test-wait (lambda () result))
    result))

(ert-deftest lps-anthropic-request ()
  (let ((process-environment (cons "ANTHROPIC_API_KEY=test-key" process-environment))
        (auth-sources nil))
    (lps-test-with-http 200 (lps-test-read "response-anthropic.json")
                        (let ((r (lps-test-http-run 'anthropic-api)))
                          (should (car r))
                          (should (string-prefix-p "\\subsubsection{Topic}" (cdr r)))
                          (should (equal (plist-get lps-test-http-request :method) "POST"))
                          (should (equal (alist-get "x-api-key" (plist-get lps-test-http-request :headers)
                                                    nil nil #'equal)
                                         "test-key"))
                          (let ((json (json-read-from-string (plist-get lps-test-http-request :data))))
                            (should (equal (alist-get 'system json) "SYS"))
                            (should (equal (alist-get 'model json) latex-parser-skill-anthropic-model)))))))

(ert-deftest lps-anthropic-error-message ()
  (let ((process-environment (cons "ANTHROPIC_API_KEY=k" process-environment))
        (auth-sources nil))
    (lps-test-with-http 401 "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key\"}}"
                        (let ((r (lps-test-http-run 'anthropic-api)))
                          (should-not (car r))
                          (should (string-match-p "HTTP 401" (cdr r)))
                          (should (string-match-p "invalid x-api-key" (cdr r)))))))

(ert-deftest lps-openai-request ()
  (let ((latex-parser-skill-openai-model "test-model")
        (latex-parser-skill-openai-url "http://localhost:11434/v1/chat/completions")
        (auth-sources nil))
    (lps-test-with-http 200 (lps-test-read "response-openai.json")
                        (let ((r (lps-test-http-run 'openai-compatible)))
                          (should (car r))
                          (should (string-match-p "One sentence" (cdr r)))
                          (let* ((json (json-read-from-string (plist-get lps-test-http-request :data)))
                                 (msgs (append (alist-get 'messages json) nil)))
                            (should (equal (alist-get 'model json) "test-model"))
                            (should (equal (alist-get 'role (car msgs)) "system"))
                            (should (equal (alist-get 'content (cadr msgs)) "USER"))
                            (should (eq (alist-get 'stream json) :json-false)))
                          (should-not (assoc "Authorization" (plist-get lps-test-http-request :headers)))))))

(ert-deftest lps-openai-needs-model ()
  (let ((latex-parser-skill-openai-model nil))
    (should-error (latex-parser-skill-openai-payload "s" "t") :type 'user-error)))

;;;; gptel

(ert-deftest lps-gptel-backend-with-stub ()
  (let ((captured nil) result)
    (cl-letf (((symbol-function 'require)
               (let ((orig (symbol-function 'require)))
                 (lambda (feature &rest args)
                   (if (eq feature 'gptel) t (apply orig feature args)))))
              ((symbol-function 'gptel-request)
               (lambda (prompt &rest keys)
                 (setq captured (cons prompt keys))
                 (funcall (plist-get keys :callback) "REPLY" nil))))
      (defvar gptel-backend nil)
      (defvar gptel-model nil)
      (latex-parser-skill-backend-request
       'gptel "SYS" "USER"
       (lambda (r) (setq result r))
       #'ignore)
      (should (equal result "REPLY"))
      (should (equal (car captured) "USER"))
      (should (equal (plist-get (cdr captured) :system) "SYS")))))

(provide 'latex-parser-skill-backend-test)
;;; latex-parser-skill-backend-test.el ends here
