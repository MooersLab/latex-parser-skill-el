;;; latex-parser-skill-live-test.el --- Tests against real backends -*- lexical-binding: t; -*-

;;; Commentary:

;; These tests send a short transcript to real models.  They are
;; skipped unless the environment variable LPS_LIVE is 1.  Pick the
;; backends with LPS_LIVE_BACKENDS, a space-separated list such as
;; "claude-code openai-compatible".  The openai-compatible test reads
;; its model name from LPS_OPENAI_MODEL.
;;
;;   LPS_LIVE=1 LPS_LIVE_BACKENDS="claude-code" make live-test

;;; Code:

(require 'test-helper)

(defun lps-live-enabled-p (backend)
  "Return non-nil if live tests should run for BACKEND."
  (and (equal (getenv "LPS_LIVE") "1")
       (member (symbol-name backend)
               (split-string (or (getenv "LPS_LIVE_BACKENDS") "claude-code")))))

(defun lps-live-run (backend)
  "Parse the short fixture with BACKEND and check the result."
  (let* ((latex-parser-skill-timeout 300)
         (latex-parser-skill-openai-model (or (getenv "LPS_OPENAI_MODEL")
                                              latex-parser-skill-openai-model))
         (r (latex-parser-skill-process-string-sync
             (lps-test-read "raw-short.txt") backend)))
    (message "Live result from %s:\n%s" backend (car r))
    (should (string-match-p "\\\\subsubsection" (car r)))
    (should (string-match-p "\\\\index{" (car r)))
    (should (null (latex-parser-skill-violation-errors (cdr r))))))

(ert-deftest lps-live-claude-code ()
  (skip-unless (lps-live-enabled-p 'claude-code))
  (lps-live-run 'claude-code))

(ert-deftest lps-live-anthropic-api ()
  (skip-unless (lps-live-enabled-p 'anthropic-api))
  (lps-live-run 'anthropic-api))

(ert-deftest lps-live-openai-compatible ()
  (skip-unless (lps-live-enabled-p 'openai-compatible))
  (lps-live-run 'openai-compatible))

(ert-deftest lps-live-gptel ()
  (skip-unless (and (lps-live-enabled-p 'gptel) (require 'gptel nil t)))
  (lps-live-run 'gptel))

(provide 'latex-parser-skill-live-test)
;;; latex-parser-skill-live-test.el ends here
