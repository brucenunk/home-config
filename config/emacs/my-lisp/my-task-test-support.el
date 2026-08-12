;;; my-task-test-support.el --- Shared helpers for task ERT tests -*- lexical-binding: t -*-

;;; Commentary:

;; Shared test support for task-related ERT files.

;;; Code:

(setq load-prefer-newer t)

(require 'ert)
(require 'dired)

(unless (require 'denote nil t)
  (defvar denote-directory nil)
  (defvar denote-templates nil)
  (defun denote-directories ()
    (list denote-directory))
  (defun denote-file-is-in-denote-directory-p (file)
    (and denote-directory
         (string-prefix-p (file-name-as-directory (expand-file-name denote-directory))
                          (expand-file-name file))))
  (defun denote-file-has-denoted-filename-p (file)
    (string-match-p "[0-9]\\{8\\}T[0-9]\\{6\\}==.*--.*" (file-name-nondirectory file)))
  (defun denote-retrieve-filename-identifier (file)
    (when (string-match "\\([0-9]\\{8\\}T[0-9]\\{6\\}\\)=="
                        (file-name-nondirectory file))
      (match-string 1 (file-name-nondirectory file))))
  (defun denote-get-path-by-id (identifier)
    (when denote-directory
      (car (directory-files-recursively
            denote-directory
            (format "\\`%s==.*" (regexp-quote identifier))
            nil nil))))
  (defun denote-retrieve-filename-signature (file)
    (when (string-match
           "[0-9]\\{8\\}T[0-9]\\{6\\}==\\([^=]+\\)--"
           (file-name-nondirectory file))
      (match-string 1 (file-name-nondirectory file))))
  (defun denote-directory-files (regexp &optional directory _text-only _omit-current _absolute)
    (let ((target (or directory denote-directory)))
      (if target
          (directory-files target t regexp t)
        nil)))
  (defun denote-sort-dired (regex _sort-component _reverse _omit-current)
    (dired (cons denote-directory (directory-files denote-directory t regex t)))
    (buffer-name))
  (provide 'denote))

(require 'my-task-index)
(require 'my-task)
(require 'my-task-list)

(declare-function my/task-index--persist-change "my-task-index" (operation mutator))
(declare-function my/task-index--read-file "my-task-index" (&optional strict))
(declare-function my/task-index--write-file "my-task-index" (table))
(declare-function my/task-session-active-ids "my-task-session" ())
(declare-function my/task-session-prepare-work-async "my-task-session" (&rest args))
(declare-function my/task-session-state-remove "my-task-session" (task))
(declare-function my/task-list--handle-task-state-change "my-task-list" (event))

(defmacro my/task-index-test--with-isolated-index (&rest body)
  "Run BODY with an isolated task-index file and in-memory table."
  (declare (indent 0) (debug t))
  `(let* ((temp-dir (make-temp-file "my-task-index-tests" t))
          (my/task-index-file (expand-file-name "task-index.el" temp-dir))
          (my/task-index (make-hash-table :test 'equal)))
     (unwind-protect
         (progn ,@body)
       (delete-directory temp-dir t))))

(defun my/task-index-test--entry (task-id &rest props)
  "Build durable task entry for TASK-ID with PROPS."
  (append (list :task-id task-id) props))

(defun my/task-index-test--persisted-table ()
  "Return the persisted task-index table for the current test."
  (my/task-index--read-file))

(defmacro my/task-index-test--with-unloaded-ui-modules (&rest body)
  "Run BODY after unloading task UI modules and clearing shared hook state."
  (declare (indent 0) (debug t))
  `(let ((had-task-state-hook (boundp 'my/task-state-change-functions)))
     (when (featurep 'my-task-list)
       (unload-feature 'my-task-list t))
     (when had-task-state-hook
       (makunbound 'my/task-state-change-functions))
     (unwind-protect
         (progn ,@body)
       (require 'my-task)
       (require 'my-task-list))))

(provide 'my-task-test-support)
;;; my-task-test-support.el ends here
