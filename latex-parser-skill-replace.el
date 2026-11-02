;;; latex-parser-skill-replace.el --- Deterministic text replacements -*- lexical-binding: t; -*-

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

;; Stage 1 of the pipeline.  Text that did not come from a dictation
;; tool with its own clean-up step still holds contractions and
;; dictation errors.  This file fixes the predictable ones before the
;; language model sees the text.
;;
;; The engine is self-contained.  It reads the bundled contraction
;; table plus any rule files listed in
;; `latex-parser-skill-replacement-files'.  A rule file is a CSV file
;; of TRIGGER,REPLACEMENT lines, such as an export from a dictation
;; extension.  Triggers may span several words.  Matching ignores
;; case, respects word boundaries and keeps the case of the original.
;;
;; Contractions ending in 's or 'd are ambiguous ("it's" may be "it
;; is" or "it has").  By default they are left for the model, which
;; reads the whole sentence.
;;
;; Users who prefer an external tool can set
;; `latex-parser-skill-replacement-command' instead.

;;; Code:

(require 'subr-x)
(require 'latex-parser-skill-common)

(defgroup latex-parser-skill-replace nil
  "Stage 1 deterministic replacements."
  :group 'latex-parser-skill
  :prefix "latex-parser-skill-")

(defcustom latex-parser-skill-run-replacements t
  "When non-nil, run Stage 1 replacements before the model stage."
  :type 'boolean
  :group 'latex-parser-skill-replace)

(defcustom latex-parser-skill-contractions-file
  (latex-parser-skill-data-file "data/contractions.csv")
  "CSV file of CONTRACTION,EXPANSION pairs used by Stage 1 and Stage 3."
  :type 'file
  :group 'latex-parser-skill-replace)

(defcustom latex-parser-skill-replacement-files nil
  "Extra CSV rule files of TRIGGER,REPLACEMENT lines.
Files are read in order after the contraction table, and a later
file overrides an earlier one for the same trigger."
  :type '(repeat file)
  :group 'latex-parser-skill-replace)

(defcustom latex-parser-skill-replacement-alist nil
  "Personal rules as an alist of (TRIGGER . REPLACEMENT).
These rules are applied last and override every file."
  :type '(alist :key-type string :value-type string)
  :group 'latex-parser-skill-replace)

(defcustom latex-parser-skill-replacement-deny nil
  "Triggers that must never fire, compared without regard to case."
  :type '(repeat string)
  :group 'latex-parser-skill-replace)

(defcustom latex-parser-skill-skip-ambiguous t
  "When non-nil, leave ambiguous contractions for the model stage.
Ambiguous contractions end in \\='s or \\='d and expand to more than one
reading, such as \"it's\" (it is, it has) and \"I'd\" (I would, I had)."
  :type 'boolean
  :group 'latex-parser-skill-replace)

(defcustom latex-parser-skill-replacement-command nil
  "External command that replaces the built-in Stage 1 engine.
When non-nil, it is a list of a program and its arguments.  The
string %f in an argument is replaced by the name of a temporary
file that holds the input text.  The command must print the result
on standard output.  An example for a Python script follows.

  (\"python3\" \"/path/to/apply_replacements.py\" \"%f\"
   \"--skip-ambiguous\" \"-o\" \"-\")"
  :type '(choice (const :tag "Built-in engine" nil)
                 (repeat :tag "Command and arguments" string))
  :group 'latex-parser-skill-replace)

(defvar latex-parser-skill--rules-cache nil
  "Cons of (SIGNATURE . INDEX) for the Stage 1 rule index.")

(defun latex-parser-skill--ambiguous-p (trigger replacement)
  "Return non-nil if TRIGGER expanding to REPLACEMENT is ambiguous."
  (let ((key (downcase trigger)))
    (or (and (string-suffix-p "'s" key)
             (string-match-p " is\\'" replacement))
        (and (string-suffix-p "'d" key)
             (string-match-p " \\(?:would\\|had\\|did\\)\\'" replacement)))))

(defun latex-parser-skill--rule-alist ()
  "Return the merged Stage 1 rules as an alist of (TRIGGER . REPLACEMENT)."
  (let ((table (make-hash-table :test #'equal))
        (deny (mapcar (lambda (s) (downcase (latex-parser-skill-straighten-quotes s)))
                      latex-parser-skill-replacement-deny))
        result)
    (dolist (file (cons latex-parser-skill-contractions-file
                        latex-parser-skill-replacement-files))
      (when (and file (file-readable-p file))
        (dolist (pair (latex-parser-skill-read-csv file))
          (puthash (downcase (car pair)) pair table))))
    (dolist (pair latex-parser-skill-replacement-alist)
      (puthash (downcase (latex-parser-skill-straighten-quotes (car pair)))
               pair table))
    (maphash
     (lambda (key pair)
       (unless (or (member key deny)
                   (and latex-parser-skill-skip-ambiguous
                        (latex-parser-skill--ambiguous-p (car pair) (cdr pair))))
         (push pair result)))
     table)
    result))

(defun latex-parser-skill--build-index ()
  "Return a hash table that maps a first word to its candidate rules.
Each candidate is a list (REGEXP WORD-COUNT REPLACEMENT).  REGEXP
matches the words after the first one.  The candidates for one
word are sorted with the longest trigger first."
  (let ((index (make-hash-table :test #'equal)))
    (dolist (pair (latex-parser-skill--rule-alist))
      (let ((words (split-string (downcase (car pair)) "[ \t]+" t)))
        (when words
          (push (list (mapconcat (lambda (w) (concat "[ \t\n]+" (regexp-quote w)))
                                 (cdr words) "")
                      (length words)
                      (cdr pair))
                (gethash (car words) index)))))
    (maphash (lambda (k v)
               (puthash k (sort v (lambda (a b) (> (nth 1 a) (nth 1 b)))) index))
             index)
    index))

(defun latex-parser-skill--rule-index ()
  "Return the cached rule index, rebuilding it when the inputs change."
  (let ((sig (list latex-parser-skill-contractions-file
                   (mapcar (lambda (f)
                             (cons f (file-attribute-modification-time
                                      (file-attributes f))))
                           (cons latex-parser-skill-contractions-file
                                 latex-parser-skill-replacement-files))
                   latex-parser-skill-replacement-alist
                   latex-parser-skill-replacement-deny
                   latex-parser-skill-skip-ambiguous)))
    (unless (equal sig (car latex-parser-skill--rules-cache))
      (setq latex-parser-skill--rules-cache
            (cons sig (latex-parser-skill--build-index))))
    (cdr latex-parser-skill--rules-cache)))

(defun latex-parser-skill--in-comment-p (pos)
  "Return non-nil if POS follows an unescaped % on its line."
  (save-excursion
    (goto-char pos)
    (let ((bol (line-beginning-position)) found)
      (while (and (not found)
                  (re-search-backward "%" bol t))
        (unless (eq (char-before) ?\\)
          (setq found t)))
      found)))

(defun latex-parser-skill--boundary-p (pos)
  "Return non-nil if a trigger may end at POS.
A trigger may end at the end of the text, before a character that is
not part of a word, or before a closing apostrophe."
  (let ((c (char-after pos)))
    (or (null c)
        (not (or (eq c ?') (eq c ?_)
                 (string-match-p "[[:alnum:]]" (string c))))
        (and (eq c ?')
             (let ((d (char-after (1+ pos))))
               (or (null d) (not (string-match-p "[[:alnum:]_]" (string d)))))))))

(defun latex-parser-skill--token-keys (token)
  "Return lookup keys for TOKEN as a list of (KEY . OFFSET).
OFFSET is the number of leading apostrophes removed from TOKEN."
  (let* ((right (string-trim-right token "'+"))
         (left (string-trim-left right "'+")))
    (delete-dups
     (list (cons token 0)
           (cons right 0)
           (cons left (- (length right) (length left)))))))

(defun latex-parser-skill--replace-in-buffer (index)
  "Apply the rules in INDEX to the current buffer.
Return the number of replacements made."
  (let ((count 0)
        (case-fold-search t))
    (goto-char (point-min))
    (while (re-search-forward "[[:alnum:]']+" nil t)
      (let* ((tbeg (match-beginning 0))
             (tend (match-end 0))
             (token (downcase (match-string-no-properties 0)))
             (done nil))
        (unless (or (eq (char-before tbeg) ?\\)
                    (latex-parser-skill--in-comment-p tbeg))
          (dolist (key (latex-parser-skill--token-keys token))
            (let ((beg (+ tbeg (cdr key))))
              (dolist (cand (gethash (car key) index))
                (unless done
                  (goto-char (+ beg (length (car key))))
                  (when (and (looking-at (nth 0 cand))
                             (latex-parser-skill--boundary-p (match-end 0)))
                    (let* ((stop (match-end 0))
                           (original (buffer-substring-no-properties beg stop))
                           (new (latex-parser-skill-apply-case
                                 original (nth 2 cand))))
                      (delete-region beg stop)
                      (goto-char beg)
                      (insert new)
                      (setq count (1+ count)
                            done t))))))))
        (unless done (goto-char tend))))
    count))

(defun latex-parser-skill-replace-string (text)
  "Apply Stage 1 replacements to TEXT.
Return a cons of the new text and the number of replacements.  When
`latex-parser-skill-replacement-command' is set, the count is nil."
  (if latex-parser-skill-replacement-command
      (cons (latex-parser-skill--run-replacement-command text) nil)
    (with-temp-buffer
      (insert (latex-parser-skill-straighten-quotes text))
      (let ((count (latex-parser-skill--replace-in-buffer
                    (latex-parser-skill--rule-index))))
        (cons (buffer-string) count)))))

(defun latex-parser-skill--run-replacement-command (text)
  "Run `latex-parser-skill-replacement-command' on TEXT and return stdout.
Signal an error when the command exits with a non-zero status."
  (let ((input (make-temp-file "latex-parser-skill-in" nil ".txt"))
        (errfile (make-temp-file "latex-parser-skill-err")))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'utf-8))
            (write-region text nil input nil 'silent))
          (let* ((cmd (mapcar (lambda (arg)
                                (replace-regexp-in-string "%f" input arg t t))
                              latex-parser-skill-replacement-command))
                 (program (car cmd)))
            (unless (executable-find program)
              (user-error "Replacement command not found: %s" program))
            (with-temp-buffer
              (let* ((coding-system-for-read 'utf-8)
                     (status (apply #'call-process program nil
                                    (list t errfile) nil (cdr cmd))))
                (when (file-readable-p errfile)
                  (let ((err (with-temp-buffer
                               (insert-file-contents errfile)
                               (string-trim (buffer-string)))))
                    (unless (string-empty-p err)
                      (latex-parser-skill-log "Replacement command stderr: %s" err))))
                (unless (eq status 0)
                  (error "Replacement command failed with status %s" status))
                (buffer-string)))))
      (delete-file input)
      (delete-file errfile))))

;;;###autoload
(defun latex-parser-skill-replace-region (beg end)
  "Apply only the Stage 1 replacements to the text between BEG and END."
  (interactive "r")
  (let* ((result (latex-parser-skill-replace-string
                  (buffer-substring-no-properties beg end))))
    (atomic-change-group
      (save-excursion
        (goto-char beg)
        (delete-region beg end)
        (insert (car result))))
    (message "Stage 1 made %s replacements"
             (or (cdr result) "an unknown number of"))))

(provide 'latex-parser-skill-replace)
;;; latex-parser-skill-replace.el ends here
