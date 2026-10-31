;;; my-agent-catalogue-tests.el --- Generated configuration tests -*- lexical-binding: t -*-

;;; Commentary:
;; Trusted configuration loading, explicit reload, and the Nix projection.

;;; Code:

(require 'ert)
(require 'my-agent-catalogue)

(defvar my/agent-catalogue-test--executed nil)

(defmacro my/agent-catalogue-test--with-config (&rest body)
  "Run BODY with isolated generated configuration and inventory."
  (declare (indent 0) (debug t))
  `(let ((user-emacs-directory (make-temp-file "agent-config-" t))
         (my/agent-machines nil))
     (unwind-protect (progn ,@body)
       (delete-directory user-emacs-directory t))))

(ert-deftest my/agent-catalogue-startup-allows-missing-configuration ()
  (my/agent-catalogue-test--with-config
    (should-not (my/agent-catalogue-reload 'noerror))
    (should-not my/agent-machines)))

(ert-deftest my/agent-catalogue-explicit-reload-reports-missing-file-and-clears-old-choices ()
  (my/agent-catalogue-test--with-config
    (setq my/agent-machines '(("old" :models nil)))
    (should-error (my/agent-catalogue-reload) :type 'file-missing)
    (should-not my/agent-machines)))

(ert-deftest my/agent-catalogue-is-trusted-executable-configuration ()
  (my/agent-catalogue-test--with-config
    (let (my/agent-catalogue-test--executed)
      (with-temp-file (locate-user-emacs-file "agent-catalogue.el")
        (insert "(setq my/agent-catalogue-test--executed t my/agent-machines '((\"machine\" :models nil)))\n"))
      (my/agent-catalogue-reload 'noerror)
      (should my/agent-catalogue-test--executed)
      (should (equal my/agent-machines '(("machine" :models nil)))))))

(ert-deftest my/agent-catalogue-refresh-is-explicit-and-replaces-the-inventory ()
  (my/agent-catalogue-test--with-config
    (with-temp-file (locate-user-emacs-file "agent-catalogue.el")
      (insert "(setq my/agent-machines '((\"old\" :models nil)))\n"))
    (my/agent-catalogue-reload 'noerror)
    (with-temp-file (locate-user-emacs-file "agent-catalogue.el")
      (insert "(setq my/agent-machines '((\"new\" :models nil)))\n"))
    (should (equal my/agent-machines '(("old" :models nil))))
    (call-interactively #'my/agent-catalogue-reload)
    (should (equal my/agent-machines '(("new" :models nil))))))

(ert-deftest my/agent-catalogue-loads-generated-nix-configuration ()
  (skip-unless (getenv "AGENT_CATALOGUE_TEST"))
  (my/agent-catalogue-test--with-config
    (copy-file (getenv "AGENT_CATALOGUE_TEST")
               (locate-user-emacs-file "agent-catalogue.el"))
    (my/agent-catalogue-reload 'noerror)
    (let ((local (cdr (assoc "machine-a" my/agent-machines)))
          (remote (cdr (assoc "machine-b" my/agent-machines))))
      (should (equal (mapcar #'car my/agent-machines) '("machine-a" "machine-b")))
      (should (equal (plist-get local :directory) "~/work/"))
      (should (equal (plist-get local :repositories)
                     '((:base-ref "origin/main" :name "example/project"
                        :path "/work/quoted \"path\"/back\\slash/é/main"))))
      (should (equal (plist-get local :default-model) "example/vendor/model"))
      (should (equal (plist-get local :models)
                     '((:default-thinking "medium" :name "example/vendor/model"
                        :thinking-levels ("off" "minimal" "low" "medium" "high")))))
      (should (equal (plist-get remote :directory) "/rpc:remote.example:~/work/"))
      (should (equal (plist-get remote :repositories)
                     '((:base-ref "origin/master" :name "example/bare" :path "/srv/git/project.git"))))
      (should (equal (plist-get remote :default-model) ""))
      (should-not (plist-get remote :models))
      (with-temp-buffer
        (insert-file-contents (locate-user-emacs-file "agent-catalogue.el"))
        (should-not (string-match-p "private-\\|isLocal\\|is-local\\|localMachine" (buffer-string)))))))

(provide 'my-agent-catalogue-tests)
;;; my-agent-catalogue-tests.el ends here