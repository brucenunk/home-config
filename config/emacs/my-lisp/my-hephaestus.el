;;; my-hephaestus.el --- Hephaestus CLI adapter -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Narrow adapter for the deployed standalone `hephaestus' binary on `$PATH'.
;;
;; Public functions:
;;   Async:
;;     - my/hephaestus-allocate-async — allocate a linked worktree for an owner/repo branch
;;     - my/hephaestus-resume-async — resume an exact worktree on an existing branch
;;   Sync:
;;     - my/hephaestus-release — release a linked worktree and tolerate already-detached clean paths
;;
;; Process launch, stdout/stderr parsing, path normalization, and error
;; formatting stay private to this adapter.

;;; Code:

(require 'cl-lib)
(require 'my-worktree)
(require 'subr-x)

(defun my/hephaestus--owner-repo-slug (owner repo)
  "Return OWNER/REPO slug string."
  (format "%s/%s" owner repo))

(defun my/hephaestus--normalize-path (path)
  "Return PATH as an expanded directory path."
  (file-name-as-directory (expand-file-name path)))

(defun my/hephaestus--same-path-p (left right)
  "Return non-nil when LEFT and RIGHT normalize to the same directory path."
  (equal (my/hephaestus--normalize-path left)
         (my/hephaestus--normalize-path right)))

(defun my/hephaestus--output-path (stdout)
  "Return first non-empty stdout line from HEPHAESTUS STDOUT, or nil."
  (car (split-string (string-trim-right (or stdout "")) "\n" t)))

(defun my/hephaestus--error-message (stderr stdout)
  "Return user-facing hephaestus error message from STDERR and STDOUT."
  (let* ((trimmed-stderr (and stderr (string-trim stderr)))
         (trimmed-stdout (and stdout (string-trim stdout)))
         (message (or (and (not (string-empty-p trimmed-stderr))
                           trimmed-stderr)
                      (and (not (string-empty-p trimmed-stdout))
                           trimmed-stdout)
                      "Hephaestus failed")))
    (if (string-empty-p message)
        "Hephaestus failed"
      message)))

(cl-defun my/hephaestus--run-async (args &key name on-success on-error)
  "Run `hephaestus' with ARGS asynchronously.
ON-SUCCESS is called with (STDOUT STDERR) on exit 0.
ON-ERROR is called with (ERROR-MESSAGE) on non-zero exit or startup failure."
  (let* ((stdout-buf (generate-new-buffer
                      (format " *hephaestus-%s-stdout*" (or name "async"))))
         (stderr-buf (generate-new-buffer
                      (format " *hephaestus-%s-stderr*" (or name "async")))))
    (condition-case err
        (make-process
         :name (format "hephaestus-%s" (or name "async"))
         :buffer stdout-buf
         :stderr stderr-buf
         :command (cons "hephaestus" args)
         :noquery t
         :connection-type 'pipe
         :coding 'utf-8-unix
         :sentinel
         (lambda (proc _event)
           (when (memq (process-status proc) '(exit signal))
             (let ((stdout (with-current-buffer stdout-buf (buffer-string)))
                   (stderr (with-current-buffer stderr-buf (buffer-string)))
                   (exit-code (process-exit-status proc)))
               (kill-buffer stdout-buf)
               (kill-buffer stderr-buf)
               (if (zerop exit-code)
                   (when on-success
                     (funcall on-success stdout stderr))
                 (when on-error
                   (funcall on-error
                            (my/hephaestus--error-message stderr stdout))))))))
      (error
       (kill-buffer stdout-buf)
       (kill-buffer stderr-buf)
       (when on-error
         (funcall on-error
                  (format "Failed to start hephaestus: %s"
                          (error-message-string err))))))))

(defun my/hephaestus--run (&rest args)
  "Run `hephaestus' synchronously with ARGS.
Return plist `(:exit-code CODE :stdout STDOUT :stderr STDERR)'."
  (let* ((stdout-buf (generate-new-buffer " *hephaestus-sync-stdout*"))
         (stderr-buf (generate-new-buffer " *hephaestus-sync-stderr*")))
    (unwind-protect
        (condition-case err
            (let ((proc (make-process
                         :name "hephaestus-sync"
                         :buffer stdout-buf
                         :stderr stderr-buf
                         :command (cons "hephaestus" args)
                         :noquery t
                         :connection-type 'pipe
                         :coding 'utf-8-unix)))
              (while (memq (process-status proc) '(run open listen connect stop))
                (accept-process-output proc 0.1))
              (list :exit-code (process-exit-status proc)
                    :stdout (with-current-buffer stdout-buf (buffer-string))
                    :stderr (with-current-buffer stderr-buf (buffer-string))))
          (error
           (list :exit-code -1
                 :stdout ""
                 :stderr (format "Failed to start hephaestus: %s"
                                 (error-message-string err)))))
      (kill-buffer stdout-buf)
      (kill-buffer stderr-buf))))

(defun my/hephaestus--validate-result-path (path expected label)
  "Return normalized PATH when it matches EXPECTED, otherwise signal `error'."
  (let ((normalized-path (my/hephaestus--normalize-path path))
        (normalized-expected (my/hephaestus--normalize-path expected)))
    (unless (my/hephaestus--same-path-p normalized-path normalized-expected)
      (error "%s returned unexpected worktree %s (expected %s)"
             label path expected))
    normalized-path))

;;;###autoload
(cl-defun my/hephaestus-allocate-async (owner repo branch &key fetch on-success on-error)
  "Allocate task BRANCH for OWNER/REPO asynchronously.
When FETCH is non-nil, refresh origin before allocation.
ON-SUCCESS is called with the allocated worktree path."
  (my/hephaestus--run-async
   (append (list "allocate"
                 (my/hephaestus--owner-repo-slug owner repo)
                 branch)
           (when fetch
             (list "--fetch")))
   :name "allocate"
   :on-success
   (lambda (stdout _stderr)
     (if-let ((allocated-worktree (my/hephaestus--output-path stdout)))
         (when on-success
           (funcall on-success
                    (my/hephaestus--normalize-path allocated-worktree)))
       (when on-error
         (funcall on-error "Hephaestus did not return a worktree path"))))
   :on-error on-error))

;;;###autoload
(cl-defun my/hephaestus-resume-async (worktree-path branch &key on-success on-error)
  "Resume WORKTREE-PATH on existing BRANCH asynchronously.
ON-SUCCESS is called with the resumed worktree path."
  (my/hephaestus--run-async
   (list "resume" worktree-path branch)
   :name "resume"
   :on-success
   (lambda (stdout _stderr)
     (condition-case err
         (if-let ((resumed-worktree (my/hephaestus--output-path stdout)))
             (when on-success
               (funcall on-success
                        (my/hephaestus--validate-result-path
                         resumed-worktree worktree-path "Hephaestus resume")))
           (when on-error
             (funcall on-error "Hephaestus did not return a worktree path")))
       (error
        (when on-error
          (funcall on-error (error-message-string err))))))
   :on-error on-error))

;;;###autoload
(defun my/hephaestus-release (worktree-path)
  "Release WORKTREE-PATH via `hephaestus'.
Signal `error' when release fails for a reason other than an already-detached
clean worktree."
  (let* ((result (my/hephaestus--run "release" worktree-path))
         (exit-code (plist-get result :exit-code))
         (stdout (plist-get result :stdout))
         (stderr (plist-get result :stderr))
         (error-message (my/hephaestus--error-message stderr stdout)))
    (unless (or (zerop exit-code)
                (and (string-prefix-p "worktree is already detached:" error-message)
                     (my/worktree-clean-p worktree-path)))
      (error "%s" error-message))
    t))

(provide 'my-hephaestus)
;;; my-hephaestus.el ends here
