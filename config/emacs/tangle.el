;;; tangle.el --- Build-time literate configuration generation -*- lexical-binding: t -*-

(require 'ob-tangle)

(defun my/emacs-tangle-batch ()
  "Tangle the source and output directory supplied as command-line arguments."
  (unless (= (length command-line-args-left) 2)
    (error "Expected Org source and output directory"))
  (let* ((source (expand-file-name (pop command-line-args-left)))
         (output (file-name-as-directory
                  (expand-file-name (pop command-line-args-left))))
         (org-confirm-babel-evaluate t))
    (make-directory output t)
    ;; Only tangling is needed: do not evaluate blocks or load user settings.
    ;; Resolve relative tangle paths in OUTPUT, not in the source worktree.
    (with-temp-buffer
      (insert-file-contents source)
      (setq buffer-file-name (expand-file-name "my-emacs.org" output)
            default-directory output)
      (org-mode)
      (org-babel-tangle))))

(provide 'my-emacs-tangle)
;;; tangle.el ends here
