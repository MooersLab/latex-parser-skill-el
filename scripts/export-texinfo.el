;;; export-texinfo.el --- Export the manual to Texinfo -*- lexical-binding: t; -*-

;;; Commentary:

;; Usage: emacs -Q --batch -l scripts/export-texinfo.el docs/latex-parser-skill.org
;; The Org sources use #+INDEX: lines, which become \index entries in
;; LaTeX.  Texinfo needs #+CINDEX: lines, so this script converts them
;; in the export copy after the INCLUDE lines are expanded.

;;; Code:

(require 'ox-texinfo)

(defun export-texinfo--cindex (_backend)
  "Turn #+INDEX: lines into #+CINDEX: lines in the export buffer."
  (goto-char (point-min))
  (while (re-search-forward "^\\([ \t]*\\)#\\+INDEX:" nil t)
    (replace-match "\\1#+CINDEX:" t)))

(add-hook (if (boundp 'org-export-before-parsing-functions)
              'org-export-before-parsing-functions
            'org-export-before-parsing-hook)
          #'export-texinfo--cindex)

(dolist (file command-line-args-left)
  (with-current-buffer (find-file-noselect file)
    (org-texinfo-export-to-texinfo)))
(setq command-line-args-left nil)

;;; export-texinfo.el ends here
