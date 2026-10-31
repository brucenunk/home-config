;;; my-shells.el --- Shell startup helpers -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Implementation for the configuration in my-emacs.org.
;; Public functions/commands:
;;   - my/exec-path-from-shell-initialize-deferred

;;; Code:


;;;###autoload
(defun my/exec-path-from-shell-initialize-deferred ()
  "Initialize shell PATH after startup when GUI or daemon sessions need it."
  (when (or (display-graphic-p) (daemonp))
    (run-with-idle-timer
     1 nil
     (lambda ()
       (exec-path-from-shell-initialize)))))

(provide 'my-shells)
;;; my-shells.el ends here