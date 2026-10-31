;;; my-emacs-literate-tests.el --- Generated configuration checks -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)

(defconst my/literate-test--generated (getenv "MY_EMACS_GENERATED"))
(defconst my/literate-test--source (getenv "MY_EMACS_SOURCE"))

(defun my/literate-test--files (directory)
  "Return Lisp files recursively under DIRECTORY."
  (directory-files-recursively directory "\\.el\\'"))

(defun my/literate-test--forms (file)
  "Read all top-level forms in FILE, checking its syntax first."
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (check-parens)
    (goto-char (point-min))
    (let (forms)
      (condition-case nil
          (while t (push (read (current-buffer)) forms))
        (end-of-file nil))
      (nreverse forms))))

(ert-deftest my/literate-generated-layout-and-syntax ()
  (let ((expected '("early-init.el" "init.el" "my-emacs-modules/my-emacs-agents.el"
                    "my-emacs-modules/my-emacs-completion.el"
                    "my-emacs-modules/my-emacs-dired.el"
                    "my-emacs-modules/my-emacs-editing.el"
                    "my-emacs-modules/my-emacs-writing.el"
                    "my-emacs-modules/my-emacs-org.el"
                    "my-emacs-modules/my-emacs-denote.el"
                    "my-emacs-modules/my-emacs-git.el"
                    "my-emacs-modules/my-emacs-languages.el"
                    "my-emacs-modules/my-emacs-shells.el"
                    "my-emacs-modules/my-emacs-remote.el"
                    "my-emacs-modules/my-emacs-ui.el"
                    "my-emacs-modules/my-emacs-excali.el"
                    "my-emacs-modules/my-emacs-org-excali.el")))
    (should (equal (sort (mapcar (lambda (file)
                                  (file-relative-name file my/literate-test--generated))
                                (my/literate-test--files my/literate-test--generated))
                         #'string<)
                   (sort expected #'string<))))
  (dolist (file (append (my/literate-test--files my/literate-test--generated)
                        (my/literate-test--files
                         (expand-file-name "my-lisp" my/literate-test--source))))
    (ert-info (file) (my/literate-test--forms file))))

(ert-deftest my/literate-generated-files-have-lisp-headers ()
  (dolist (file (my/literate-test--files my/literate-test--generated))
    (ert-info (file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (should (looking-at ";;+ .*lexical-binding: t"))
        (forward-line 1)
        (should (looking-at ";;+ .*\\(?:Generated from\\|Do not edit\\)"))))))

(ert-deftest my/literate-capability-imports-are-alphabetical ()
  (let ((imports
         (cl-loop for form in (my/literate-test--forms
                              (expand-file-name "init.el" my/literate-test--generated))
                  when (and (eq (car-safe form) 'require)
                            (string-prefix-p "my-emacs-" (symbol-name (cadadr form))))
                  collect (symbol-name (cadadr form)))))
    (should imports)
    (should (equal imports (sort (copy-sequence imports) #'string<)))))

(ert-deftest my/literate-generated-modules-contain-no-implementation-functions ()
  (cl-labels ((check (form)
                (when (consp form)
                  (should-not (memq (car form) '(defun cl-defun defmacro)))
                  (check (car form))
                  (check (cdr form)))))
    (dolist (file (my/literate-test--files my/literate-test--generated))
      (ert-info (file)
        (mapc #'check (my/literate-test--forms file))))))

(ert-deftest my/literate-tangling-is-reproducible ()
  (let ((output (make-temp-file "emacs-tangle-" t)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (let ((status
                   (call-process
                    (expand-file-name invocation-name invocation-directory) nil t nil
                    "--batch" "-Q" "--load"
                    (expand-file-name "tangle.el" my/literate-test--source)
                    "--funcall" "my/emacs-tangle-batch"
                    (expand-file-name "my-emacs.org" my/literate-test--source) output)))
              (ert-info ((buffer-string)) (should (equal status 0)))))
          (should (= (length (my/literate-test--files output))
                     (length (my/literate-test--files my/literate-test--generated))))
          (dolist (file (my/literate-test--files my/literate-test--generated))
            (should (equal (with-temp-buffer
                             (insert-file-contents-literally file) (buffer-string))
                           (with-temp-buffer
                             (insert-file-contents-literally
                              (expand-file-name
                               (file-relative-name file my/literate-test--generated) output))
                             (buffer-string))))))
      (delete-directory output t))))

(ert-deftest my/literate-isolated-startup-loads-generated-config-not-org ()
  (with-temp-buffer
    (let ((status
           (call-process
            (expand-file-name invocation-name invocation-directory) nil t nil
            "--batch" "-Q"
            "--eval" (prin1-to-string `(setq load-path ',load-path))
            "--eval"
            (prin1-to-string
             `(progn
                (require 'ert)
                (require 'package)
                (package-initialize)
                (setq use-package-expand-minimally t)
                (advice-add 'org-babel-tangle :before
                            (lambda (&rest _) (ert-fail "Tangled during startup")))
                (advice-add 'org-babel-load-file :before
                            (lambda (&rest _) (ert-fail "Loaded Org during startup")))
                ;; A full startup smoke test must never create a server socket,
                ;; poll OS appearance or schedule agent cleanup.
                (require 'server)
                (fset 'server-running-p (lambda (&rest _) t))
                (fset 'server-start (lambda (&rest _) (ert-fail "Started server")))
                (require 'auto-dark)
                (fset 'auto-dark-mode #'ignore)
                (require 'agent-shell-gc)
                (fset 'agent-shell-gc-mode #'ignore)
                (setq user-emacs-directory
                      (file-name-as-directory (make-temp-file "emacs-startup-" t)))
                (load ,(expand-file-name "early-init.el" my/literate-test--generated) nil t)
                (load ,(expand-file-name "init.el" my/literate-test--generated) nil t)
                (dolist (feature '(my-emacs-agents my-emacs-completion my-emacs-editing
                                   my-emacs-writing my-emacs-org my-emacs-remote
                                   my-emacs-ui my-emacs-excali my-emacs-org-excali
                                   my-emacs-languages my-emacs-dired my-emacs-shells
                                   my-emacs-git my-emacs-denote))
                  (should (featurep feature)))
                (should-not (featurep 'excali))
                (should (equal (alist-get 'nix-ts-mode my/eglot-mode-server-executables)
                               "nixd"))
                (dolist (command '(my/agent-session-start-from-file
                                   my/agent-session-start-new-worktree
                                   my/agent-session-start-in-directory))
                  (should (commandp command)))
                (should-not (boundp 'my/agent-session-map))
                (should-not (key-binding (kbd "C-c a")))
                (should (eq denote-file-type 'org)))))))
      (ert-info ((buffer-string)) (should (equal status 0))))))

(provide 'my-emacs-literate-tests)
;;; my-emacs-literate-tests.el ends here