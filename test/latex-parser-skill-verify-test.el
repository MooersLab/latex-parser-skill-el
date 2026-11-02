;;; latex-parser-skill-verify-test.el --- Stage 3 tests -*- lexical-binding: t; -*-

;;; Commentary:

;; One passing golden file and one failing fixture per rule.

;;; Code:

(require 'test-helper)

(defun lps-test-rules (fixture &optional level)
  "Return the rule symbols that FIXTURE breaks at LEVEL (default error)."
  (delete-dups
   (mapcar (lambda (v) (plist-get v :rule))
           (seq-filter (lambda (v) (eq (plist-get v :level) (or level 'error)))
                       (latex-parser-skill-verify-string (lps-test-read fixture))))))

(ert-deftest lps-verify-good-file-passes ()
  (should (null (latex-parser-skill-verify-string
                 (lps-test-read "parsed-good.tex")))))

(ert-deftest lps-verify-preamble ()
  (should (memq 'preamble (lps-test-rules "parsed-bad-preamble.tex")))
  (should (= 3 (length (seq-filter
                        (lambda (v) (eq (plist-get v :rule) 'preamble))
                        (latex-parser-skill-verify-string
                         (lps-test-read "parsed-bad-preamble.tex")))))))

(ert-deftest lps-verify-contractions-but-not-possessives ()
  (let ((msgs (mapcar (lambda (v) (plist-get v :message))
                      (seq-filter (lambda (v) (eq (plist-get v :rule) 'contraction))
                                  (latex-parser-skill-verify-string
                                   (lps-test-read "parsed-bad-contraction.tex"))))))
    (should (= 2 (length msgs)))
    (should (seq-some (lambda (m) (string-match-p "can't" m)) msgs))
    (should (seq-some (lambda (m) (string-match-p "It's" m)) msgs))
    (should-not (seq-some (lambda (m) (string-match-p "student" m)) msgs))))

(ert-deftest lps-verify-index ()
  (should (equal (lps-test-rules "parsed-bad-index.tex") '(index))))

(ert-deftest lps-verify-sound-and-dash ()
  (let ((rules (lps-test-rules "parsed-bad-sound.tex")))
    (should (memq 'sound rules))
    (should (memq 'dash rules))))

(ert-deftest lps-verify-todo-last ()
  (should (equal (lps-test-rules "parsed-bad-todo.tex") '(todo))))

(ert-deftest lps-verify-todo-unclosed ()
  (let ((v (latex-parser-skill-verify-string
            "\\subsubsection{A}\n\\index{a}\n\nText.\n\n% TODO Items\n\\begin{itemize}[label=\\unchecked]\n\\item X.\n")))
    (should (seq-some (lambda (x) (string-match-p "Close" (plist-get x :message))) v))))

(ert-deftest lps-verify-missing-todo-is-a-warning ()
  (let ((v (latex-parser-skill-verify-string "\\subsubsection{A}\n\\index{a}\n\nText.\n")))
    (should (equal (mapcar (lambda (x) (plist-get x :level)) v) '(warning)))
    (should (null (latex-parser-skill-violation-errors v)))))

(ert-deftest lps-verify-one-sentence-warning ()
  (let ((v (latex-parser-skill-verify-string
            "\\subsubsection{A}\n\\index{a}\n\nOne sentence. Two sentences.\nWe used e.g. This line.\n")))
    (should (equal (mapcar (lambda (x) (plist-get x :line))
                           (seq-filter (lambda (x) (eq (plist-get x :rule) 'one-sentence)) v))
                   '(4)))))

(ert-deftest lps-verify-check-selection ()
  (let ((latex-parser-skill-verify-checks '(index)))
    (should (null (latex-parser-skill-verify-string
                   (lps-test-read "parsed-bad-contraction.tex"))))))

(ert-deftest lps-verify-format ()
  (should (equal (latex-parser-skill-format-violations
                  (list (list :rule 'x :level 'error :line 3 :message "Bad")))
                 "line 3 [error] Bad")))

(ert-deftest lps-verify-buffer-command ()
  (lps-test-with-env
    (with-temp-buffer
      (insert "\\documentclass{article}\n\\begin{document}\n"
              (lps-test-read "parsed-bad-index.tex")
              "\\end{document}\n")
      (let ((v (latex-parser-skill-verify-buffer)))
        (should (equal (mapcar (lambda (x) (plist-get x :rule))
                               (latex-parser-skill-violation-errors v))
                       '(index))))
      (with-current-buffer "*latex-parser-skill-report*"
        (should (string-match-p "line 1" (buffer-string)))))))

(provide 'latex-parser-skill-verify-test)
;;; latex-parser-skill-verify-test.el ends here
