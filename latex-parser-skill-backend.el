;;; latex-parser-skill-backend.el --- Model backends for latex-parser-skill -*- lexical-binding: t; -*-

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

;; A backend sends a system prompt and a user message to a language
;; model and calls back with the reply.  Every backend is
;; asynchronous.  The built-in backends are
;;
;;   claude-code        the claude command-line program in print mode
;;   anthropic-api      the Claude Messages API over HTTPS
;;   openai-compatible  any /v1/chat/completions server, such as
;;                      Ollama, llama.cpp, LM Studio or vLLM
;;   gptel              the gptel package, when it is installed
;;
;; A new backend is added with `latex-parser-skill-register-backend'.

;;; Code:

(require 'auth-source)
(require 'json)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'latex-parser-skill-common)

(defvar url-http-end-of-headers)
(defvar gptel-backend)
(defvar gptel-model)
(declare-function gptel-request "ext:gptel")
(declare-function gptel-abort "ext:gptel")

(defgroup latex-parser-skill-backend nil
  "Model backends for latex-parser-skill."
  :group 'latex-parser-skill
  :prefix "latex-parser-skill-")

;;;; Prompt

(defcustom latex-parser-skill-prompt-file
  (latex-parser-skill-data-file "prompts/transcript-parser.md")
  "File that holds the transcript-parser instructions.
The default is the copy bundled with the package.  It may also point
to an installed SKILL.md file, in which case its YAML front matter is
removed before use."
  :type 'file
  :group 'latex-parser-skill-backend)

(defconst latex-parser-skill-output-contract
  "## Output contract for this request

The transcript arrives in the user message, not as a file path.
Do not read or write any file.
Reply with the LaTeX fragment only.
Do not wrap it in a code fence and do not add any comment before or after it."
  "Text appended to the skill instructions for every request.")

(defun latex-parser-skill-system-prompt ()
  "Return the system prompt built from `latex-parser-skill-prompt-file'."
  (unless (file-readable-p latex-parser-skill-prompt-file)
    (user-error "Cannot read prompt file %s" latex-parser-skill-prompt-file))
  (let ((text (with-temp-buffer
                (let ((coding-system-for-read 'utf-8))
                  (insert-file-contents latex-parser-skill-prompt-file))
                (buffer-string))))
    (when (string-match "\\`---\n\\(?:.\\|\n\\)*?\n---\n" text)
      (setq text (substring text (match-end 0))))
    (concat (string-trim text) "\n\n" latex-parser-skill-output-contract "\n")))

(defconst latex-parser-skill-parse-instruction
  "Parse the following transcript according to your instructions."
  "Instruction placed before the transcript in a parse request.")

(defconst latex-parser-skill-repair-instruction
  "The LaTeX fragment below was produced from a transcript, but it breaks these rules of your instructions."
  "Instruction placed before the violation list in a repair request.")

(defun latex-parser-skill-parse-message (text)
  "Return the user message that asks the model to parse TEXT."
  (concat latex-parser-skill-parse-instruction "\n\n" text))

(defun latex-parser-skill-repair-message (latex report)
  "Return the user message that asks the model to repair LATEX.
REPORT lists the violations, one per line."
  (concat latex-parser-skill-repair-instruction "\n\n" report
          "\n\nReturn the whole corrected fragment and change nothing else."
          "\n\n" latex))

;;;; Shared options

(defcustom latex-parser-skill-timeout 600
  "Seconds to wait for a backend reply before giving up."
  :type 'integer
  :group 'latex-parser-skill-backend)

(defcustom latex-parser-skill-max-tokens 16000
  "Largest number of tokens a backend may return, where supported."
  :type 'integer
  :group 'latex-parser-skill-backend)

(defcustom latex-parser-skill-temperature 0
  "Sampling temperature sent to HTTP backends."
  :type 'number
  :group 'latex-parser-skill-backend)

;;;; Registry

(defvar latex-parser-skill-backends nil
  "Alist of registered backends.
Each element is (NAME . PLIST).  PLIST keys are :request, :remote,
:cancel and :description.")

(defun latex-parser-skill-register-backend (name &rest plist)
  "Register backend NAME with the properties in PLIST.
:request is a function of SYSTEM, TEXT, CALLBACK and ERRBACK.  It
starts the request and returns a handle.  CALLBACK receives the reply
string and ERRBACK receives an error message string.

:remote is t, nil, or a function of no arguments.  A non-nil value
means that text leaves the computer.

:cancel is an optional function of the handle.  The default kills a
process or a buffer.

:description is a short string shown during selection."
  (setf (alist-get name latex-parser-skill-backends) plist)
  name)

(defun latex-parser-skill-backend-get (name)
  "Return the property list of backend NAME, or signal an error."
  (or (alist-get name latex-parser-skill-backends)
      (user-error "Unknown backend %s" name)))

(defun latex-parser-skill-backend-remote-p (name)
  "Return non-nil if backend NAME sends text off the computer."
  (let ((remote (plist-get (latex-parser-skill-backend-get name) :remote)))
    (if (functionp remote) (funcall remote) remote)))

(defun latex-parser-skill-backend-request (name system text callback errback)
  "Send the system prompt SYSTEM and the user message TEXT to backend NAME.
CALLBACK receives the reply and ERRBACK receives an error message.
Return a handle for `latex-parser-skill-backend-cancel'.  A timer
cancels the request after `latex-parser-skill-timeout' seconds."
  (let* ((fn (plist-get (latex-parser-skill-backend-get name) :request))
         (finished nil)
         (timer nil)
         (handle nil)
         (done (lambda (f arg)
                 (unless finished
                   (setq finished t)
                   (when timer (cancel-timer timer))
                   (funcall f arg)))))
    (setq handle (funcall fn system text
                          (lambda (reply) (funcall done callback reply))
                          (lambda (msg) (funcall done errback msg))))
    (unless finished
      (setq timer
            (run-at-time latex-parser-skill-timeout nil
                         (lambda ()
                           (unless finished
                             (funcall done errback
                                      (format "No reply after %d seconds"
                                              latex-parser-skill-timeout))
                             (latex-parser-skill-backend-cancel name handle))))))
    (list :backend name :handle handle
          :abort (lambda () (setq finished t) (when timer (cancel-timer timer))))))

(defun latex-parser-skill-backend-cancel (name handle)
  "Cancel HANDLE that backend NAME returned."
  (let ((cancel (plist-get (alist-get name latex-parser-skill-backends) :cancel)))
    (cond
     (cancel (funcall cancel handle))
     ((processp handle)
      (when (process-live-p handle) (delete-process handle)))
     ((bufferp handle)
      (when (buffer-live-p handle)
        (let ((proc (get-buffer-process handle)))
          (when proc (delete-process proc)))
        (kill-buffer handle))))))

;;;; claude-code backend

(defcustom latex-parser-skill-claude-executable "claude"
  "Name or path of the Claude Code command-line program."
  :type 'string
  :group 'latex-parser-skill-backend)

(defcustom latex-parser-skill-claude-model nil
  "Model for the claude-code backend, or nil for the program default.
An alias such as \"sonnet\" or \"opus\" or a full model name works."
  :type '(choice (const :tag "Program default" nil) string)
  :group 'latex-parser-skill-backend)

(defcustom latex-parser-skill-claude-prompt-source 'bundled
  "Where the claude-code backend gets its instructions.
The value bundled sends the prompt from `latex-parser-skill-prompt-file'
as the system prompt and turns off every tool.  The value skill relies
on a transcript-parser skill installed for Claude Code."
  :type '(choice (const :tag "Bundled prompt" bundled)
                 (const :tag "Installed skill" skill))
  :group 'latex-parser-skill-backend)

(defcustom latex-parser-skill-claude-extra-args nil
  "Extra arguments added to every claude command line."
  :type '(repeat string)
  :group 'latex-parser-skill-backend)

(defconst latex-parser-skill-claude-skill-instruction
  "Use the transcript-parser skill to carry out the request on standard input. Reply with the LaTeX fragment only, without a code fence, and do not write any file."
  "Instruction used when `latex-parser-skill-claude-prompt-source' is skill.")

(defconst latex-parser-skill-claude-stdin-instruction
  "Carry out the request on standard input."
  "Instruction used when `latex-parser-skill-claude-prompt-source' is bundled.")

(defun latex-parser-skill-claude-command (system)
  "Return the claude command line as a list for the system prompt SYSTEM."
  (append
   (list latex-parser-skill-claude-executable "-p")
   (if (eq latex-parser-skill-claude-prompt-source 'skill)
       (list latex-parser-skill-claude-skill-instruction
             "--append-system-prompt" latex-parser-skill-output-contract
             "--max-turns" "5")
     (list latex-parser-skill-claude-stdin-instruction
           "--system-prompt" system
           "--tools" ""))
   (list "--output-format" "text" "--no-session-persistence")
   (when latex-parser-skill-claude-model
     (list "--model" latex-parser-skill-claude-model))
   latex-parser-skill-claude-extra-args))

(defun latex-parser-skill--claude-request (system text callback errback)
  "Run the claude program with SYSTEM and TEXT on standard input.
Call CALLBACK with standard output on success, or ERRBACK."
  (unless (executable-find latex-parser-skill-claude-executable)
    (user-error "Cannot find %s; install Claude Code or change the backend"
                latex-parser-skill-claude-executable))
  (let* ((out (generate-new-buffer " *latex-parser-skill-claude*"))
         (err (generate-new-buffer " *latex-parser-skill-claude-err*"))
         (default-directory temporary-file-directory)
         (proc
          (make-process
           :name "latex-parser-skill-claude"
           :buffer out
           :stderr err
           :command (latex-parser-skill-claude-command system)
           :coding 'utf-8
           :connection-type 'pipe
           :noquery t
           :sentinel
           (lambda (p _event)
             (unless (process-live-p p)
               (let ((status (process-exit-status p))
                     (reply (if (buffer-live-p out)
                                (with-current-buffer out (buffer-string))
                              ""))
                     (msg (if (buffer-live-p err)
                              (with-current-buffer err
                                (string-trim (buffer-string)))
                            "")))
                 (when (buffer-live-p out) (kill-buffer out))
                 (when (buffer-live-p err) (kill-buffer err))
                 (if (and (eq (process-status p) 'exit) (eq status 0))
                     (funcall callback reply)
                   (funcall errback
                            (format "claude exited with status %s: %s"
                                    status msg)))))))))
    (process-send-string proc text)
    (process-send-eof proc)
    proc))

(latex-parser-skill-register-backend
 'claude-code
 :request #'latex-parser-skill--claude-request
 :remote t
 :description "Claude Code command-line program (frontier model)")

;;;; HTTP helpers

(defun latex-parser-skill--http-parse ()
  "Parse the HTTP response in the current buffer.
Return a cons of the status code and the decoded JSON body."
  (goto-char (point-min))
  (let ((code (and (looking-at "HTTP/[0-9.]+ \\([0-9]+\\)")
                   (string-to-number (match-string 1)))))
    (goto-char (if (and (boundp 'url-http-end-of-headers)
                        (number-or-marker-p url-http-end-of-headers))
                   url-http-end-of-headers
                 (or (re-search-forward "\r?\n\r?\n" nil t) (point-min))))
    (let* ((body (decode-coding-string
                  (buffer-substring-no-properties (point) (point-max)) 'utf-8))
           (json (condition-case nil
                     (let ((json-object-type 'alist)
                           (json-array-type 'list)
                           (json-key-type 'symbol))
                       (json-read-from-string body))
                   (error nil))))
      (cons code json))))

(defun latex-parser-skill--http-post (url headers payload extract callback errback)
  "POST PAYLOAD as JSON to URL with HEADERS.
EXTRACT is a function of the decoded JSON that returns the reply
text.  Call CALLBACK with that text, or ERRBACK with a message.
Return the retrieval buffer."
  (let ((url-request-method "POST")
        (url-request-extra-headers
         (cons '("Content-Type" . "application/json") headers))
        (url-request-data
         (encode-coding-string (json-encode payload) 'utf-8)))
    (url-retrieve
     url
     (lambda (status)
       (let ((buf (current-buffer)))
         (unwind-protect
             (let* ((parsed (latex-parser-skill--http-parse))
                    (code (car parsed))
                    (json (cdr parsed))
                    (text (and json (ignore-errors (funcall extract json)))))
               (cond
                ((and code (>= code 200) (< code 300) (stringp text))
                 (funcall callback text))
                (t
                 (funcall errback
                          (format "HTTP %s from %s: %s"
                                  (or code "error") url
                                  (or (and json (latex-parser-skill--json-error json))
                                      (plist-get status :error)
                                      "no usable reply"))))))
           (when (buffer-live-p buf) (kill-buffer buf)))))
     nil t t)))

(defun latex-parser-skill--json-error (json)
  "Return an error message from the decoded JSON reply, or nil."
  (let ((err (alist-get 'error json)))
    (cond ((stringp err) err)
          ((consp err) (or (alist-get 'message err) (format "%S" err))))))

(defun latex-parser-skill--auth-secret (host)
  "Return the secret stored in auth-source for HOST, or nil."
  (let ((secret (auth-source-pick-first-password :host host)))
    (if (functionp secret) (funcall secret) secret)))

;;;; anthropic-api backend

(defcustom latex-parser-skill-anthropic-model "claude-sonnet-5-5"
  "Model name for the anthropic-api backend."
  :type 'string
  :group 'latex-parser-skill-backend)

(defcustom latex-parser-skill-anthropic-url "https://api.anthropic.com/v1/messages"
  "Endpoint of the Claude Messages API."
  :type 'string
  :group 'latex-parser-skill-backend)

(defun latex-parser-skill--anthropic-key ()
  "Return the Claude API key from auth-source or the environment."
  (or (latex-parser-skill--auth-secret "api.anthropic.com")
      (getenv "ANTHROPIC_API_KEY")
      (user-error "No API key: add api.anthropic.com to auth-source or set ANTHROPIC_API_KEY")))

(defun latex-parser-skill-anthropic-payload (system text)
  "Return the Messages API request body for SYSTEM and TEXT."
  `((model . ,latex-parser-skill-anthropic-model)
    (max_tokens . ,latex-parser-skill-max-tokens)
    (temperature . ,latex-parser-skill-temperature)
    (system . ,system)
    (messages . [((role . "user")
                  (content . ,text))])))

(defun latex-parser-skill-anthropic-extract (json)
  "Return the text blocks of the Messages API reply JSON joined together."
  (mapconcat (lambda (block)
               (if (equal (alist-get 'type block) "text")
                   (alist-get 'text block)
                 ""))
             (alist-get 'content json) ""))

(defun latex-parser-skill--anthropic-request (system text callback errback)
  "Send SYSTEM and TEXT to the Messages API.
Call CALLBACK with the reply or ERRBACK with a message."
  (latex-parser-skill--http-post
   latex-parser-skill-anthropic-url
   `(("x-api-key" . ,(latex-parser-skill--anthropic-key))
     ("anthropic-version" . "2023-06-01"))
   (latex-parser-skill-anthropic-payload system text)
   #'latex-parser-skill-anthropic-extract
   callback errback))

(latex-parser-skill-register-backend
 'anthropic-api
 :request #'latex-parser-skill--anthropic-request
 :remote t
 :description "Claude Messages API with an API key (frontier model)")

;;;; openai-compatible backend

(defcustom latex-parser-skill-openai-url
  "http://localhost:11434/v1/chat/completions"
  "Chat completions endpoint for the openai-compatible backend.
The default is the Ollama server on this computer."
  :type 'string
  :group 'latex-parser-skill-backend)

(defcustom latex-parser-skill-openai-model nil
  "Model name for the openai-compatible backend, such as an Ollama tag."
  :type '(choice (const :tag "Unset" nil) string)
  :group 'latex-parser-skill-backend)

(defun latex-parser-skill--url-host (url)
  "Return the host part of URL."
  (url-host (url-generic-parse-url url)))

(defun latex-parser-skill-openai-remote-p ()
  "Return non-nil if `latex-parser-skill-openai-url' is not on this computer."
  (not (member (latex-parser-skill--url-host latex-parser-skill-openai-url)
               '("localhost" "127.0.0.1" "::1" "[::1]"))))

(defun latex-parser-skill-openai-payload (system text)
  "Return the chat completions request body for SYSTEM and TEXT."
  (unless latex-parser-skill-openai-model
    (user-error "Set `latex-parser-skill-openai-model' to a model your server provides"))
  `((model . ,latex-parser-skill-openai-model)
    (temperature . ,latex-parser-skill-temperature)
    (max_tokens . ,latex-parser-skill-max-tokens)
    (stream . :json-false)
    (messages . [((role . "system") (content . ,system))
                 ((role . "user")
                  (content . ,text))])))

(defun latex-parser-skill-openai-extract (json)
  "Return the message content of the first choice in JSON."
  (let ((choice (car (alist-get 'choices json))))
    (alist-get 'content (alist-get 'message choice))))

(defun latex-parser-skill--openai-request (system text callback errback)
  "Send SYSTEM and TEXT to a chat completions server.
Call CALLBACK with the reply or ERRBACK with a message."
  (let* ((payload (latex-parser-skill-openai-payload system text))
         (key (latex-parser-skill--auth-secret
               (latex-parser-skill--url-host latex-parser-skill-openai-url))))
    (latex-parser-skill--http-post
     latex-parser-skill-openai-url
     (when key `(("Authorization" . ,(concat "Bearer " key))))
     payload
     #'latex-parser-skill-openai-extract
     callback errback)))

(latex-parser-skill-register-backend
 'openai-compatible
 :request #'latex-parser-skill--openai-request
 :remote #'latex-parser-skill-openai-remote-p
 :description "Ollama, llama.cpp, LM Studio or vLLM (local model)")

;;;; gptel backend

(defcustom latex-parser-skill-gptel-backend nil
  "Backend object for the gptel backend, or nil for `gptel-backend'."
  :type '(choice (const :tag "Use gptel-backend" nil) sexp)
  :group 'latex-parser-skill-backend)

(defcustom latex-parser-skill-gptel-model nil
  "Model symbol for the gptel backend, or nil for `gptel-model'."
  :type '(choice (const :tag "Use gptel-model" nil) symbol)
  :group 'latex-parser-skill-backend)

(defcustom latex-parser-skill-gptel-remote t
  "Whether the gptel backend counts as sending text off the computer."
  :type 'boolean
  :group 'latex-parser-skill-backend)

(defun latex-parser-skill--gptel-request (system text callback errback)
  "Send SYSTEM and TEXT through `gptel-request'.
Call CALLBACK with the reply or ERRBACK with a message.  Return the
buffer that the request runs in."
  (unless (require 'gptel nil t)
    (user-error "The gptel backend needs the gptel package"))
  (let ((buf (generate-new-buffer " *latex-parser-skill-gptel*"))
        (gptel-backend (or latex-parser-skill-gptel-backend gptel-backend))
        (gptel-model (or latex-parser-skill-gptel-model gptel-model))
        (chunks nil))
    (gptel-request text
                   :system system
                   :buffer buf
                   :stream nil
                   :callback
                   (lambda (response info)
                     (cond
                      ((stringp response)
                       (push response chunks)
                       (funcall callback (apply #'concat (nreverse chunks)))
                       (when (buffer-live-p buf) (kill-buffer buf)))
                      ((null response)
                       (funcall errback (format "gptel error: %s"
                                                (or (plist-get info :status) "no reply")))
                       (when (buffer-live-p buf) (kill-buffer buf)))
                      ;; Reasoning blocks and tool calls arrive as conses; ignore them.
                      (t nil))))
    buf))

(defun latex-parser-skill--gptel-cancel (buf)
  "Abort the gptel request that belongs to BUF."
  (when (buffer-live-p buf)
    (when (fboundp 'gptel-abort) (ignore-errors (gptel-abort buf)))
    (kill-buffer buf)))

(latex-parser-skill-register-backend
 'gptel
 :request #'latex-parser-skill--gptel-request
 :cancel #'latex-parser-skill--gptel-cancel
 :remote (lambda () latex-parser-skill-gptel-remote)
 :description "Any model already configured in gptel")

(provide 'latex-parser-skill-backend)
;;; latex-parser-skill-backend.el ends here
