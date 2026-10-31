;;; my-emacs-deferred-tests.el --- Deferred registration checks -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'use-package)

(defconst my/deferred-test--directory (file-name-directory load-file-name))
(defconst my/deferred-test--init
  (or (getenv "MY_EMACS_INIT_FILE")
      (expand-file-name "../init.el" my/deferred-test--directory)))

(defun my/deferred-test--declaration (file package)
  "Read PACKAGE's single top-level declaration from FILE."
  (let (declarations)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (condition-case nil
          (while t
            (let ((form (read (current-buffer))))
              (when (and (eq (car-safe form) 'use-package)
                         (eq (nth 1 form) package))
                (push form declarations))))
        (end-of-file nil)))
    (should (= (length declarations) 1))
    (car declarations)))

(defun my/deferred-test--fresh (&rest forms)
  "Evaluate FORMS in isolated batch Emacs with the same package paths."
  (with-temp-buffer
    (let ((status
           (call-process
            (expand-file-name invocation-name invocation-directory) nil t nil
            "--batch" "-Q"
            "--eval" (prin1-to-string `(setq load-path ',load-path))
            "--eval" "(require 'ert)"
            "--eval" "(require 'use-package)"
            "--eval" (prin1-to-string `(progn ,@forms)))))
      (ert-info ((buffer-string)) (should (equal status 0))))))

(ert-deftest my/deferred-embark-reference-registration-load-orders ()
  (dolist (order '((my-agent-shell my-emacs-completion consult embark)
                   (consult embark my-agent-shell my-emacs-completion)
                   (embark consult my-emacs-completion my-agent-shell)
                   (embark-consult my-emacs-completion my-agent-shell)
                   (embark-consult my-agent-shell my-emacs-completion)
                   (my-emacs-completion embark my-agent-shell consult)))
    (ert-info (order)
      (my/deferred-test--fresh
       ;; Disable only background cleanup; never launch an agent/session.
       '(require 'agent-shell-gc)
       '(advice-add 'agent-shell-gc-mode :override #'ignore)
       `(dolist (feature ',order) (require feature))
       '(should (featurep 'embark-consult))
       '(should (eq (lookup-key embark-file-map (kbd "@"))
                    #'my/agent-shell-insert-reference))
       '(should (eq (keymap-parent my/agent-shell-reference-map) embark-general-map))
       '(should (eq (lookup-key my/agent-shell-reference-map (kbd "@"))
                    #'my/agent-shell-insert-reference))
       '(should (equal (alist-get 'consult-grep embark-keymap-alist)
                       '(my/agent-shell-reference-map)))
       '(should (equal (alist-get 'my/agent-shell-insert-reference
                                 embark-around-action-hooks)
                       '(my/agent-shell--reference-action)))
       '(should (memq #'consult-preview-at-point-mode embark-collect-mode-hook))))))

(ert-deftest my/deferred-embark-consult-has-explicit-load-trigger ()
  (my/deferred-test--fresh
   ;; Embark itself currently loads embark-consult when Consult arrives.  Unload
   ;; that integration in this child to check our declaration's own load trigger.
   '(require 'embark)
   '(require 'consult)
   '(when (featurep 'embark-consult) (unload-feature 'embark-consult t))
   '(should-not (featurep 'embark-consult))
   (my/deferred-test--declaration
    (expand-file-name "my-emacs-completion.el" my/deferred-test--directory)
    'embark-consult)
   '(should (featurep 'embark-consult))))

(ert-deftest my/deferred-completion-does-not-force-agent-module ()
  (my/deferred-test--fresh
   '(require 'my-emacs-completion)
   '(require 'embark)
   '(should (featurep 'embark-consult))
   '(should-not (featurep 'my-agent-shell))
   '(should-not (featurep 'agent-shell))))

(ert-deftest my/deferred-eglot-nix-registration-load-orders ()
  (let ((declaration (my/deferred-test--declaration my/deferred-test--init 'eglot)))
    (dolist (loaded '(nil t))
      (my/deferred-test--fresh
       `(when ,loaded (require 'eglot))
       declaration
       `(should (eq (featurep 'eglot) ,loaded))
       '(require 'eglot)
       '(should (equal (alist-get 'nix-ts-mode eglot-server-programs)
                       '("nixd" :initializationOptions
                         (:formatting (:command ["nixfmt"])))))))))

(ert-deftest my/deferred-magit-diff-binding-load-orders ()
  (let ((declaration (my/deferred-test--declaration my/deferred-test--init 'magit-diff)))
    (dolist (loaded '(nil t))
      (my/deferred-test--fresh
       `(when ,loaded (require 'magit-diff))
       declaration
       `(should (eq (featurep 'magit-diff) ,loaded))
       '(require 'magit-diff)
       '(should (eq (lookup-key magit-diff-mode-map (kbd "C-c r"))
                    #'my/agent-shell-quote-region))
       '(should (eq (lookup-key magit-diff-mode-map (kbd "r")) #'magit-rebase))
       '(should-not (eq (lookup-key magit-mode-map (kbd "C-c r"))
                        #'my/agent-shell-quote-region))))))

(ert-deftest my/deferred-go-association-in-mode-declaration ()
  (my/deferred-test--fresh
   '(should-not (featurep 'go-ts-mode))
   (my/deferred-test--declaration my/deferred-test--init 'go-ts-mode)
   '(should-not (featurep 'go-ts-mode))
   '(should (eq (cdr (assoc "\\.go\\'" auto-mode-alist)) 'go-ts-mode))))

(ert-deftest my/deferred-package-declarations-are-unique ()
  (let ((seen (make-hash-table :test #'eq)))
    (dolist (file (cons my/deferred-test--init
                        (directory-files my/deferred-test--directory t "\\.el\\'")))
      (unless (string-suffix-p "-tests.el" file)
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (condition-case nil
              (while t
                (let ((form (read (current-buffer))))
                  (when (eq (car-safe form) 'use-package)
                    (let ((package (nth 1 form)))
                      (ert-info ((format "%s declared in %s and %s"
                                         package (gethash package seen) file))
                        (should-not (gethash package seen)))
                      (puthash package file seen)))))
            (end-of-file nil)))))))

(provide 'my-emacs-deferred-tests)
;;; my-emacs-deferred-tests.el ends here