;;; latex-parser-skill-chunk-test.el --- Chunking and clean-up tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for splitting input, cleaning replies and merging results.

;;; Code:

(require 'test-helper)

(ert-deftest lps-split-short-text-is-one-chunk ()
  (should (equal (latex-parser-skill-split "abc" nil) '("abc")))
  (should (equal (latex-parser-skill-split "abc" 100) '("abc"))))

(ert-deftest lps-split-at-blank-lines ()
  (let* ((text (lps-test-read "raw-long.txt"))
         (chunks (latex-parser-skill-split text 250)))
    (should (> (length chunks) 1))
    (dolist (c chunks)
      (should (<= (length c) 250))
      (should (string-prefix-p "First" (car chunks))))
    ;; No paragraph is cut in the middle.
    (should (equal (mapconcat #'identity chunks "\n\n")
                   (string-trim text)))))

(ert-deftest lps-split-long-paragraph-at-sentences ()
  (let ((chunks (latex-parser-skill-split
                 "One two three. Four five six. Seven eight nine." 20)))
    (should (equal chunks '("One two three." "Four five six." "Seven eight nine.")))))

(ert-deftest lps-postprocess-strips-fences-and-chatter ()
  (should (equal (latex-parser-skill-postprocess
                  "Here is the result:\n```latex\n\\subsubsection{A}\n\\index{a}\n\nText.\n\n% TODO Items\n\\begin{itemize}[label=\\unchecked]\n\\item X.\n\\end{itemize}\n```\nLet me know if you need more.")
                 "\\subsubsection{A}\n\\index{a}\n\nText.\n\n% TODO Items\n\\begin{itemize}[label=\\unchecked]\n\\item X.\n\\end{itemize}\n")))

(ert-deftest lps-postprocess-removes-think-blocks ()
  (should (equal (latex-parser-skill-postprocess
                  "<think>\nreasoning here\n</think>\n\\subsubsection{A}\n\\index{a}\n")
                 "\\subsubsection{A}\n\\index{a}\n")))

(ert-deftest lps-extract-todos ()
  (let ((r (latex-parser-skill-extract-todos (lps-test-read "parsed-good.tex"))))
    (should (equal (cdr r) '("\\item Email Sam about more cluster time."
                             "\\item Write the methods paragraph this week.")))
    (should-not (string-match-p "itemize" (car r)))))

(ert-deftest lps-merge-puts-one-todo-block-last ()
  (let* ((a "\\subsubsection{A}\n\\index{a}\n\nA.\n\n% TODO Items\n\\begin{itemize}[label=\\unchecked]\n\\item One.\n\\end{itemize}\n")
         (b "\\subsubsection{B}\n\\index{b}\n\nB.\n\n% TODO Items\n\\begin{itemize}[label=\\unchecked]\n\\item Two.\n\\end{itemize}\n")
         (m (latex-parser-skill-merge (list a b))))
    (should (with-temp-buffer (insert m) (= 1 (how-many "begin{itemize}" (point-min) (point-max)))))
    (should (string-match-p "\\\\item One\\.\n\\\\item Two\\.\n\\\\end{itemize}\n\\'" m))
    (should (< (string-match "subsubsection{A}" m) (string-match "subsubsection{B}" m)))
    (should (null (latex-parser-skill-violation-errors
                   (latex-parser-skill-verify-string m))))))

(ert-deftest lps-merge-without-todos ()
  (should (equal (latex-parser-skill-merge '("\\subsubsection{A}\n" "\\subsubsection{B}\n"))
                 "\\subsubsection{A}\n\n\\subsubsection{B}\n")))

(provide 'latex-parser-skill-chunk-test)
;;; latex-parser-skill-chunk-test.el ends here
