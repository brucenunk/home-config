;;; my-agent-shell-notifications.el --- Local attention cues -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Implementation for the configuration in my-emacs.org.
;; Public functions/commands:
;;   - my/agent-notification-visit-waiting

;;; Code:

(require 'cl-lib)

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

(defun my/agent-notification--send (_notification)
  "Play one local chime without displaying a notification."
  (my/agent-notification--play)
  ;; The core tracks provider IDs independently for each session.
  (gensym "agent-chime-"))

(defun my/agent-notification--close (_id)
  "Nothing to dismiss for an already-started, one-shot chime."
  nil)

(defvar agent-shell-notifications-provider)

(defvar agent-shell-notifications-send-function)

(defvar agent-shell-notifications-close-function)

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

;;;###autoload
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

(provide 'my-agent-shell-notifications)
;;; my-agent-shell-notifications.el ends here