;;; latex-parser-skill-chunk.el --- Split input and clean model output -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Blaine Mooers

;; Author: Blaine Mooers <blaine-mooers@ou.edu>
;; URL: https://github.com/MooersLab/latex-parser-skill-el
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Long transcripts can exceed the context window of a local model.
;; This file splits the input at blank lines into chunks of a bounded
;; size, cleans the reply of each request, and merges the parsed
;; chunks so that one TODO block closes the result.

;;; Code:

(require 'subr-x)
(require 'latex-parser-skill-common)

(defun latex-parser-skill--split-sentences (paragraph size)
  "Split PARAGRAPH into pieces no longer than SIZE at sentence ends.
A single sentence longer than SIZE stays whole."
  (let ((sentences nil)
        (start 0)
        pieces current)
    (while (string-match "[.?!][ \t\n]+" paragraph start)
      (push (substring paragraph start (1+ (match-beginning 0))) sentences)
      (setq start (match-end 0)))
    (when (< start (length paragraph))
      (push (substring paragraph start) sentences))
    (setq sentences (nreverse sentences))
    (dolist (s sentences)
      (if (and current (> (+ (length current) 1 (length s)) size))
          (progn (push current pieces) (setq current s))
        (setq current (if current (concat current " " s) s))))
    (when current (push current pieces))
    (nreverse pieces)))

(defun latex-parser-skill-split (text size)
  "Split TEXT into chunks of at most SIZE characters.
Splits fall at blank lines.  A paragraph longer than SIZE is split at
sentence ends.  When SIZE is nil or TEXT is short, return a list that
holds TEXT alone."
  (if (or (null size) (<= (length text) size))
      (list text)
    (let ((paragraphs (split-string text "\n[ \t]*\n" t "[ \t\n]+"))
          chunks current)
      (dolist (p paragraphs)
        (dolist (piece (if (> (length p) size)
                           (latex-parser-skill--split-sentences p size)
                         (list p)))
          (if (and current (> (+ (length current) 2 (length piece)) size))
              (progn (push current chunks) (setq current piece))
            (setq current (if current (concat current "\n\n" piece) piece)))))
      (when current (push current chunks))
      (nreverse chunks))))

(defun latex-parser-skill-postprocess (text)
  "Clean the raw model reply TEXT and return the LaTeX fragment.
Remove reasoning blocks, Markdown code fences, chatter before the
first heading, and chatter after the TODO block.  End the result
with one newline."
  (let ((s (replace-regexp-in-string "<think>\\(?:.\\|\n\\)*?</think>" "" text)))
    (setq s (replace-regexp-in-string "^[ \t]*```[a-zA-Z]*[ \t]*$" "" s))
    (when (string-match "^[ \t]*\\\\subsubsection" s)
      (setq s (substring s (match-beginning 0))))
    (let ((todo (string-match "^% TODO Items" s)))
      (when (and todo (string-match "^[ \t]*\\\\end{itemize}[ \t]*$" s todo))
        (setq s (substring s 0 (match-end 0)))))
    (concat (string-trim s) "\n")))

(defconst latex-parser-skill--todo-regexp
  (concat "^\\(?:% TODO Items[ \t]*\n\\)?"
          "[ \t]*\\\\begin{itemize}\\[label=\\\\unchecked\\][ \t]*\n"
          "\\(\\(?:.\\|\n\\)*?\\)"
          "[ \t]*\\\\end{itemize}[ \t]*\n?")
  "Regexp for a TODO block.  Group 1 holds the items.")

(defun latex-parser-skill-extract-todos (text)
  "Remove TODO blocks from TEXT.
Return a cons of the remaining body and the list of \\item lines."
  (let ((items nil)
        (body text))
    (while (string-match latex-parser-skill--todo-regexp body)
      (let ((inner (match-string 1 body))
            (beg (match-beginning 0))
            (end (match-end 0)))
        (dolist (line (split-string inner "\n" t "[ \t]+"))
          (when (string-prefix-p "\\item" line)
            (push line items)))
        (setq body (concat (substring body 0 beg) (substring body end)))))
    (cons (string-trim body) (nreverse items))))

(defun latex-parser-skill-todo-block (items)
  "Return a TODO block for ITEMS, a list of \\item lines."
  (concat "% TODO Items\n"
          "\\begin{itemize}[label=\\unchecked]\n"
          (mapconcat #'identity items "\n")
          "\n\\end{itemize}\n"))

(defun latex-parser-skill-merge (parts)
  "Merge the parsed PARTS into one fragment with one final TODO block.
When no part has a TODO item, no block is added."
  (let (bodies items)
    (dolist (part parts)
      (let ((split (latex-parser-skill-extract-todos part)))
        (unless (string-empty-p (car split))
          (push (car split) bodies))
        (setq items (append items (cdr split)))))
    (concat (mapconcat #'identity (nreverse bodies) "\n\n")
            "\n"
            (if items
                (concat "\n" (latex-parser-skill-todo-block (delete-dups items)))
              ""))))

(provide 'latex-parser-skill-chunk)
;;; latex-parser-skill-chunk.el ends here
