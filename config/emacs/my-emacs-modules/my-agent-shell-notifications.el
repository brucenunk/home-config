;;; my-agent-shell-notifications.el --- Local attention cues -*- lexical-binding: t -*-

;;; Commentary:
;; agent-shell-notifications owns event delivery, delays and dismissal.
;; Our adapter adds text-only KnockKnock popups, local sound and navigation.
;; Never load the upstream KnockKnock backend: it temporarily rebinds RET.

;;; Code:

(require 'cl-lib)
;; The pinned dependency otherwise truncates a predictable shared /tmp path
;; during require.  Redirect diagnostics before even loading its bytecode.
(eval-and-compile
  (defvar knockknock--log-file)
  (setq knockknock--log-file null-device))
(require 'knockknock)

(defgroup my/agent-notifications nil
  "Local agent-shell attention cues."
  :group 'agent-shell)

(defcustom my/agent-notification-sound-file
  (expand-file-name "sounds/agent-attention.wav" user-emacs-directory)
  "Local, Nix-generated chime.  Set to nil to disable sound."
  :type '(choice (const nil) file))

(defcustom my/agent-notification-active-seconds 10
  "Seconds without Emacs input before the selected session counts as AFK."
  :type 'natnum)

(defvar my/agent-notification--popup-id nil)
(defvar-local my/agent-notification--subscription nil)
(defvar-local my/agent-notification--reply-pending nil)
(defvar-local my/agent-notification--permissions nil)

(defun my/agent-notification--play ()
  "Play the chime asynchronously on the Emacs host, never through TRAMP."
  (when my/agent-notification-sound-file
    (let ((default-directory (expand-file-name "~/" "/")))
      (condition-case err
          (when-let* ((player (if (eq system-type 'darwin)
                                 "/usr/bin/afplay"
                               (executable-find "paplay")))
                      ((file-readable-p my/agent-notification-sound-file)))
            (make-process
             :name "agent-attention-sound" :buffer nil :noquery t
             :command (list player my/agent-notification-sound-file)
             :sentinel (lambda (process _event)
                         (when (and (memq (process-status process) '(exit signal))
                                    (not (zerop (process-exit-status process))))
                           (message "Agent chime failed: %s" (process-exit-status process))))))
        (error (message "Agent chime unavailable: %s" (error-message-string err)))))))

(defun my/agent-notification--send (notification)
  "Display NOTIFICATION without stealing focus or installing a keymap."
  (let ((id (gensym "agent-popup-")))
    ;; KnockKnock's startup queue renders the oldest item.  Its single popup
    ;; slot must contain only our latest cue, including before frame readiness.
    (setq my/agent-notification--popup-id id
          knockknock--pending-notifications nil)
    (when (display-graphic-p)
      (knockknock-notify :title (plist-get notification :title)
                        :message (plist-get notification :body)
                        :duration (plist-get notification :timeout)))
    (my/agent-notification--play)
    id))

(defun my/agent-notification--close (id)
  "Dismiss ID only if it still owns the single popup slot."
  (when (eq id my/agent-notification--popup-id)
    (setq my/agent-notification--popup-id nil)
    ;; The pinned KnockKnock's public close doesn't cancel queued rendering.
    ;; Cancel it too, so acknowledgement cannot resurrect an old popup.
    (when (timerp knockknock--debounce-timer)
      (cancel-timer knockknock--debounce-timer))
    (setq knockknock--debounce-timer nil
          knockknock--pending-notifications nil)
    (when (display-graphic-p) (knockknock-close))))

;; Configure the public provider API before loading the library: it validates
;; these functions at load time, even when automatic provider loading is off.
(defvar agent-shell-notifications-provider)
(defvar agent-shell-notifications-send-function)
(defvar agent-shell-notifications-close-function)
(setq agent-shell-notifications-provider nil
      agent-shell-notifications-send-function #'my/agent-notification--send
      agent-shell-notifications-close-function #'my/agent-notification--close)
(require 'agent-shell-notifications)
;; The pinned core resolves :app-icon before calling our provider, even though
;; text-only cues discard it.  Prevent synchronous network I/O on this path.
(advice-add 'agent-shell-notifications--icon-file :override #'ignore)

(defun my/agent-notification--active-p (shell)
  "Whether SHELL's selected viewport/shell has focused, recent Emacs input."
  (let ((selected (window-buffer (selected-window))))
    (and (eq t (frame-focus-state (selected-frame)))
         (or (eq selected shell)
             (eq selected (agent-shell-viewport--buffer
                           :shell-buffer shell :existing-only t)))
         (< (float-time (or (current-idle-time) 0))
            my/agent-notification-active-seconds))))

(defun my/agent-notification--prepare (_type event)
  "Capture EVENT's shell before upstream schedules a delayed notification.
This inhibit hook always permits delivery; upstream still filters cancellation."
  (unless (assq :my-shell event)
    (nconc event (list (cons :my-shell (current-buffer)))))
  nil)

(defun my/agent-notification--format (type event)
  "Build a short session-labelled notification for TYPE and EVENT."
  (let ((shell (map-elt event :my-shell)))
    (list :title (if (eq type 'permission-request)
                     "Agent needs permission" "Agent ready")
          :body (if (buffer-live-p shell) (buffer-name shell) "Agent shell"))))

(defun my/agent-notification--track (event)
  "Maintain pending-session state from public agent-shell EVENTs."
  (pcase (map-elt event :event)
    ('permission-request
     (cl-pushnew (map-nested-elt event '(:data :request-id))
                 my/agent-notification--permissions :test #'equal))
    ('permission-response
     (setq my/agent-notification--permissions
           (delete (map-nested-elt event '(:data :request-id))
                   my/agent-notification--permissions)))
    ('turn-complete
     (setq my/agent-notification--permissions nil
           my/agent-notification--reply-pending
           (not (equal (map-nested-elt event '(:data :stop-reason)) "cancelled"))))
    ((or 'input-submitted 'clean-up)
     ;; Mid-turn steering also emits input-submitted.  It acknowledges a
     ;; response, but does not answer any outstanding permission requests.
     (setq my/agent-notification--reply-pending nil)
     (when (eq (map-elt event :event) 'clean-up)
       (setq my/agent-notification--permissions nil))
     (agent-shell-notifications--cancel-and-close (current-buffer)))))

(defun my/agent-notification--acknowledge ()
  "Acknowledge the selected shell/viewport without answering permissions."
  (when-let* ((shell (if (derived-mode-p 'agent-shell-mode)
                        (current-buffer)
                      (agent-shell-viewport--shell-buffer (current-buffer)))))
    (with-current-buffer shell
      (setq my/agent-notification--reply-pending nil)
      (agent-shell-notifications--cancel-and-close shell))))

(defun my/agent-notification--setup ()
  "Enable delivery and pending tracking once in the current shell."
  (agent-shell-notifications-mode 1)
  (when my/agent-notification--subscription
    (agent-shell-unsubscribe :subscription my/agent-notification--subscription))
  (setq my/agent-notification--subscription
        (agent-shell-subscribe-to :shell-buffer (current-buffer)
                                  :on-event #'my/agent-notification--track))
  (add-hook 'post-command-hook #'my/agent-notification--acknowledge nil t))

(defun my/agent-notification--viewport-setup ()
  "Acknowledge interaction in either viewport mode, including compose typing."
  (add-hook 'post-command-hook #'my/agent-notification--acknowledge nil t))

(defun my/agent-notification-visit-waiting ()
  "Choose a live session awaiting a reply or permission, using its viewport."
  (interactive)
  (let ((waiting
         (cl-remove-if-not
          (lambda (buffer)
            (with-current-buffer buffer
              (and (derived-mode-p 'agent-shell-mode)
                   (or my/agent-notification--reply-pending
                       my/agent-notification--permissions))))
          (buffer-list))))
    (unless waiting (user-error "No agent sessions waiting"))
    (let ((shell (get-buffer (completing-read "Waiting agent: "
                                             (mapcar #'buffer-name waiting) nil t))))
      (agent-shell-notifications--switch-to-shell shell)
      (with-current-buffer shell (setq my/agent-notification--reply-pending nil)))))

(setq knockknock-use-svg-layout nil
      knockknock-use-icons nil
      knockknock-poshandler #'posframe-poshandler-frame-top-right-corner
      agent-shell-notifications-timeout 5
      agent-shell-notifications-idle-timeout my/agent-notification-active-seconds
      agent-shell-notifications-shell-visible-function #'my/agent-notification--active-p
      agent-shell-notifications-format-function #'my/agent-notification--format)
;; Upstream mode's lighter says "libnotify", regardless of provider.  Keep the
;; already crowded mode line untouched.
(setf (alist-get 'agent-shell-notifications-mode minor-mode-alist) nil)
(add-hook 'agent-shell-notifications-inhibit-functions #'my/agent-notification--prepare t)
(add-hook 'agent-shell-mode-hook #'my/agent-notification--setup)
(add-hook 'agent-shell-viewport-edit-mode-hook #'my/agent-notification--viewport-setup)
(add-hook 'agent-shell-viewport-view-mode-hook #'my/agent-notification--viewport-setup)

(provide 'my-agent-shell-notifications)
;;; my-agent-shell-notifications.el ends here