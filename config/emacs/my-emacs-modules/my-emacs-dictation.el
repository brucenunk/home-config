;;; my-emacs-dictation.el --- Voice dictation insertion -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Record a short voice note with the standalone Josip recorder helper,
;; transcribe it through a configured OpenAI-compatible endpoint, and insert the
;; resulting text at point.
;;
;; In ordinary Emacs buffers, `my/dictation-insert' inserts the transcript at
;; point.  In Ghostel terminal buffers, it uses `ghostel-paste-string' so
;; terminal applications such as Pi receive the transcript as paste input rather
;; than as edits to the terminal render buffer.
;;
;; User flow:
;;   - Run `my/dictation-insert', or press C-;.
;;   - Speak while recording is active.
;;   - Press RET to stop recording and transcribe.
;;   - Press ESC to cancel recording.
;;
;; This module owns dictation UI, temporary file cleanup, audio validation,
;; transcription, and text delivery.  Josip owns only microphone permission, raw
;; WAV capture, and the stop/ready-file recorder handshake documented in
;; swift/josip/README.md.
;;
;; Commands:
;;   - my/dictation-insert — record, transcribe, and insert dictation at point.
;;
;; Key bindings:
;;   - C-; — run `my/dictation-insert'.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'url)
(require 'url-http)

(defvar url-http-response-status)

(declare-function ghostel-paste-string "ghostel" (string))

(defvar ghostel-char-mode-map)
(defvar ghostel-readonly-mode-map)

(defgroup my-dictation nil
  "Voice dictation insertion."
  :group 'editing)

(defcustom my/dictation-recorder-program "josip"
  "Recorder program used for microphone capture.
The program must implement Josip's flag-based recorder contract."
  :type 'string
  :group 'my-dictation)

(defcustom my/dictation-transcription-base-url
  nil
  "Base URL for the OpenAI-compatible transcription endpoint."
  :type '(choice (const :tag "Not configured" nil) string)
  :group 'my-dictation)

(defcustom my/dictation-transcription-api-key "dummy-key-not-required"
  "Bearer token for `my/dictation-transcription-base-url'."
  :type 'string
  :group 'my-dictation)

(defcustom my/dictation-transcription-model "gpt-4o-mini-transcribe"
  "Audio transcription model sent to the transcription endpoint."
  :type 'string
  :group 'my-dictation)

(defcustom my/dictation-max-recording-seconds 90
  "Maximum recording duration in seconds.
Josip independently rejects values above 90 seconds."
  :type 'integer
  :group 'my-dictation)

(defcustom my/dictation-transcription-timeout-seconds 60
  "Timeout in seconds for transcription requests."
  :type 'integer
  :group 'my-dictation)

(defcustom my/dictation-recorder-ready-timeout-seconds 35
  "Timeout in seconds while waiting for Josip to start recording."
  :type 'integer
  :group 'my-dictation)

(defcustom my/dictation-insert-key "C-;"
  "Key sequence bound to `my/dictation-insert'."
  :type 'key-sequence
  :group 'my-dictation)

(defconst my/dictation--min-audio-bytes 1024)
(defconst my/dictation--min-recording-seconds 0.7)
(defconst my/dictation--min-max-amplitude 0.001)
(defconst my/dictation--response-excerpt-chars 500)

(defun my/dictation--recorder-argv (audio-file stop-file ready-file)
  "Return Josip recorder arguments for AUDIO-FILE, STOP-FILE, and READY-FILE."
  (list "--output" audio-file
        "--max-duration" (number-to-string my/dictation-max-recording-seconds)
        "--stop-file" stop-file
        "--ready-file" ready-file))

(defun my/dictation--process-stderr (process)
  "Return captured stderr text for PROCESS."
  (when-let ((buffer (process-get process 'stderr-buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (string-trim (buffer-string))))))

(defun my/dictation--recorder-error-message (error &optional stderr)
  "Return user-facing recorder message for ERROR and STDERR."
  (let ((detail (string-trim (or stderr ""))))
    (cond
     ((and (listp error) (memq (car error) '(file-error error)))
      (format "Could not start dictation recorder `%s'. Run home-manager apply so Josip is installed."
              my/dictation-recorder-program))
     ((string-match-p "permission\\|privacy\\|denied\\|not authorized" detail)
      "Could not record audio. Check macOS Microphone permission for Josip.")
     ((string-match-p "no default\\|can't open input\\|input.*device\\|audio device\\|sox FAIL" detail)
      "Could not record audio from the default microphone. Check the selected input device and microphone permission.")
     ((not (string-empty-p detail))
      (format "Could not record audio: %s"
              (string-join (last (split-string detail "\n" t) 3) "\n")))
     ((stringp error)
      (format "Could not record audio: %s" error))
     (t
      "Could not record audio."))))

(defun my/dictation--start-recorder (audio-file stop-file ready-file)
  "Start Josip recording to AUDIO-FILE using STOP-FILE and READY-FILE."
  (let ((stderr-buffer (generate-new-buffer " *my-dictation-josip-stderr*")))
    (condition-case error
        (let ((process (make-process
                        :name "my-dictation-josip"
                        :buffer nil
                        :command (cons my/dictation-recorder-program
                                       (my/dictation--recorder-argv audio-file stop-file ready-file))
                        :connection-type 'pipe
                        :stderr stderr-buffer
                        :noquery t)))
          (process-put process 'stderr-buffer stderr-buffer)
          process)
      (error
       (when (buffer-live-p stderr-buffer)
         (kill-buffer stderr-buffer))
       (user-error "%s" (my/dictation--recorder-error-message error))))))

(defun my/dictation--cleanup-recorder (process)
  "Kill PROCESS stderr buffer if present."
  (when-let ((buffer (and process (process-get process 'stderr-buffer))))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

(defun my/dictation--wait-for-ready (process ready-file)
  "Wait until PROCESS writes READY-FILE, or signal a recorder error."
  (let ((deadline (+ (float-time) my/dictation-recorder-ready-timeout-seconds)))
    (while (and (< (float-time) deadline)
                (not (file-exists-p ready-file))
                (memq (process-status process) '(run open)))
      (accept-process-output process 0.1))
    (cond
     ((file-exists-p ready-file) t)
     ((not (memq (process-status process) '(run open)))
      (user-error "%s" (my/dictation--recorder-error-message
                         (format "Josip exited with status %s" (process-exit-status process))
                         (my/dictation--process-stderr process))))
     (t
      (user-error "Timed out waiting for Josip to start. Check the microphone permission prompt.")))))

(defun my/dictation--stop-recorder (process stop-file)
  "Ask PROCESS to stop by writing STOP-FILE, then wait briefly for exit."
  (when (memq (process-status process) '(run open))
    (with-temp-file stop-file
      (insert "stop\n")))
  (let ((deadline (+ (float-time) 3)))
    (while (and (< (float-time) deadline)
                (memq (process-status process) '(run open)))
      (accept-process-output process 0.1)))
  (when (memq (process-status process) '(run open))
    (kill-process process)
    (accept-process-output process 0.2))
  (unless (zerop (process-exit-status process))
    (user-error "%s" (my/dictation--recorder-error-message
                       (format "Josip exited with status %s" (process-exit-status process))
                       (my/dictation--process-stderr process)))))

(defun my/dictation--analyze-audio-file (audio-file)
  "Return an alist of `sox stat' facts for AUDIO-FILE."
  (with-temp-buffer
    (let ((exit-code (call-process "sox" nil (list (current-buffer) t) nil
                                   audio-file "-n" "stat")))
      (unless (zerop exit-code)
        (user-error "Could not inspect recorded audio: %s"
                    (string-trim (buffer-string))))
      (let ((output (buffer-string)))
        `((duration-seconds . ,(when (string-match "^Length (seconds):[[:space:]]*\\([0-9.]+\\)" output)
                                (string-to-number (match-string 1 output))))
          (maximum-amplitude . ,(when (string-match "^Maximum amplitude:[[:space:]]*\\([0-9.]+\\)" output)
                                  (string-to-number (match-string 1 output)))))))))

(defun my/dictation--assert-usable-audio (analysis)
  "Signal when ANALYSIS describes unusable audio."
  (let ((duration (alist-get 'duration-seconds analysis))
        (maximum-amplitude (alist-get 'maximum-amplitude analysis)))
    (when (and duration (< duration my/dictation--min-recording-seconds))
      (user-error "Recording was too short (%.1fs). Start dictation, speak, then press RET to stop."
                  duration))
    (when (and maximum-amplitude (< maximum-amplitude my/dictation--min-max-amplitude))
      (user-error "Recording appears to be silent. Check the default microphone, input volume, and macOS Microphone permission for Josip."))))

(defun my/dictation--file-bytes (file)
  "Return FILE contents as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun my/dictation--multipart-body (audio-file boundary)
  "Return unibyte multipart request body for AUDIO-FILE using BOUNDARY."
  (let ((audio-bytes (my/dictation--file-bytes audio-file))
        (file-name (file-name-nondirectory audio-file)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert "--" boundary "\r\n")
      (insert "Content-Disposition: form-data; name=\"model\"\r\n\r\n")
      (insert my/dictation-transcription-model "\r\n")
      (insert "--" boundary "\r\n")
      (insert "Content-Disposition: form-data; name=\"file\"; filename=\"" file-name "\"\r\n")
      (insert "Content-Type: audio/wav\r\n\r\n")
      (insert audio-bytes "\r\n")
      (insert "--" boundary "--\r\n")
      (buffer-string))))

(defun my/dictation--json-message (payload)
  "Return an error message from JSON PAYLOAD if present."
  (or (alist-get 'message payload)
      (let ((error (alist-get 'error payload)))
        (when (listp error)
          (alist-get 'message error)))
      "unknown error"))

(defun my/dictation--response-excerpt (body)
  "Return a compact diagnostic excerpt from response BODY."
  (let ((text (replace-regexp-in-string "[[:space:]]+" " " (string-trim body))))
    (cond
     ((string-empty-p text) "empty response body")
     ((> (length text) my/dictation--response-excerpt-chars)
      (concat (substring text 0 my/dictation--response-excerpt-chars) "…"))
     (t text))))

(defun my/dictation--parse-json-response (body status)
  "Parse transcription response BODY for HTTP STATUS, or signal a useful error."
  (condition-case nil
      (json-parse-string body :object-type 'alist :array-type 'list :null-object nil :false-object nil)
    (error
     (user-error "Transcription returned invalid JSON with HTTP %s: %s"
                 status
                 (my/dictation--response-excerpt body)))))

(defun my/dictation--transcript-from-response (status body)
  "Return transcript text from HTTP STATUS and response BODY."
  (let ((payload (my/dictation--parse-json-response body status)))
    (unless (and (>= status 200) (< status 300))
      (user-error "Transcription failed with HTTP %s: %s"
                  status (my/dictation--json-message payload)))
    (let ((transcript (string-trim (or (alist-get 'text payload) ""))))
      (when (string-empty-p transcript)
        (user-error "Transcription returned an empty transcript. Check microphone input and try again while speaking before pressing RET."))
      transcript)))

(defun my/dictation--transcribe-audio-file (audio-file)
  "Transcribe AUDIO-FILE and return transcript text."
  (unless my/dictation-transcription-base-url
    (user-error "Dictation transcription endpoint is not configured"))
  (when (< (file-attribute-size (file-attributes audio-file))
           my/dictation--min-audio-bytes)
    (user-error "Recording produced an empty or invalid audio file."))
  (let* ((boundary (format "emacs-dictation-%s-%s" (emacs-pid) (random)))
         (url-request-method "POST")
         (url-request-extra-headers
          `(("Authorization" . ,(concat "Bearer " my/dictation-transcription-api-key))
            ("Content-Type" . ,(concat "multipart/form-data; boundary=" boundary))))
         (url-request-data (my/dictation--multipart-body audio-file boundary))
         (url (concat (string-remove-suffix "/" my/dictation-transcription-base-url)
                      "/audio/transcriptions"))
         (buffer (url-retrieve-synchronously url t t my/dictation-transcription-timeout-seconds)))
    (unless buffer
      (user-error "Transcription timed out after %ss. Try a shorter recording or check the configured endpoint."
                  my/dictation-transcription-timeout-seconds))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (let ((status (or url-http-response-status 0)))
            (unless (re-search-forward "^\r?$" nil t)
              (user-error "Transcription returned an invalid HTTP response."))
            (my/dictation--transcript-from-response
             status
             (buffer-substring-no-properties (point) (point-max)))))
      (kill-buffer buffer))))

(defun my/dictation--record-audio-file (audio-file stop-file ready-file)
  "Record AUDIO-FILE with STOP-FILE and READY-FILE coordination."
  (let (process)
    (unwind-protect
        (progn
          (setq process (my/dictation--start-recorder audio-file stop-file ready-file))
          (message "Waiting for Josip…")
          (my/dictation--wait-for-ready process ready-file)
          (message "Recording dictation. Press RET to stop, ESC to cancel.")
          (catch 'stop-recording
            (while (memq (process-status process) '(run open))
              (let ((key (read-event "Recording dictation. Press RET to stop, ESC to cancel."
                                     nil 0.2)))
                (cond
                 ((null key) nil)
                 ((memq key '(?\r ?\n return enter))
                  (throw 'stop-recording t))
                 ((memq key '(?\e escape))
                  (user-error "Dictation cancelled"))
                 (t
                  (message "Press RET to stop dictation, or ESC to cancel."))))))
          (my/dictation--stop-recorder process stop-file))
      (when process
        (let ((inhibit-quit t))
          (when (memq (process-status process) '(run open))
            (ignore-errors
              (my/dictation--stop-recorder process stop-file)))))
      (my/dictation--cleanup-recorder process))))

(defun my/dictation--ghostel-buffer-p ()
  "Return non-nil when the current buffer should receive terminal paste input."
  (derived-mode-p 'ghostel-mode))

(defun my/dictation--terminal-safe-transcript (transcript)
  "Return TRANSCRIPT normalized for terminal input review before submission."
  (string-trim (replace-regexp-in-string "[[:cntrl:]]+" " " transcript)))

(defun my/dictation--deliver-transcript (buffer marker transcript)
  "Deliver TRANSCRIPT to BUFFER at MARKER, or through terminal input when needed."
  (unless (buffer-live-p buffer)
    (user-error "Original buffer was killed before dictation could be delivered."))
  (with-current-buffer buffer
    (if (my/dictation--ghostel-buffer-p)
        (let ((terminal-transcript (my/dictation--terminal-safe-transcript transcript)))
          (when (string-empty-p terminal-transcript)
            (user-error "Transcript contained no terminal-safe text to paste."))
          (unless (fboundp 'ghostel-paste-string)
            (user-error "Ghostel paste support is not available in this buffer."))
          (ghostel-paste-string terminal-transcript))
      (goto-char marker)
      (insert transcript))))

;;;###autoload
(defun my/dictation-insert ()
  "Record, transcribe, and insert voice dictation at point.

Recording is handled by the standalone Josip helper app, so macOS grants
microphone access to Josip rather than Emacs.  This command owns temporary file
cleanup, audio inspection, transcription, and delivering the transcript to the
current buffer.  In ordinary buffers delivery inserts at point; in Ghostel
terminal buffers delivery uses terminal paste input so TUIs receive the text."
  (interactive)
  (unless (my/dictation--ghostel-buffer-p)
    (barf-if-buffer-read-only))
  (let* ((target-buffer (current-buffer))
         (target-marker (copy-marker (point) nil))
         (temp-dir (make-temp-file "emacs-dictation-" t))
         (audio-file (expand-file-name "dictation.wav" temp-dir))
         (stop-file (expand-file-name "stop" temp-dir))
         (ready-file (expand-file-name "ready" temp-dir)))
    (unwind-protect
        (progn
          (my/dictation--record-audio-file audio-file stop-file ready-file)
          (message "Transcribing dictation…")
          (my/dictation--assert-usable-audio
           (my/dictation--analyze-audio-file audio-file))
          (let ((transcript (my/dictation--transcribe-audio-file audio-file)))
            (condition-case error
                (my/dictation--deliver-transcript target-buffer target-marker transcript)
              (error
               (kill-new transcript)
               (signal (car error) (cdr error))))
            (message "Dictation delivered. Review before using.")))
      (set-marker target-marker nil)
      (when (file-directory-p temp-dir)
        (delete-directory temp-dir t)))))

(keymap-global-set my/dictation-insert-key #'my/dictation-insert)

(with-eval-after-load 'ghostel
  ;; Ghostel char mode uses an override keymap ahead of global bindings so most
  ;; input goes to the terminal. Bind the dictation key there explicitly so it
  ;; remains available while Pi or another TUI is focused. Avoid C-c-prefixed
  ;; bindings here because Ghostel uses C-c as terminal interrupt.
  (keymap-set ghostel-char-mode-map my/dictation-insert-key #'my/dictation-insert)
  (keymap-set ghostel-readonly-mode-map my/dictation-insert-key #'my/dictation-insert))

(provide 'my-emacs-dictation)
;;; my-emacs-dictation.el ends here
