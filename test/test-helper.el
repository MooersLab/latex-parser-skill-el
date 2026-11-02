;;; test-helper.el --- Shared setup for latex-parser-skill tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Loads the package from the repository and registers a fake backend
;; that answers from a queue, so the tests never touch the network.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defconst lps-test-root
  (expand-file-name ".." (file-name-directory
                          (or load-file-name buffer-file-name)))
  "Root directory of the repository.")

(add-to-list 'load-path lps-test-root)
(require 'latex-parser-skill)

(defconst lps-test-fixtures (expand-file-name "test/fixtures" lps-test-root)
  "Directory of test fixtures.")

(defun lps-test-fixture (name)
  "Return the path of fixture NAME."
  (expand-file-name name lps-test-fixtures))

(defun lps-test-read (name)
  "Return the contents of fixture NAME."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents (lps-test-fixture name)))
    (buffer-string)))

(defvar lps-test-replies nil
  "Queue of replies for the fake backend.
Each element is a string, or (error . MESSAGE) for a failure.")

(defvar lps-test-requests nil
  "Requests that the fake backend received, newest first.
Each element is a cons of the system prompt and the user message.")

(defun lps-test--fake-request (system text callback errback)
  "Answer SYSTEM and TEXT from `lps-test-replies' on the next tick.
Call CALLBACK or ERRBACK.  Return a dummy handle."
  (push (cons system text) lps-test-requests)
  (let ((reply (or (pop lps-test-replies)
                   (lps-test-read "parsed-good.tex"))))
    (run-at-time 0 nil
                 (lambda ()
                   (if (and (consp reply) (eq (car reply) 'error))
                       (funcall errback (cdr reply))
                     (funcall callback reply))))
    'fake-handle))

(latex-parser-skill-register-backend
 'fake
 :request #'lps-test--fake-request
 :remote nil
 :cancel #'ignore
 :description "Test backend")

(defmacro lps-test-with-env (&rest body)
  "Run BODY with the fake backend and quiet, non-interactive settings."
  (declare (indent 0) (debug t))
  `(let ((latex-parser-skill-backend 'fake)
         (latex-parser-skill-confirm-remote nil)
         (latex-parser-skill-warn-size nil)
         (latex-parser-skill-show-report 'never)
         (latex-parser-skill-overwrite 'always)
         (latex-parser-skill-replacement-files nil)
         (latex-parser-skill-replacement-alist nil)
         (latex-parser-skill-replacement-command nil)
         (latex-parser-skill-chunk-sizes nil)
         (latex-parser-skill-default-chunk-size nil)
         (latex-parser-skill--current-job nil)
         (lps-test-replies nil)
         (lps-test-requests nil)
         (inhibit-message t))
     ,@body))

(defun lps-test-wait (predicate &optional seconds)
  "Process events until PREDICATE returns non-nil or SECONDS pass.
Return the value of PREDICATE."
  (let ((deadline (+ (float-time) (or seconds 10)))
        value)
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    value))

(defun lps-test-wait-for-job ()
  "Wait until no job is running."
  (lps-test-wait (lambda () (null latex-parser-skill--current-job))))

(provide 'test-helper)
;;; test-helper.el ends here
