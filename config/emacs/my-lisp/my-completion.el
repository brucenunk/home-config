;;; my-completion.el --- Completion helpers -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Implementation for the configuration in my-emacs.org.
;; Public functions/commands:
;;   - my/project-git-branch
;;   - my/marginalia-annotate-project-file
;;   - my/corfu-enable-auto
;;   - my/cape-explicit-file-capf
;;   - my/cape-file-capf
;;   - my/cape-file
;;   - my/cape-dabbrev-capf

;;; Code:

(eval-when-compile
  (require 'marginalia))

;;;###autoload
(defun my/project-git-branch (directory)
  "Return DIRECTORY's current Git branch, or `detached'."
  (let* ((dot-git (expand-file-name ".git" directory))
         (git-directory
          (cond
           ((file-directory-p dot-git) dot-git)
           ((file-regular-p dot-git)
            (with-temp-buffer
              (insert-file-contents dot-git)
              (let ((gitdir (string-trim (buffer-string))))
                (when (string-prefix-p "gitdir: " gitdir)
                  (expand-file-name
                   (string-remove-prefix "gitdir: " gitdir)
                   directory)))))))
         (head-file (and git-directory
                         (expand-file-name "HEAD" git-directory))))
    (when (and head-file (file-readable-p head-file))
      (with-temp-buffer
        (insert-file-contents head-file)
        (let ((head (string-trim (buffer-string))))
          (cond
           ((string-prefix-p "ref: refs/heads/" head)
            (string-remove-prefix "ref: refs/heads/" head))
           ((string-match-p "\\`[[:xdigit:]]+\\'" head) "detached")))))))

;;;###autoload
(defun my/marginalia-annotate-project-file (candidate)
  "Annotate project CANDIDATE with its Git branch when appropriate.
Detached Git worktrees are labelled `detached'.  Other project-file
candidates retain Marginalia's standard file annotation."
  (if (and (file-name-absolute-p candidate)
           (not (file-remote-p candidate))
           (file-directory-p candidate))
      (let ((default-directory
             (file-name-as-directory (expand-file-name candidate))))
        (let ((branch (my/project-git-branch default-directory)))
          (if branch
              (let ((detached (equal branch "detached")))
                (marginalia--fields
                 ((if detached "-" branch)
                  :face (if detached
                            'marginalia-null
                          'marginalia-value))))
            (marginalia-annotate-project-file candidate))))
    (marginalia-annotate-project-file candidate)))

;;;###autoload
(defun my/corfu-enable-auto ()
  "Enable Corfu automatic completion in the current supported buffer."
  (setq-local corfu-auto t))

;;;###autoload
(defun my/cape-explicit-file-capf ()
  "Complete explicit paths using Cape and the buffer's working directory.
Leave prose, URLs, @ mentions and slash-command-like tokens alone.  An
absolute path must contain a directory component (for example /tmp/).
Modes which omit the global CAPF fallback marker `t' keep their own policy."
  (when-let* ((bounds (bounds-of-thing-at-point 'filename))
              (file (buffer-substring-no-properties (car bounds) (point)))
              ((string-match-p "\\`\\(?:\\.\\.?/\\|~/\\|/[^/[:space:]]+/\\)" file)))
    ;; Capture the directory for delayed table and location queries too.
    ;; Cape's native file handler dispatch supports TRAMP, including RPC.
    (my/cape-file-capf default-directory)))

;;;###autoload
(defun my/cape-file-capf (directory)
  "Return a `cape-file' CAPF which resolves relative to DIRECTORY."
  (let ((cape-file-directory directory))
    (pcase (cape-file)
      (`(,beg ,end ,table . ,properties)
       (let* ((properties (copy-sequence properties))
              (location (plist-get properties :company-location)))
         (when location
           (setq properties
                 (plist-put
                  properties :company-location
                  (lambda (&rest args)
                    (let ((default-directory directory))
                      (apply location args))))))
         `(,beg ,end
                ,(lambda (string predicate action)
                   (let ((default-directory directory))
                     (complete-with-action action table string predicate)))
                ,@properties))))))

;;;###autoload
(defun my/cape-file (prefix)
  "Complete a file, prompting for a temporary base directory with PREFIX."
  (interactive "P")
  (if prefix
      (let ((directory
             (read-directory-name "File completion base directory: "
                                  default-directory nil t)))
        (cape-interactive
         '(cape-file-directory-must-exist)
         (lambda () (my/cape-file-capf directory))))
    (cape-file t)))

;;;###autoload
(defun my/cape-dabbrev-capf ()
  "Complete via `cape-dabbrev' after a three-character prefix."
  (funcall (cape-capf-prefix-length #'cape-dabbrev 3)))

(provide 'my-completion)
;;; my-completion.el ends here