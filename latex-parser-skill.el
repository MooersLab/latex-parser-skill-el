;;; latex-parser-skill.el --- Apply the transcript-parser skill to LaTeX buffers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Blaine Mooers

;; Author: Blaine Mooers <blaine-mooers@ou.edu>
;; Maintainer: Blaine Mooers <blaine-mooers@ou.edu>
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (transient "0.3.7"))
;; Keywords: tex, wp, convenience
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

;; latex-parser-skill turns raw dictated or transcribed text in a
;; LaTeX buffer into a structured LaTeX fragment.  The fragment has
;; one \subsubsection per topic, \index keys below each heading, one
;; sentence per line, expanded contractions, and a closing checklist
;; of TODO items.  The rules come from the transcript-parser skill.
;;
;; The text can be the active region, the whole buffer, or a file.
;; The work runs in four stages.
;;
;;   1. Replacements   deterministic contraction and dictation fixes
;;   2. Parse          a language model applies the skill
;;   3. Verify         deterministic checks of the skill rules
;;   4. Repair         the model fixes any rule that Stage 3 flags
;;
;; The model can be Claude Code, the Claude API, a local server such
;; as Ollama, or anything configured in gptel.
;;
;; Quick start:
;;
;;   (require 'latex-parser-skill)
;;   (with-eval-after-load 'tex
;;     (define-key LaTeX-mode-map (kbd "C-c t") latex-parser-skill-command-map))
;;   (with-eval-after-load 'tex-mode
;;     (define-key latex-mode-map (kbd "C-c t") latex-parser-skill-command-map))
;;
;; Then select a transcript and press C-c t r.  See the README and the
;; Info manual for the tutorial.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'transient)
(require 'latex-parser-skill-common)
(require 'latex-parser-skill-replace)
(require 'latex-parser-skill-verify)
(require 'latex-parser-skill-chunk)
(require 'latex-parser-skill-backend)

(declare-function diff-no-select "diff")

;;;; Options

(defcustom latex-parser-skill-backend 'claude-code
  "Backend that runs the model stages.
Built-in values are claude-code, anthropic-api, openai-compatible
and gptel."
  :type '(choice (const claude-code) (const anthropic-api)
                 (const openai-compatible) (const gptel) symbol)
  :group 'latex-parser-skill)

(defcustom latex-parser-skill-output-action 'preview
  "What to do with the result of a region or buffer command.
preview      show the result for review before it replaces anything
replace      replace the source text in one undo step
insert-after insert the result after the source text
new-buffer   show the result in a new buffer
file         write NAME_parsed.tex beside the buffer's file"
  :type '(choice (const preview) (const replace) (const insert-after)
                 (const new-buffer) (const file))
  :group 'latex-parser-skill)

(defcustom latex-parser-skill-file-output-action 'file
  "What to do with the result of `latex-parser-skill-file'.
The values are the same as for `latex-parser-skill-output-action',
except that replace and insert-after behave like new-buffer."
  :type '(choice (const file) (const preview) (const new-buffer))
  :group 'latex-parser-skill)

(defcustom latex-parser-skill-repair-attempts 1
  "Number of repair passes allowed for each chunk.
A repair pass runs only when Stage 3 finds an error.  Zero turns the
repair stage off."
  :type 'integer
  :group 'latex-parser-skill)

(defcustom latex-parser-skill-chunk-sizes '((openai-compatible . 12000))
  "Alist of (BACKEND . SIZE) for splitting long input.
SIZE is the largest chunk in characters.  A backend that is missing
from the alist gets `latex-parser-skill-default-chunk-size'."
  :type '(alist :key-type symbol :value-type integer)
  :group 'latex-parser-skill)

(defcustom latex-parser-skill-default-chunk-size nil
  "Chunk size for backends missing from `latex-parser-skill-chunk-sizes'.
nil means that the whole text goes in one request."
  :type '(choice (const :tag "No chunking" nil) integer)
  :group 'latex-parser-skill)

(defcustom latex-parser-skill-confirm-remote t
  "When non-nil, ask once per session before text leaves the computer."
  :type 'boolean
  :group 'latex-parser-skill)

(defcustom latex-parser-skill-warn-size 60000
  "Ask before sending more than this many characters, or nil to never ask."
  :type '(choice (const :tag "Never ask" nil) integer)
  :group 'latex-parser-skill)

(defcustom latex-parser-skill-modes
  '(latex-mode LaTeX-mode tex-mode TeX-mode plain-tex-mode docTeX-mode
               doctex-mode LaTeX-ts-mode)
  "Major modes in which the region and buffer commands run.
Derived modes are accepted too."
  :type '(repeat symbol)
  :group 'latex-parser-skill)

(defcustom latex-parser-skill-check-mode t
  "When non-nil, refuse to run outside `latex-parser-skill-modes'."
  :type 'boolean
  :group 'latex-parser-skill)

(defcustom latex-parser-skill-buffer-body-only t
  "When non-nil, the buffer command parses only the document body.
The body is the text between \\begin{document} and \\end{document}.
A buffer without these lines is parsed whole."
  :type 'boolean
  :group 'latex-parser-skill)

(defcustom latex-parser-skill-show-report 'errors
  "When to show the verification report after a run.
always   after every run
errors   when an error remains after repair
never    never"
  :type '(choice (const always) (const errors) (const never))
  :group 'latex-parser-skill)

(defcustom latex-parser-skill-overwrite 'ask
  "What to do when the output file already exists.
ask asks, always overwrites, and never writes to a new buffer instead."
  :type '(choice (const ask) (const always) (const never))
  :group 'latex-parser-skill)

(defcustom latex-parser-skill-preamble-lines
  '("\\usepackage{enumitem}"
    "\\usepackage{amssymb}"
    "\\usepackage{makeidx}"
    "\\makeindex"
    "\\newcommand{\\unchecked}{$\\square$}")
  "Preamble lines that the parsed output needs to compile."
  :type '(repeat string)
  :group 'latex-parser-skill)

(defcustom latex-parser-skill-finished-hook nil
  "Hook run after a result is delivered.
Each function receives the result text and the list of violations."
  :type 'hook
  :group 'latex-parser-skill)

;;;; Pipeline

(cl-defstruct (latex-parser-skill--run
               (:constructor latex-parser-skill--run-create)
               (:copier nil))
  "State of one pipeline run."
  backend system chunks results request alive start replacements
  callback errback progress)

(defvar latex-parser-skill--remote-confirmed nil
  "Backends that the user allowed to receive text in this session.")

(defun latex-parser-skill-chunk-size (backend)
  "Return the chunk size for BACKEND."
  (if (assq backend latex-parser-skill-chunk-sizes)
      (alist-get backend latex-parser-skill-chunk-sizes)
    latex-parser-skill-default-chunk-size))

(defun latex-parser-skill--progress (run format-string &rest args)
  "Report progress of RUN with FORMAT-STRING and ARGS."
  (let ((msg (apply #'format format-string args)))
    (latex-parser-skill-log "%s" msg)
    (when (latex-parser-skill--run-progress run)
      (funcall (latex-parser-skill--run-progress run) msg))))

(defun latex-parser-skill--request (run message on-reply)
  "Send MESSAGE for RUN and call ON-REPLY with the cleaned reply."
  (latex-parser-skill-log-text "Request" message)
  (setf (latex-parser-skill--run-request run)
        (latex-parser-skill-backend-request
         (latex-parser-skill--run-backend run)
         (latex-parser-skill--run-system run)
         message
         (lambda (reply)
           (when (latex-parser-skill--run-alive run)
             (latex-parser-skill-log-text "Reply" reply)
             (funcall on-reply (latex-parser-skill-postprocess reply))))
         (lambda (msg)
           (when (latex-parser-skill--run-alive run)
             (setf (latex-parser-skill--run-alive run) nil)
             (latex-parser-skill-log "Error: %s" msg)
             (funcall (latex-parser-skill--run-errback run) msg))))))

(defun latex-parser-skill--chunk-done (run index latex)
  "Store LATEX as the result for chunk INDEX of RUN and continue."
  (push latex (latex-parser-skill--run-results run))
  (latex-parser-skill--next-chunk run (1+ index)))

(defun latex-parser-skill--check-chunk (run index latex attempts)
  "Verify LATEX for chunk INDEX of RUN and repair it when needed.
ATTEMPTS is the number of repair passes still allowed."
  (let ((errors (latex-parser-skill-violation-errors
                 (latex-parser-skill-verify-string latex))))
    (if (or (null errors) (<= attempts 0))
        (latex-parser-skill--chunk-done run index latex)
      (latex-parser-skill--progress
       run "Repairing chunk %d (%d errors)" (1+ index) (length errors))
      (latex-parser-skill--request
       run
       (latex-parser-skill-repair-message
        latex (latex-parser-skill-format-violations errors))
       (lambda (fixed)
         (latex-parser-skill--check-chunk run index fixed (1- attempts)))))))

(defun latex-parser-skill--next-chunk (run index)
  "Parse chunk INDEX of RUN, or finish when no chunk is left."
  (let ((chunks (latex-parser-skill--run-chunks run)))
    (if (>= index (length chunks))
        (latex-parser-skill--finish-run run)
      (latex-parser-skill--progress
       run "Parsing chunk %d of %d with %s"
       (1+ index) (length chunks) (latex-parser-skill--run-backend run))
      (latex-parser-skill--request
       run
       (latex-parser-skill-parse-message (nth index chunks))
       (lambda (latex)
         (latex-parser-skill--check-chunk
          run index latex latex-parser-skill-repair-attempts))))))

(defun latex-parser-skill--finish-run (run)
  "Merge the chunk results of RUN and call its callback."
  (let* ((parts (reverse (latex-parser-skill--run-results run)))
         (result (if (cdr parts)
                     (latex-parser-skill-merge parts)
                   (car parts)))
         (violations (latex-parser-skill-verify-string result)))
    (setf (latex-parser-skill--run-alive run) nil)
    (latex-parser-skill-log
     "Finished in %.1f s with %d errors and %d warnings"
     (float-time (time-subtract nil (latex-parser-skill--run-start run)))
     (length (latex-parser-skill-violation-errors violations))
     (- (length violations)
        (length (latex-parser-skill-violation-errors violations))))
    (funcall (latex-parser-skill--run-callback run) result violations)))

(cl-defun latex-parser-skill-process-string
    (text callback &key (backend latex-parser-skill-backend) errback progress)
  "Run the pipeline on TEXT and call CALLBACK with the result.
CALLBACK receives the LaTeX fragment and the list of violations that
remain.  BACKEND overrides `latex-parser-skill-backend'.  ERRBACK
receives an error message.  PROGRESS receives status messages.
Return the run object, which `latex-parser-skill-cancel-run' accepts."
  (let* ((stage1 (if latex-parser-skill-run-replacements
                     (latex-parser-skill-replace-string text)
                   (cons text 0)))
         (run (latex-parser-skill--run-create
               :backend backend
               :system (latex-parser-skill-system-prompt)
               :chunks (latex-parser-skill-split
                        (car stage1) (latex-parser-skill-chunk-size backend))
               :alive t
               :start (current-time)
               :replacements (cdr stage1)
               :callback callback
               :errback (or errback
                            (lambda (msg) (message "latex-parser-skill: %s" msg)))
               :progress progress)))
    (latex-parser-skill-backend-get backend)
    (latex-parser-skill--progress
     run "Stage 1 made %s replacements"
     (or (cdr stage1) "an unknown number of"))
    (latex-parser-skill--next-chunk run 0)
    run))

(defun latex-parser-skill-cancel-run (run)
  "Stop RUN and kill its pending request."
  (when (and run (latex-parser-skill--run-alive run))
    (setf (latex-parser-skill--run-alive run) nil)
    (let ((req (latex-parser-skill--run-request run)))
      (when req
        (funcall (plist-get req :abort))
        (latex-parser-skill-backend-cancel (plist-get req :backend)
                                           (plist-get req :handle))))))

(defun latex-parser-skill-process-string-sync (text &optional backend)
  "Run the pipeline on TEXT and wait for the result.
BACKEND overrides `latex-parser-skill-backend'.  Return a cons of the
LaTeX fragment and the list of violations.  Signal an error on
failure.  This function suits batch use."
  (let (done result failure)
    (latex-parser-skill-process-string
     text
     (lambda (latex violations)
       (setq result (cons latex violations) done t))
     :backend (or backend latex-parser-skill-backend)
     :errback (lambda (msg) (setq failure msg done t))
     :progress (lambda (msg) (message "%s" msg)))
    (while (not done)
      (accept-process-output nil 0.1))
    (when failure (error "latex-parser-skill: %s" failure))
    result))

;;;; Jobs started from commands

(cl-defstruct (latex-parser-skill--job
               (:constructor latex-parser-skill--job-create)
               (:copier nil))
  "A command-level job that knows where the result goes."
  kind buffer beg end original file action run)

(defvar latex-parser-skill--current-job nil
  "The job that is running, or nil.")

(defvar latex-parser-skill--mode-line-string nil
  "Mode-line text shown while a job runs.")
(put 'latex-parser-skill--mode-line-string 'risky-local-variable t)

(defun latex-parser-skill--set-mode-line (text)
  "Show TEXT in the mode line, or remove the indicator when TEXT is nil."
  (setq latex-parser-skill--mode-line-string (and text (concat " " text)))
  (if text
      (unless (memq 'latex-parser-skill--mode-line-string global-mode-string)
        (setq global-mode-string
              (append (or global-mode-string '(""))
                      '(latex-parser-skill--mode-line-string))))
    (setq global-mode-string
          (delq 'latex-parser-skill--mode-line-string global-mode-string)))
  (force-mode-line-update t))

(defun latex-parser-skill--check-buffer-mode ()
  "Signal an error unless the current buffer is in a LaTeX mode."
  (when (and latex-parser-skill-check-mode
             (not (apply #'derived-mode-p latex-parser-skill-modes)))
    (user-error "Not a LaTeX buffer; set `latex-parser-skill-check-mode' to nil to override")))

(defun latex-parser-skill--confirm (text)
  "Ask the questions needed before sending TEXT, and return non-nil to go on."
  (let ((backend latex-parser-skill-backend))
    (and (or (not latex-parser-skill-warn-size)
             (<= (length text) latex-parser-skill-warn-size)
             (y-or-n-p (format "Send %d characters to the model? " (length text))))
         (or (not latex-parser-skill-confirm-remote)
             (not (latex-parser-skill-backend-remote-p backend))
             (memq backend latex-parser-skill--remote-confirmed)
             (when (y-or-n-p (format "Backend %s sends text off this computer.  Continue? "
                                     backend))
               (push backend latex-parser-skill--remote-confirmed)
               t)))))

(defun latex-parser-skill--start (job)
  "Start JOB and remember it as the current job."
  (when (and latex-parser-skill--current-job
             (latex-parser-skill--run-alive
              (latex-parser-skill--job-run latex-parser-skill--current-job)))
    (user-error "A job is already running; cancel it with `latex-parser-skill-cancel'"))
  (let ((text (latex-parser-skill--job-original job)))
    (when (string-empty-p (string-trim text))
      (user-error "There is no text to parse"))
    (when (latex-parser-skill--confirm text)
      (setq latex-parser-skill--current-job job)
      (latex-parser-skill--set-mode-line "LPS[starting]")
      (setf (latex-parser-skill--job-run job)
            (latex-parser-skill-process-string
             text
             (lambda (latex violations)
               (latex-parser-skill--set-mode-line nil)
               (setq latex-parser-skill--current-job nil)
               (latex-parser-skill--deliver job latex violations))
             :errback
             (lambda (msg)
               (latex-parser-skill--set-mode-line nil)
               (setq latex-parser-skill--current-job nil)
               (message "latex-parser-skill failed: %s (see %s)"
                        msg latex-parser-skill-log-buffer-name))
             :progress
             (lambda (msg)
               (latex-parser-skill--set-mode-line
                (format "LPS[%s]" (car (split-string msg " with "))))
               (message "latex-parser-skill: %s" msg))))
      job)))

;;;; Delivery

(defun latex-parser-skill-parsed-file-name (file)
  "Return the output file name for FILE, NAME_parsed.tex beside FILE."
  (concat (file-name-sans-extension file) "_parsed.tex"))

(defun latex-parser-skill--result-buffer (text &optional mode)
  "Show TEXT in a fresh result buffer in MODE and return the buffer."
  (let ((buf (generate-new-buffer "*latex-parser-skill-result*")))
    (with-current-buffer buf
      (insert text)
      (funcall (if (and mode (fboundp mode)) mode #'latex-mode))
      (goto-char (point-min)))
    (pop-to-buffer buf)
    buf))

(defun latex-parser-skill--source-mode (job)
  "Return the major mode of the buffer that JOB came from, or nil."
  (let ((buf (latex-parser-skill--job-buffer job)))
    (and (buffer-live-p buf) (buffer-local-value 'major-mode buf))))

(defun latex-parser-skill--source-intact-p (job)
  "Return non-nil if the source text of JOB is still unchanged."
  (let ((buf (latex-parser-skill--job-buffer job)))
    (and (buffer-live-p buf)
         (with-current-buffer buf
           (equal (buffer-substring-no-properties
                   (latex-parser-skill--job-beg job)
                   (latex-parser-skill--job-end job))
                  (latex-parser-skill--job-original job))))))

(defun latex-parser-skill--write-file (file text)
  "Write TEXT to FILE and return FILE, or nil when the user declines."
  (when (or (not (file-exists-p file))
            (eq latex-parser-skill-overwrite 'always)
            (and (eq latex-parser-skill-overwrite 'ask)
                 (y-or-n-p (format "Overwrite %s? " file))))
    (let ((coding-system-for-write 'utf-8))
      (write-region text nil file nil 'silent))
    file))

(defun latex-parser-skill--deliver (job text violations &optional action)
  "Deliver TEXT for JOB with ACTION, and report VIOLATIONS.
ACTION defaults to the action stored in JOB."
  (let ((action (or action (latex-parser-skill--job-action job))))
    (when (and (eq (latex-parser-skill--job-kind job) 'file)
               (memq action '(replace insert-after)))
      (setq action 'new-buffer))
    (pcase action
      ('preview (latex-parser-skill--show-preview job text violations))
      ((or 'replace 'insert-after)
       (if (not (latex-parser-skill--source-intact-p job))
           (progn
             (message "The source text changed during the request; showing the result in a new buffer")
             (latex-parser-skill--result-buffer
              text (latex-parser-skill--source-mode job)))
         (with-current-buffer (latex-parser-skill--job-buffer job)
           (let ((beg (latex-parser-skill--job-beg job))
                 (end (latex-parser-skill--job-end job)))
             (atomic-change-group
               (save-excursion
                 (if (eq action 'replace)
                     (progn (goto-char beg)
                            (delete-region beg end)
                            (insert text))
                   (goto-char end)
                   (insert "\n\n" text))))))))
      ('file
       (let* ((src (or (latex-parser-skill--job-file job)
                       (let ((buf (latex-parser-skill--job-buffer job)))
                         (and (buffer-live-p buf) (buffer-file-name buf)))))
              (out (and src (latex-parser-skill--write-file
                             (latex-parser-skill-parsed-file-name src) text))))
         (if out
             (message "Wrote %s" out)
           (latex-parser-skill--result-buffer
            text (latex-parser-skill--source-mode job)))))
      (_ (latex-parser-skill--result-buffer
          text (latex-parser-skill--source-mode job))))
    (unless (eq action 'preview)
      (latex-parser-skill--maybe-report violations job))
    (run-hook-with-args 'latex-parser-skill-finished-hook text violations)))

;;;; Report

(defvar-local latex-parser-skill--report-source nil
  "Cons of (BUFFER . FIRST-LINE) that report lines point into.")

(define-derived-mode latex-parser-skill-report-mode special-mode "LPS-Report"
  "Major mode for the latex-parser-skill verification report.")

(defun latex-parser-skill--jump (line)
  "Jump to LINE of the report source."
  (let ((src latex-parser-skill--report-source))
    (when (and src (buffer-live-p (car src)))
      (pop-to-buffer (car src))
      (goto-char (point-min))
      (forward-line (+ (cdr src) line -2)))))

(defun latex-parser-skill-show-report (violations &optional buffer first-line)
  "Show VIOLATIONS in the report buffer.
BUFFER and FIRST-LINE say where line 1 of the checked text lies, so
that each entry can jump there."
  (let ((rep (get-buffer-create "*latex-parser-skill-report*")))
    (with-current-buffer rep
      (let ((inhibit-read-only t))
        (erase-buffer)
        (latex-parser-skill-report-mode)
        (setq latex-parser-skill--report-source
              (and buffer (cons buffer (or first-line 1))))
        (if (null violations)
            (insert "No violations found.\n")
          (insert (format "%d violations (%d errors)\n\n"
                          (length violations)
                          (length (latex-parser-skill-violation-errors violations))))
          (dolist (v violations)
            (let ((line (plist-get v :line)))
              (if buffer
                  (insert-text-button
                   (format "line %d" line)
                   'action (lambda (_b) (latex-parser-skill--jump line))
                   'follow-link t)
                (insert (format "line %d" line)))
              (insert (format " [%s] %s\n" (plist-get v :level)
                              (plist-get v :message))))))
        (goto-char (point-min))))
    (display-buffer rep)
    rep))

(defun latex-parser-skill--maybe-report (violations job)
  "Show VIOLATIONS for JOB as `latex-parser-skill-show-report' directs."
  (let ((errors (latex-parser-skill-violation-errors violations)))
    (message "latex-parser-skill: done, %d errors and %d warnings"
             (length errors) (- (length violations) (length errors)))
    (when (or (eq latex-parser-skill-show-report 'always)
              (and (eq latex-parser-skill-show-report 'errors) errors))
      (latex-parser-skill-show-report violations)
      (ignore job))))

;;;; Preview

(defvar-local latex-parser-skill--preview-job nil
  "Job whose result the preview buffer holds.")

(defvar latex-parser-skill-preview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'latex-parser-skill-preview-accept)
    (define-key map (kbd "C-c C-k") #'latex-parser-skill-preview-reject)
    (define-key map (kbd "C-c C-d") #'latex-parser-skill-preview-diff)
    (define-key map (kbd "C-c C-v") #'latex-parser-skill-verify-buffer)
    map)
  "Keymap for `latex-parser-skill-preview-mode'.")

(define-minor-mode latex-parser-skill-preview-mode
  "Minor mode for reviewing a parsed result before it is used.
\\<latex-parser-skill-preview-mode-map>\
Press \\[latex-parser-skill-preview-accept] to accept, \
\\[latex-parser-skill-preview-reject] to reject, and \
\\[latex-parser-skill-preview-diff] to compare with the source."
  :lighter " LPS-Preview"
  :keymap latex-parser-skill-preview-mode-map
  (when latex-parser-skill-preview-mode
    (setq header-line-format
          (substitute-command-keys
           "\\<latex-parser-skill-preview-mode-map>Accept: \\[latex-parser-skill-preview-accept]   Reject: \\[latex-parser-skill-preview-reject]   Diff: \\[latex-parser-skill-preview-diff]   Verify: \\[latex-parser-skill-verify-buffer]"))))

(defun latex-parser-skill--show-preview (job text violations)
  "Show TEXT for JOB in the preview buffer and report VIOLATIONS."
  (let ((buf (get-buffer-create "*latex-parser-skill-preview*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text))
      (let ((mode (latex-parser-skill--source-mode job)))
        (funcall (if (and mode (fboundp mode)) mode #'latex-mode)))
      (setq latex-parser-skill--preview-job job)
      (latex-parser-skill-preview-mode 1)
      (set-buffer-modified-p nil)
      (goto-char (point-min)))
    (pop-to-buffer buf)
    (latex-parser-skill--maybe-report violations job)
    buf))

(defun latex-parser-skill-preview-accept ()
  "Use the text of the preview buffer, including any edits."
  (interactive)
  (let ((job latex-parser-skill--preview-job)
        (text (buffer-string))
        (buf (current-buffer)))
    (unless job (user-error "This buffer is not a latex-parser-skill preview"))
    (quit-window nil)
    (kill-buffer buf)
    (latex-parser-skill--deliver
     job text nil
     (if (eq (latex-parser-skill--job-kind job) 'file) 'file 'replace))))

(defun latex-parser-skill-preview-reject ()
  "Discard the preview and leave the source unchanged."
  (interactive)
  (let ((buf (current-buffer)))
    (quit-window nil)
    (kill-buffer buf)
    (message "Result discarded")))

(defun latex-parser-skill-preview-diff ()
  "Show a diff between the source text and the preview."
  (interactive)
  (require 'diff)
  (let* ((job latex-parser-skill--preview-job)
         (old (generate-new-buffer " *latex-parser-skill-original*")))
    (unless job (user-error "This buffer is not a latex-parser-skill preview"))
    (with-current-buffer old (insert (latex-parser-skill--job-original job)))
    (display-buffer (diff-no-select old (current-buffer) "-u" t))))

;;;; Commands

(defun latex-parser-skill--body-bounds ()
  "Return a cons of the document body bounds, or of the whole buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((beg (and latex-parser-skill-buffer-body-only
                    (re-search-forward "^[ \t]*\\\\begin{document}.*\n" nil t)))
          (end (and latex-parser-skill-buffer-body-only
                    (save-excursion
                      (goto-char (point-max))
                      (re-search-backward "^[ \t]*\\\\end{document}" nil t)))))
      (if (and beg end (< beg end))
          (cons beg end)
        (cons (point-min) (point-max))))))

(defun latex-parser-skill--make-job (kind beg end)
  "Return a job of KIND for the text between BEG and END of this buffer."
  (latex-parser-skill--job-create
   :kind kind
   :buffer (current-buffer)
   :beg (copy-marker beg)
   :end (copy-marker end t)
   :original (buffer-substring-no-properties beg end)
   :action latex-parser-skill-output-action))

;;;###autoload
(defun latex-parser-skill-region (beg end)
  "Parse the text between BEG and END with the transcript-parser skill."
  (interactive "r")
  (unless (use-region-p)
    (user-error "No active region"))
  (latex-parser-skill--check-buffer-mode)
  (deactivate-mark)
  (latex-parser-skill--start (latex-parser-skill--make-job 'region beg end)))

;;;###autoload
(defun latex-parser-skill-buffer ()
  "Parse the whole buffer, or only its document body.
See `latex-parser-skill-buffer-body-only'."
  (interactive)
  (latex-parser-skill--check-buffer-mode)
  (let ((bounds (latex-parser-skill--body-bounds)))
    (latex-parser-skill--start
     (latex-parser-skill--make-job 'buffer (car bounds) (cdr bounds)))))

;;;###autoload
(defun latex-parser-skill-dwim ()
  "Parse the active region, or the buffer when no region is active."
  (interactive)
  (if (use-region-p)
      (latex-parser-skill-region (region-beginning) (region-end))
    (latex-parser-skill-buffer)))

;;;###autoload
(defun latex-parser-skill-file (file)
  "Parse FILE and deliver the result.
`latex-parser-skill-file-output-action' chooses the delivery.
By default the result is written to NAME_parsed.tex beside FILE."
  (interactive (list (read-file-name "Transcript file: " nil nil t)))
  (let ((file (expand-file-name file)))
    (latex-parser-skill--start
     (latex-parser-skill--job-create
      :kind 'file
      :file file
      :original (with-temp-buffer
                  (let ((coding-system-for-read 'utf-8))
                    (insert-file-contents file))
                  (buffer-string))
      :action latex-parser-skill-file-output-action))))

;;;###autoload
(defun latex-parser-skill-verify-buffer ()
  "Verify the region or the buffer with the Stage 3 rules and show a report."
  (interactive)
  (let* ((bounds (if (use-region-p)
                     (cons (region-beginning) (region-end))
                   (latex-parser-skill--body-bounds)))
         (violations (latex-parser-skill-verify-string
                      (buffer-substring-no-properties (car bounds) (cdr bounds)))))
    (latex-parser-skill-show-report violations (current-buffer)
                                    (line-number-at-pos (car bounds)))
    violations))

;;;###autoload
(defun latex-parser-skill-select-backend (backend)
  "Set `latex-parser-skill-backend' to BACKEND for this session."
  (interactive
   (list (intern
          (completing-read
           "Backend: "
           (mapcar (lambda (b)
                     (concat (symbol-name (car b)) "  "
                             (or (plist-get (cdr b) :description) "")))
                   latex-parser-skill-backends)
           nil t))))
  (let ((name (intern (car (split-string (symbol-name backend) " " t)))))
    (latex-parser-skill-backend-get name)
    (setq latex-parser-skill-backend name)
    (message "latex-parser-skill now uses %s" name)
    name))

;;;###autoload
(defun latex-parser-skill-cancel ()
  "Cancel the running job."
  (interactive)
  (if (not latex-parser-skill--current-job)
      (message "No job is running")
    (latex-parser-skill-cancel-run
     (latex-parser-skill--job-run latex-parser-skill--current-job))
    (setq latex-parser-skill--current-job nil)
    (latex-parser-skill--set-mode-line nil)
    (latex-parser-skill-log "Cancelled by user")
    (message "latex-parser-skill job cancelled")))

;;;###autoload
(defun latex-parser-skill-show-log ()
  "Show the log buffer."
  (interactive)
  (display-buffer (get-buffer-create latex-parser-skill-log-buffer-name)))

;;;###autoload
(defun latex-parser-skill-insert-preamble ()
  "Insert the preamble lines that the parsed output needs.
The lines go before \\begin{document} when the buffer has one, and
at point otherwise.  Lines that are already present are skipped."
  (interactive)
  (let* ((missing (seq-remove
                   (lambda (line)
                     (save-excursion
                       (goto-char (point-min))
                       (search-forward line nil t)))
                   latex-parser-skill-preamble-lines))
         (pos (save-excursion
                (goto-char (point-min))
                (when (re-search-forward "^[ \t]*\\\\begin{document}" nil t)
                  (line-beginning-position)))))
    (if (null missing)
        (message "The preamble already has every line")
      (save-excursion
        (when pos (goto-char pos))
        (unless (bolp) (insert "\n"))
        (insert (mapconcat #'identity missing "\n") "\n"))
      (message "Inserted %d preamble lines" (length missing)))))

;;;; Batch use

(defun latex-parser-skill-batch ()
  "Parse each file named in `command-line-args-left' and write NAME_parsed.tex.
Run it from the shell with the `emacs' program as follows.

  `emacs' --batch -L DIR -l latex-parser-skill \\
        -f latex-parser-skill-batch notes.txt"
  (let ((latex-parser-skill-overwrite 'always))
    (dolist (file command-line-args-left)
      (let* ((text (with-temp-buffer
                     (let ((coding-system-for-read 'utf-8))
                       (insert-file-contents file))
                     (buffer-string)))
             (result (latex-parser-skill-process-string-sync text))
             (out (latex-parser-skill-parsed-file-name file)))
        (latex-parser-skill--write-file out (car result))
        (message "Wrote %s (%d violations)" out (length (cdr result)))))
    (setq command-line-args-left nil)))

;;;; Key bindings and menu

;;;###autoload (autoload 'latex-parser-skill-menu "latex-parser-skill" nil t)
(transient-define-prefix latex-parser-skill-menu ()
  "Menu of latex-parser-skill commands."
  [["Parse"
    ("r" "Region" latex-parser-skill-region)
    ("b" "Buffer" latex-parser-skill-buffer)
    ("f" "File" latex-parser-skill-file)
    ("d" "Region or buffer" latex-parser-skill-dwim)]
   ["Check"
    ("v" "Verify" latex-parser-skill-verify-buffer)
    ("p" "Insert preamble lines" latex-parser-skill-insert-preamble)
    ("s" "Stage 1 only on region" latex-parser-skill-replace-region)]
   ["Control"
    ("m" "Select backend" latex-parser-skill-select-backend)
    ("k" "Cancel job" latex-parser-skill-cancel)
    ("l" "Show log" latex-parser-skill-show-log)]])

;;;###autoload (autoload 'latex-parser-skill-command-map "latex-parser-skill" nil t 'keymap)
(defvar latex-parser-skill-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "r" #'latex-parser-skill-region)
    (define-key map "b" #'latex-parser-skill-buffer)
    (define-key map "f" #'latex-parser-skill-file)
    (define-key map "d" #'latex-parser-skill-dwim)
    (define-key map "v" #'latex-parser-skill-verify-buffer)
    (define-key map "m" #'latex-parser-skill-select-backend)
    (define-key map "k" #'latex-parser-skill-cancel)
    (define-key map "l" #'latex-parser-skill-show-log)
    (define-key map "p" #'latex-parser-skill-insert-preamble)
    (define-key map "s" #'latex-parser-skill-replace-region)
    (define-key map "t" #'latex-parser-skill-menu)
    map)
  "Prefix keymap for latex-parser-skill commands.
Bind it under a prefix of your choice.  The README suggests the
key sequence that starts with \\`C-c t'.")
(fset 'latex-parser-skill-command-map latex-parser-skill-command-map)

(provide 'latex-parser-skill)
;;; latex-parser-skill.el ends here
