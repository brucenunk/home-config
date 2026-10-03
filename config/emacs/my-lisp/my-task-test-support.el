;;; my-task-test-support.el --- Shared helpers for task ERT tests -*- lexical-binding: t -*-

;;; Commentary:

;; Run against real Denote.  Persisted filters are isolated from user state.

;;; Code:

(setq load-prefer-newer t)
(require 'ert)
(require 'cl-lib)
(require 'dired)
(require 'denote)
(require 'my-task)
(defvar my/task-list-filter-file)
(let ((my/task-list-filter-file (make-temp-name
                               (expand-file-name "task-test-filter-" temporary-file-directory))))
  (require 'my-task-list))

(provide 'my-task-test-support)
;;; my-task-test-support.el ends here
