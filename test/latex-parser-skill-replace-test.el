;;; latex-parser-skill-replace-test.el --- Stage 1 tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the self-contained replacement engine and the optional
;; external command.

;;; Code:

(require 'test-helper)

(defun lps-test-replace (text)
  "Return Stage 1 output for TEXT."
  (car (latex-parser-skill-replace-string text)))

(ert-deftest lps-replace-expands-contractions ()
  (lps-test-with-env
    (should (equal (lps-test-replace "We don't know and they can't say.")
                   "We do not know and they cannot say."))))

(ert-deftest lps-replace-keeps-case ()
  (lps-test-with-env
    (should (equal (lps-test-replace "Don't. DON'T. don't.")
                   "Do not. DO NOT. do not."))))

(ert-deftest lps-replace-straightens-curly-apostrophes ()
  (lps-test-with-env
    (should (equal (lps-test-replace "We don’t know.")
                   "We do not know."))))

(ert-deftest lps-replace-skips-ambiguous-by-default ()
  (lps-test-with-env
    (should (equal (lps-test-replace "It's late and I'd go.")
                   "It's late and I'd go."))
    (let ((latex-parser-skill-skip-ambiguous nil))
      (should (equal (lps-test-replace "It's late.")
                     "It is late.")))))

(ert-deftest lps-replace-informal-forms-and-leading-apostrophe ()
  (lps-test-with-env
    (should (equal (lps-test-replace "We're gonna wait 'cause it's late.")
                   "We are going to wait because it's late."))))

(ert-deftest lps-replace-leaves-possessives ()
  (lps-test-with-env
    (should (equal (lps-test-replace "The student's notebook.")
                   "The student's notebook."))))

(ert-deftest lps-replace-protects-commands-and-comments ()
  (lps-test-with-env
    (let ((latex-parser-skill-replacement-alist '(("emph" . "EMPHASIS"))))
      (should (equal (lps-test-replace "\\emph{x} emph % don't emph")
                     "\\emph{x} EMPHASIS % don't emph")))))

(ert-deftest lps-replace-rule-files-and-multiword-triggers ()
  (lps-test-with-env
    (let ((latex-parser-skill-replacement-files
           (list (lps-test-fixture "rules.csv"))))
      (should (equal (lps-test-replace
                      "The settle cassin step and Saxs data at one point eight.")
                     "The cell casting step and SAXS data at 1.8.")))))

(ert-deftest lps-replace-word-boundaries ()
  (lps-test-with-env
    (let ((latex-parser-skill-replacement-files
           (list (lps-test-fixture "rules.csv"))))
      (should (equal (lps-test-replace "pymolshortcuts and pymol.")
                     "pymolshortcuts and PyMOL.")))))

(ert-deftest lps-replace-deny-list ()
  (lps-test-with-env
    (let ((latex-parser-skill-replacement-deny '("gonna")))
      (should (equal (lps-test-replace "gonna go")
                     "gonna go")))))

(ert-deftest lps-replace-count ()
  (lps-test-with-env
    (should (= 2 (cdr (latex-parser-skill-replace-string
                       "I'm sure they're here."))))))

(ert-deftest lps-replace-external-command ()
  (lps-test-with-env
    (let ((latex-parser-skill-replacement-command
           (list (lps-test-fixture "fake-replace.sh") "%f")))
      (let ((result (latex-parser-skill-replace-string "alpha beta")))
        (should (equal (car result) "ALPHA beta"))
        (should (null (cdr result)))))))

(ert-deftest lps-replace-region-command ()
  (lps-test-with-env
    (with-temp-buffer
      (insert "keep. We can't go. keep.")
      (latex-parser-skill-replace-region 7 19)
      (should (equal (buffer-string) "keep. We cannot go. keep.")))))

(provide 'latex-parser-skill-replace-test)
;;; latex-parser-skill-replace-test.el ends here
