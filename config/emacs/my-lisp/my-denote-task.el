;;; my-denote-task.el --- Follow-up note identity -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (denote "3.0"))

;;; Commentary:

;; Ordinary Denote follow-up files, independent of capture and agent lifecycle.
;; Public functions/predicates:
;;   - my/denote-task-directory — return the shared follow-up root
;;   - my/denote-task-file-p — recognize a Denote Org follow-up note

;;; Code:

(require 'denote)

(defgroup my-denote-task nil
  "Denote follow-up notes."
  :group 'denote)

;;;###autoload
(defun my/denote-task-directory ()
  "Return the shared follow-up file root."
  (expand-file-name "~/work/docs/tasks/"))

;;;###autoload
(defun my/denote-task-file-p ()
  "Return non-nil if the current buffer visits a Denote Org follow-up note."
  (and buffer-file-name
       (equal (file-name-extension buffer-file-name) "org")
       (file-in-directory-p buffer-file-name (my/denote-task-directory))
       (denote-file-has-denoted-filename-p buffer-file-name)))

(provide 'my-denote-task)
;;; my-denote-task.el ends here