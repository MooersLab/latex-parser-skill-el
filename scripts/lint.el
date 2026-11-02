;;; lint.el --- Run checkdoc and package-lint in batch mode -*- lexical-binding: t; -*-

;;; Commentary:

;; Usage: emacs -Q --batch -L . -l scripts/lint.el FILE...
;; Installs package-lint from MELPA into .elpa when it is missing, or
;; loads it from $PACKAGE_LINT_DIR, then runs checkdoc and package-lint
;; on every FILE.  Exits with status 1 when either tool reports a
;; problem.

;;; Code:

(require 'package)
(require 'checkdoc)

(setq package-user-dir (expand-file-name ".elpa" default-directory))
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)
(let ((dir (getenv "PACKAGE_LINT_DIR")))
  (if (and dir (file-directory-p dir))
      (add-to-list 'load-path dir)
    (unless (package-installed-p 'package-lint)
      (package-refresh-contents)
      (package-install 'package-lint))))
(require 'package-lint)

(defvar lint--failed nil
  "Non-nil when a check found a problem.")

(let ((files command-line-args-left)
      (checkdoc-diagnostic-buffer "*checkdoc*"))
  (setq command-line-args-left nil)
  (dolist (file files)
    (with-current-buffer (find-file-noselect file)
      (let ((checkdoc-autofix-flag 'never)
            (checkdoc-create-error-function
             (lambda (text start _end &optional _unfixable)
               (setq lint--failed t)
               (message "%s:%d: checkdoc: %s" file
                        (line-number-at-pos start) text)
               nil)))
        (checkdoc-current-buffer t))))
  (let ((package-lint-main-file "latex-parser-skill.el"))
    (dolist (file files)
      (with-current-buffer (find-file-noselect file)
        (dolist (issue (package-lint-buffer))
          (setq lint--failed t)
          (message "%s:%d:%d: package-lint %s: %s" file
                   (nth 0 issue) (nth 1 issue) (nth 2 issue) (nth 3 issue)))))))

(kill-emacs (if lint--failed 1 0))

;;; lint.el ends here
