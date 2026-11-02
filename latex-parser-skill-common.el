;;; latex-parser-skill-common.el --- Shared helpers for latex-parser-skill -*- lexical-binding: t; -*-

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

;; Customization group, package directory, logging, CSV reading and
;; case handling shared by the other latex-parser-skill files.

;;; Code:

(require 'subr-x)

(defgroup latex-parser-skill nil
  "Apply the transcript-parser skill to text in LaTeX buffers."
  :group 'tex
  :prefix "latex-parser-skill-"
  :link '(url-link "https://github.com/MooersLab/latex-parser-skill-el"))

(defconst latex-parser-skill-directory
  (file-name-directory
   (or load-file-name
       (bound-and-true-p byte-compile-current-file)
       buffer-file-name
       default-directory))
  "Directory that holds the latex-parser-skill Lisp files and data.")

(defcustom latex-parser-skill-log-content t
  "When non-nil, write full request and response text to the log buffer.
When nil, only sizes, timings and errors are logged."
  :type 'boolean
  :group 'latex-parser-skill)

(defconst latex-parser-skill-log-buffer-name "*latex-parser-skill-log*"
  "Name of the buffer that records requests and responses.")

(defun latex-parser-skill-data-file (name)
  "Return the absolute path of NAME inside the package directory."
  (expand-file-name name latex-parser-skill-directory))

(defun latex-parser-skill-log (format-string &rest args)
  "Append a time-stamped line to the log buffer.
FORMAT-STRING and ARGS are passed to `format'."
  (with-current-buffer (get-buffer-create latex-parser-skill-log-buffer-name)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (format-time-string "[%Y-%m-%d %H:%M:%S] ")
              (apply #'format format-string args)
              "\n"))))

(defun latex-parser-skill-log-text (label text)
  "Log TEXT under LABEL when `latex-parser-skill-log-content' is non-nil.
Otherwise log only its length."
  (if latex-parser-skill-log-content
      (latex-parser-skill-log "%s (%d chars):\n%s" label (length text) text)
    (latex-parser-skill-log "%s (%d chars)" label (length text))))

(defun latex-parser-skill-straighten-quotes (string)
  "Return STRING with curly single quotes replaced by apostrophes."
  (replace-regexp-in-string "[\u2018\u2019\u201b\u02bc]" "'" string t t))

(defun latex-parser-skill--csv-unquote (field)
  "Trim FIELD and remove CSV double quotes around it."
  (let ((s (string-trim field)))
    (if (and (>= (length s) 2)
             (eq (aref s 0) ?\")
             (eq (aref s (1- (length s))) ?\"))
        (replace-regexp-in-string "\"\"" "\"" (substring s 1 -1) t t)
      s)))

(defun latex-parser-skill-read-csv (file)
  "Read FILE and return an alist of (TRIGGER . REPLACEMENT).
Only the first comma that is outside double quotes separates the
two fields.  Blank lines, lines that start with #, and a header line
whose first field is trigger or contraction are skipped."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents file))
    (goto-char (point-min))
    (let (result)
      (while (not (eobp))
        (let ((line (string-trim
                     (buffer-substring-no-properties
                      (line-beginning-position) (line-end-position)))))
          (when (and (not (string-empty-p line))
                     (not (string-prefix-p "#" line))
                     (string-match
                      "\\`\\(\"\\(?:[^\"]\\|\"\"\\)*\"\\|[^,]*\\),\\(.*\\)\\'"
                      line))
            (let ((key (latex-parser-skill-straighten-quotes
                        (latex-parser-skill--csv-unquote (match-string 1 line))))
                  (val (latex-parser-skill--csv-unquote (match-string 2 line))))
              (unless (or (string-empty-p key)
                          (member (downcase key) '("trigger" "contraction")))
                (push (cons key val) result)))))
        (forward-line 1))
      (nreverse result))))

(defun latex-parser-skill-apply-case (original replacement)
  "Return REPLACEMENT with the capitalization pattern of ORIGINAL.
An all-capital ORIGINAL gives an all-capital result.  A capitalized
ORIGINAL capitalizes the first letter of REPLACEMENT.  Otherwise
REPLACEMENT is returned unchanged."
  (let ((letters (replace-regexp-in-string "[^[:alpha:]]" "" original)))
    (cond
     ((or (string-empty-p letters) (string-empty-p replacement)) replacement)
     ((and (> (length letters) 1)
           (string= letters (upcase letters))
           (not (string= letters (downcase letters))))
      (upcase replacement))
     ((let ((c (aref letters 0))) (/= c (downcase c)))
      (concat (upcase (substring replacement 0 1)) (substring replacement 1)))
     (t replacement))))

(defvar latex-parser-skill--contraction-cache nil
  "Cons of (SIGNATURE . HASH-TABLE) for the verification contraction table.")

(defun latex-parser-skill-contraction-table (file)
  "Return a hash table of lowercase contractions read from FILE.
The table is cached until FILE changes."
  (let ((sig (list file (file-attribute-modification-time
                         (file-attributes file)))))
    (if (equal sig (car latex-parser-skill--contraction-cache))
        (cdr latex-parser-skill--contraction-cache)
      (let ((table (make-hash-table :test #'equal)))
        (dolist (pair (latex-parser-skill-read-csv file))
          (puthash (downcase (car pair)) (cdr pair) table))
        (setq latex-parser-skill--contraction-cache (cons sig table))
        table))))

(provide 'latex-parser-skill-common)
;;; latex-parser-skill-common.el ends here
