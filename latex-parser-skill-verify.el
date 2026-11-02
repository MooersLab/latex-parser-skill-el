;;; latex-parser-skill-verify.el --- Check parsed LaTeX against the skill rules -*- lexical-binding: t; -*-

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

;; Stage 3 of the pipeline.  The checks mirror the Verification
;; section of the transcript-parser skill.  Each check returns a list
;; of violations.  A violation is a plist with the keys :rule, :level,
;; :line and :message.  Only violations at the error level trigger the
;; repair pass.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'latex-parser-skill-common)
(require 'latex-parser-skill-replace)

(defgroup latex-parser-skill-verify nil
  "Stage 3 verification of parsed LaTeX."
  :group 'latex-parser-skill
  :prefix "latex-parser-skill-")

(defcustom latex-parser-skill-sound-descriptions
  '("wind blowing" "gunshots" "foot steps" "footsteps" "train rumbling"
    "guns firing" "coughing" "coughs" "sighing" "whistling" "dramatic music"
    "waves crashing" "air whooshing" "car engine rumbling" "clearing throat"
    "music" "dog barking" "lips smacking" "metal clanking" "wind howling"
    "thunder rumbling" "sighs" "laughs" "laughing" "applause" "silence"
    "inaudible" "background noise")
  "Parenthetical sound descriptions that must not remain in the output."
  :type '(repeat string)
  :group 'latex-parser-skill-verify)

(defcustom latex-parser-skill-verify-checks
  '(preamble index contraction sound todo dash one-sentence)
  "Checks that Stage 3 runs.
The symbols are preamble, index, contraction, sound, todo, dash and
one-sentence."
  :type '(set (const preamble) (const index) (const contraction)
              (const sound) (const todo) (const dash) (const one-sentence))
  :group 'latex-parser-skill-verify)

(defun latex-parser-skill--violation (rule level line message)
  "Return a violation plist for RULE at LEVEL on LINE with MESSAGE."
  (list :rule rule :level level :line line :message message))

(defun latex-parser-skill--comment-line-p ()
  "Return non-nil if the current line is a LaTeX comment line."
  (save-excursion
    (beginning-of-line)
    (looking-at-p "[ \t]*%")))

(defun latex-parser-skill--strip-comment (line)
  "Return LINE without a trailing LaTeX comment."
  (if (string-match "\\(?:^\\|[^\\]\\)\\(%.*\\)\\'" line)
      (substring line 0 (match-beginning 1))
    line))

(defun latex-parser-skill--check-preamble ()
  "Return violations for preamble or document environment lines."
  (let (out)
    (goto-char (point-min))
    (while (re-search-forward
            "^[ \t]*\\\\\\(documentclass\\|usepackage\\|begin{document}\\|end{document}\\)"
            nil t)
      (push (latex-parser-skill--violation
             'preamble 'error (line-number-at-pos)
             (format "Remove the \\%s line because the output must be a fragment"
                     (match-string-no-properties 1)))
            out))
    (nreverse out)))

(defun latex-parser-skill--check-index ()
  "Return violations for headings that lack an \\index line."
  (let (out)
    (goto-char (point-min))
    (while (re-search-forward "^[ \t]*\\\\subsubsection\\*?{" nil t)
      (let ((line (line-number-at-pos)))
        (forward-line 1)
        (while (and (not (eobp)) (looking-at-p "[ \t]*$"))
          (forward-line 1))
        (unless (looking-at-p "[ \t]*\\\\index{")
          (push (latex-parser-skill--violation
                 'index 'error line
                 "Add at least one \\index line directly below this heading")
                out))))
    (nreverse out)))

(defun latex-parser-skill--check-contractions ()
  "Return violations for contractions left in the text."
  (let ((table (latex-parser-skill-contraction-table
                latex-parser-skill-contractions-file))
        out)
    (goto-char (point-min))
    (while (not (eobp))
      (unless (latex-parser-skill--comment-line-p)
        (let ((line (latex-parser-skill-straighten-quotes
                     (latex-parser-skill--strip-comment
                      (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position)))))
              (start 0))
          (while (string-match "[[:alnum:]']+" line start)
            (let* ((tok (match-string 0 line))
                   (bare (string-trim tok "'+" "'+"))
                   (hit (cond ((gethash (downcase tok) table) tok)
                              ((gethash (downcase (string-trim-right tok "'+")) table)
                               (string-trim-right tok "'+"))
                              ((and (string-match-p "'" bare)
                                    (gethash (downcase bare) table))
                               bare))))
              (setq start (match-end 0))
              (when (and hit
                         (not (and (> (match-beginning 0) 0)
                                   (eq (aref line (1- (match-beginning 0))) ?\\))))
                (push (latex-parser-skill--violation
                       'contraction 'error (line-number-at-pos)
                       (format "Expand the contraction \"%s\"" hit))
                      out))))))
      (forward-line 1))
    (nreverse out)))

(defun latex-parser-skill--check-sounds ()
  "Return violations for sound-description parentheticals."
  (let ((re (concat "(\\s-*\\("
                    (regexp-opt latex-parser-skill-sound-descriptions)
                    "\\)\\s-*)"))
        (case-fold-search t)
        out)
    (goto-char (point-min))
    (while (re-search-forward re nil t)
      (push (latex-parser-skill--violation
             'sound 'error (line-number-at-pos)
             (format "Remove the sound description \"%s\""
                     (match-string-no-properties 0)))
            out))
    (nreverse out)))

(defconst latex-parser-skill-todo-begin "\\begin{itemize}[label=\\unchecked]"
  "Opening line of the TODO block that the skill produces.")

(defun latex-parser-skill--check-todo ()
  "Return violations for a misplaced or unclosed TODO block."
  (let (out)
    (goto-char (point-max))
    (if (not (search-backward latex-parser-skill-todo-begin nil t))
        (push (latex-parser-skill--violation
               'todo 'warning (line-number-at-pos (point-max))
               "No TODO block was found; add one if the speaker named tasks")
              out)
      (let ((line (line-number-at-pos)))
        (if (not (search-forward "\\end{itemize}" nil t))
            (push (latex-parser-skill--violation
                   'todo 'error line "Close the TODO block with \\end{itemize}")
                  out)
          (let ((rest (buffer-substring-no-properties (point) (point-max))))
            (unless (string-empty-p
                     (string-trim
                      (replace-regexp-in-string "^[ \t]*%.*$" "" rest)))
              (push (latex-parser-skill--violation
                     'todo 'error (line-number-at-pos)
                     "Move the TODO block to the end of the output")
                    out))))))
    out))

(defun latex-parser-skill--check-dashes ()
  "Return violations for em-dashes in prose."
  (let (out)
    (goto-char (point-min))
    (while (re-search-forward "—\\|---" nil t)
      (unless (latex-parser-skill--comment-line-p)
        (push (latex-parser-skill--violation
               'dash 'error (line-number-at-pos)
               "Replace the em-dash with a comma, a period or parentheses")
              out)))
    (nreverse out)))

(defun latex-parser-skill--check-one-sentence ()
  "Return warnings for lines that seem to hold two sentences."
  (let ((case-fold-search nil)
        out)
    (goto-char (point-min))
    (while (not (eobp))
      (let ((line (buffer-substring-no-properties
                   (line-beginning-position) (line-end-position))))
        (when (and (not (string-match-p "\\`[ \t]*[\\%]" line))
                   (string-match-p
                    "[a-z0-9)][.?!][\"']?[ \t]+[A-Z]" line)
                   (not (string-match-p
                         "\\<\\(?:e\\.g\\|i\\.e\\|et al\\|Dr\\|Mr\\|Ms\\|Mrs\\|Fig\\|vs\\)\\.[ \t]"
                         line)))
          (push (latex-parser-skill--violation
                 'one-sentence 'warning (line-number-at-pos)
                 "This line may hold more than one sentence")
                out)))
      (forward-line 1))
    (nreverse out)))

(defconst latex-parser-skill--check-functions
  '((preamble . latex-parser-skill--check-preamble)
    (index . latex-parser-skill--check-index)
    (contraction . latex-parser-skill--check-contractions)
    (sound . latex-parser-skill--check-sounds)
    (todo . latex-parser-skill--check-todo)
    (dash . latex-parser-skill--check-dashes)
    (one-sentence . latex-parser-skill--check-one-sentence))
  "Alist that maps check symbols to their functions.")

(defun latex-parser-skill-verify-string (text)
  "Check TEXT with the Stage 3 rules and return a list of violations.
The list is sorted by line number."
  (with-temp-buffer
    (insert text)
    (let (all)
      (dolist (check latex-parser-skill-verify-checks)
        (let ((fn (alist-get check latex-parser-skill--check-functions)))
          (when fn
            (save-excursion (setq all (append all (funcall fn)))))))
      (sort all (lambda (a b) (< (plist-get a :line) (plist-get b :line)))))))

(defun latex-parser-skill-violation-errors (violations)
  "Return only the error-level members of VIOLATIONS."
  (seq-filter (lambda (v) (eq (plist-get v :level) 'error)) violations))

(defun latex-parser-skill-format-violations (violations)
  "Return VIOLATIONS as text with one violation per line."
  (mapconcat (lambda (v)
               (format "line %d [%s] %s"
                       (plist-get v :line)
                       (plist-get v :level)
                       (plist-get v :message)))
             violations "\n"))

(provide 'latex-parser-skill-verify)
;;; latex-parser-skill-verify.el ends here
