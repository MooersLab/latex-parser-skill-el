;;; latex-parser-skill-pipeline-test.el --- Pipeline, input and output tests -*- lexical-binding: t; -*-

;;; Commentary:

;; End-to-end tests with the fake backend: the pipeline, the region,
;; buffer and file commands, and every output action.

;;; Code:

(require 'test-helper)

;;;; Pipeline

(ert-deftest lps-pipeline-sync-good-reply ()
  (lps-test-with-env
    (let ((r (latex-parser-skill-process-string-sync
              (lps-test-read "raw-short.txt"))))
      (should (equal (car r) (lps-test-read "parsed-good.tex")))
      (should (null (cdr r)))
      (should (= 1 (length lps-test-requests))))))

(ert-deftest lps-pipeline-runs-stage-1-first ()
  (lps-test-with-env
    (latex-parser-skill-process-string-sync "We can't stop.")
    (should (string-match-p "We cannot stop\\." (cdr (car lps-test-requests))))
    (let ((latex-parser-skill-run-replacements nil)
          (lps-test-requests nil))
      (latex-parser-skill-process-string-sync "We can't stop.")
      (should (string-match-p "can't" (cdr (car lps-test-requests)))))))

(ert-deftest lps-pipeline-repairs-errors ()
  (lps-test-with-env
    (setq lps-test-replies (list (lps-test-read "parsed-bad-contraction.tex")
                                 (lps-test-read "parsed-good.tex")))
    (let ((r (latex-parser-skill-process-string-sync "text")))
      (should (= 2 (length lps-test-requests)))
      (should (string-match-p "Expand the contraction"
                              (cdr (car lps-test-requests))))
      (should (null (cdr r))))))

(ert-deftest lps-pipeline-repair-limit ()
  (lps-test-with-env
    (let ((bad (lps-test-read "parsed-bad-contraction.tex")))
      (setq lps-test-replies (list bad bad bad))
      (let ((r (latex-parser-skill-process-string-sync "text")))
        (should (= 2 (length lps-test-requests)))
        (should (latex-parser-skill-violation-errors (cdr r)))))
    (let ((latex-parser-skill-repair-attempts 0)
          (lps-test-requests nil))
      (setq lps-test-replies (list (lps-test-read "parsed-bad-contraction.tex")))
      (latex-parser-skill-process-string-sync "text")
      (should (= 1 (length lps-test-requests))))))

(ert-deftest lps-pipeline-chunks-and-merges ()
  (lps-test-with-env
    (let ((latex-parser-skill-chunk-sizes '((fake . 250))))
      (let* ((r (latex-parser-skill-process-string-sync (lps-test-read "raw-long.txt")))
             (n (length lps-test-requests)))
        (should (> n 1))
        (with-temp-buffer
          (insert (car r))
          (should (= n (how-many "Crystal Growth" (point-min) (point-max))))
          (should (= 1 (how-many "begin{itemize}" (point-min) (point-max)))))
        (should (null (latex-parser-skill-violation-errors (cdr r))))))))

(ert-deftest lps-pipeline-error ()
  (lps-test-with-env
    (setq lps-test-replies (list (cons 'error "boom")))
    (should-error (latex-parser-skill-process-string-sync "text"))))

(ert-deftest lps-pipeline-cancel ()
  (lps-test-with-env
    (let* ((called nil)
           (run (latex-parser-skill-process-string
                 "text" (lambda (&rest _) (setq called t)))))
      (latex-parser-skill-cancel-run run)
      (lps-test-wait (lambda () called) 0.5)
      (should-not called))))

;;;; Commands and output actions

(defmacro lps-test-in-latex (content &rest body)
  "Run BODY in a `latex-mode' buffer that holds CONTENT."
  (declare (indent 1))
  `(with-temp-buffer
     (latex-mode)
     (insert ,content)
     ,@body))

(ert-deftest lps-command-refuses-non-latex-buffer ()
  (lps-test-with-env
    (with-temp-buffer
      (fundamental-mode)
      (insert "text")
      (should-error (latex-parser-skill-buffer) :type 'user-error)
      (let ((latex-parser-skill-check-mode nil)
            (latex-parser-skill-output-action 'new-buffer))
        (latex-parser-skill-buffer)
        (lps-test-wait-for-job)))))

(ert-deftest lps-command-region-needs-active-region ()
  (lps-test-with-env
    (lps-test-in-latex "abc"
                       (deactivate-mark)
                       (should-error (latex-parser-skill-region 1 2) :type 'user-error))))

(ert-deftest lps-command-empty-text ()
  (lps-test-with-env
    (lps-test-in-latex "   \n  "
                       (should-error (latex-parser-skill-buffer) :type 'user-error))))

(ert-deftest lps-command-replace-region ()
  (lps-test-with-env
    (let ((latex-parser-skill-output-action 'replace)
          (transient-mark-mode t))
      (lps-test-in-latex "BEFORE\nraw transcript text\nAFTER\n"
                         (goto-char (point-min))
                         (forward-line 1)
                         (set-mark (point))
                         (forward-line 1)
                         (activate-mark)
                         (latex-parser-skill-region (region-beginning) (region-end))
                         (lps-test-wait-for-job)
                         (should (string-prefix-p "BEFORE\n\\subsubsection{Crystal" (buffer-string)))
                         (should (string-suffix-p "\\end{itemize}\nAFTER\n" (buffer-string)))))))

(ert-deftest lps-command-replace-is-one-undo-step ()
  (lps-test-with-env
    (let ((latex-parser-skill-output-action 'replace))
      (lps-test-in-latex ""
                         (buffer-enable-undo)
                         (insert "raw text")
                         (undo-boundary)
                         (latex-parser-skill-buffer)
                         (lps-test-wait-for-job)
                         (undo-boundary)
                         (should (string-prefix-p "\\subsubsection" (buffer-string)))
                         (primitive-undo 1 (cdr buffer-undo-list))
                         (should (equal (buffer-string) "raw text"))))))

(ert-deftest lps-command-insert-after ()
  (lps-test-with-env
    (let ((latex-parser-skill-output-action 'insert-after))
      (lps-test-in-latex "raw text"
                         (latex-parser-skill-buffer)
                         (lps-test-wait-for-job)
                         (should (string-prefix-p "raw text\n\n\\subsubsection" (buffer-string)))))))

(ert-deftest lps-command-body-only ()
  (lps-test-with-env
    (let ((latex-parser-skill-output-action 'replace))
      (lps-test-in-latex "\\documentclass{article}\n\\begin{document}\nraw text\n\\end{document}\n"
                         (latex-parser-skill-buffer)
                         (lps-test-wait-for-job)
                         (should (equal (cdr (car lps-test-requests))
                                        (latex-parser-skill-parse-message "raw text\n")))
                         (should (string-prefix-p "\\documentclass{article}\n\\begin{document}\n\\subsubsection"
                                                  (buffer-string)))
                         (should (string-suffix-p "\\end{document}\n" (buffer-string)))))))

(ert-deftest lps-command-source-changed-goes-to-new-buffer ()
  (lps-test-with-env
    (let ((latex-parser-skill-output-action 'replace))
      (lps-test-in-latex "raw text"
                         (latex-parser-skill-buffer)
                         (goto-char (point-min))
                         (insert "edited ")
                         (lps-test-wait-for-job)
                         (should (equal (buffer-string) "edited raw text"))
                         (let ((res (get-buffer "*latex-parser-skill-result*")))
                           (should res)
                           (kill-buffer res))))))

(ert-deftest lps-command-one-job-at-a-time ()
  (lps-test-with-env
    (let ((latex-parser-skill-output-action 'new-buffer))
      (lps-test-in-latex "raw text"
                         (latex-parser-skill-buffer)
                         (should-error (latex-parser-skill-buffer) :type 'user-error)
                         (latex-parser-skill-cancel)
                         (should (null latex-parser-skill--current-job))))))

(ert-deftest lps-command-preview-accept-and-reject ()
  (lps-test-with-env
    (let ((latex-parser-skill-output-action 'preview))
      (lps-test-in-latex "raw text"
                         (let ((src (current-buffer)))
                           (latex-parser-skill-buffer)
                           (lps-test-wait-for-job)
                           (with-current-buffer "*latex-parser-skill-preview*"
                             (should latex-parser-skill-preview-mode)
                             (goto-char (point-max))
                             (insert "% edited in preview\n")
                             (latex-parser-skill-preview-accept))
                           (should (string-suffix-p "% edited in preview\n"
                                                    (with-current-buffer src (buffer-string))))
                           (with-current-buffer src
                             (erase-buffer)
                             (insert "raw again"))
                           (with-current-buffer src (latex-parser-skill-buffer))
                           (lps-test-wait-for-job)
                           (with-current-buffer "*latex-parser-skill-preview*"
                             (latex-parser-skill-preview-reject))
                           (should (equal (with-current-buffer src (buffer-string)) "raw again")))))))

(ert-deftest lps-command-file-writes-parsed-file ()
  (lps-test-with-env
    (let* ((dir (make-temp-file "lps-dir" t))
           (file (expand-file-name "meeting_notes.txt" dir)))
      (unwind-protect
          (progn
            (copy-file (lps-test-fixture "raw-short.txt") file)
            (latex-parser-skill-file file)
            (lps-test-wait-for-job)
            (let ((out (expand-file-name "meeting_notes_parsed.tex" dir)))
              (should (file-exists-p out))
              (should (equal (with-temp-buffer (insert-file-contents out) (buffer-string))
                             (lps-test-read "parsed-good.tex")))))
        (delete-directory dir t)))))

(ert-deftest lps-parsed-file-name ()
  (should (equal (latex-parser-skill-parsed-file-name "/a/meeting_notes.txt")
                 "/a/meeting_notes_parsed.tex"))
  (should (equal (latex-parser-skill-parsed-file-name "/a/notes.tex")
                 "/a/notes_parsed.tex")))

(ert-deftest lps-confirm-remote-once ()
  (let ((latex-parser-skill-confirm-remote t)
        (latex-parser-skill-warn-size nil)
        (latex-parser-skill-backend 'claude-code)
        (latex-parser-skill--remote-confirmed nil)
        (asked 0))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_p) (cl-incf asked) t)))
      (should (latex-parser-skill--confirm "x"))
      (should (latex-parser-skill--confirm "x"))
      (should (= asked 1)))))

(ert-deftest lps-warn-size ()
  (let ((latex-parser-skill-confirm-remote nil)
        (latex-parser-skill-warn-size 3))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_p) nil)))
      (should (latex-parser-skill--confirm "abc"))
      (should-not (latex-parser-skill--confirm "abcd")))))

(ert-deftest lps-insert-preamble ()
  (lps-test-in-latex "\\documentclass{article}\n\\usepackage{amssymb}\n\\begin{document}\nx\n\\end{document}\n"
                     (latex-parser-skill-insert-preamble)
                     (should (string-match-p "\\\\usepackage{enumitem}\n\\\\usepackage{makeidx}\n\\\\makeindex\n\\\\newcommand{\\\\unchecked}{\\$\\\\square\\$}\n\\\\begin{document}"
                                             (buffer-string)))
                     (should (= 1 (how-many "amssymb" (point-min) (point-max))))
                     (let ((before (buffer-string)))
                       (latex-parser-skill-insert-preamble)
                       (should (equal before (buffer-string))))))

(ert-deftest lps-select-backend ()
  (let ((latex-parser-skill-backend 'claude-code))
    (latex-parser-skill-select-backend 'anthropic-api)
    (should (eq latex-parser-skill-backend 'anthropic-api))
    (should-error (latex-parser-skill-select-backend 'nope))))

(ert-deftest lps-keymap-and-menu ()
  (should (eq (lookup-key latex-parser-skill-command-map "r") #'latex-parser-skill-region))
  (should (eq (lookup-key latex-parser-skill-command-map "t") #'latex-parser-skill-menu))
  (should (commandp #'latex-parser-skill-menu)))

(ert-deftest lps-batch-entry-point ()
  (lps-test-with-env
    (let* ((dir (make-temp-file "lps-batch" t))
           (file (expand-file-name "notes.txt" dir))
           (command-line-args-left (list file)))
      (unwind-protect
          (progn
            (copy-file (lps-test-fixture "raw-short.txt") file)
            (latex-parser-skill-batch)
            (should (file-exists-p (expand-file-name "notes_parsed.tex" dir)))
            (should (null command-line-args-left)))
        (delete-directory dir t)))))

(provide 'latex-parser-skill-pipeline-test)
;;; latex-parser-skill-pipeline-test.el ends here
