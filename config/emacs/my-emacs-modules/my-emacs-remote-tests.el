;;; my-emacs-remote-tests.el --- Tests for remote access configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Regression coverage for RPC integration and release-only server deployment.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'use-package)
;; A separate batch run proves policy also removes handlers installed before
;; the shared module loads, rather than only preventing initial installation.
(when (getenv "MY_TRAMP_RPC_PRELOADED_TEST")
  (require 'tramp-rpc)
  (require 'magit)
  (require 'envrc)
  (setq tramp-default-method "sshx"
        envrc-remote t
        tramp-rpc-use-direnv t
        tramp-rpc-magit-optimize t)
  (tramp-rpc-magit-install-optional-handlers)
  (unless (and tramp-rpc-magit--magit-enabled
               (tramp-external-operation-p 'magit-status-setup-buffer 'tramp-rpc)
               (advice-member-p #'tramp-rpc-magit--section-show-advice
                                'magit-section-show))
    (error "Preloaded test did not install RPC Magit handlers")))
(require 'my-emacs-remote)
;; Trigger the real module's deferred RPC setup, as a remote visit does.
(require 'tramp)
(require 'magit)
(require 'envrc)

(ert-deftest my/tramp-rpc-loads-with-linux-release-binaries ()
  (should (featurep 'tramp-rpc))
  (should (featurep 'tramp-rpc-magit))
  (should-not tramp-rpc-magit--magit-enabled)
  ;; Match envrc's remote-buffer predicate using TRAMP's parsed method string.
  (should-not envrc-remote)
  (should (seq-contains-p envrc-supported-tramp-methods
                          (file-remote-p "/rpc:user@example.invalid:/repo/" 'method)))
  (should (assoc "rpc" tramp-methods))
  (should (equal tramp-default-method "rpc"))
  (should-not tramp-rpc-use-direnv)
  (should-not tramp-rpc-magit-optimize)
  (should tramp-rpc-deploy-auto-deploy)
  (should (eq tramp-rpc-deploy-git-build-policy 'release))
  (should-not tramp-rpc-deploy-prefer-build)
  (should-not tramp-rpc-deploy-source-directory)
  (dolist (arch '("x86_64-linux" "aarch64-linux"))
    (let ((binary (tramp-rpc-deploy--bundled-binary-path arch)))
      (should (file-executable-p binary))
      (cl-letf (((symbol-function 'tramp-rpc-deploy--download-binary)
                 (lambda (&rest _) (ert-fail "Bundled binary attempted download")))
                ((symbol-function 'tramp-rpc-deploy--build-binary)
                 (lambda (&rest _) (ert-fail "Bundled binary attempted build"))))
        (should (equal binary (tramp-rpc-deploy--ensure-local-binary arch))))))
  (should-not (tramp-rpc-deploy--bundled-binary-path "aarch64-darwin")))

(ert-deftest my/tramp-default-marker-and-explicit-sshx-selection ()
  ;; TRAMP 2.8.2's default syntax uses /-:, not plain /host:.
  (should (equal (file-remote-p "/-:example.invalid:/repo/" 'method) "rpc"))
  (should (equal (file-remote-p "/sshx:example.invalid:/repo/" 'method) "sshx"))
  (should-not (file-remote-p "/example.invalid:/repo/")))

(ert-deftest my/tramp-rpc-magit-opt-out-survives-optional-installation ()
  (tramp-rpc-magit-install-optional-handlers)
  (should-not tramp-rpc-magit-optimize)
  (should-not tramp-rpc-magit--magit-enabled)
  (dolist (operation '(magit-status-setup-buffer magit-status-refresh-buffer))
    (should-not (tramp-external-operation-p operation 'tramp-rpc)))
  (should-not (advice-member-p #'tramp-rpc-magit--section-show-advice
                              'magit-section-show)))

(ert-deftest my/tramp-rpc-cannot-run-cargo-even-after-download-failure ()
  (let ((cargo-called nil)
        (tramp-rpc-deploy-bundled-binary-directory nil)
        (tramp-rpc-deploy-local-cache-directory (make-temp-file "rpc-cache" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'tramp-rpc-deploy--download-binary)
                   (lambda (&rest _) (error "Simulated download failure")))
                  ((symbol-function 'tramp-rpc-deploy--cargo-available-p)
                   (lambda () t))
                  ((symbol-function 'call-process)
                   (lambda (&rest _) (setq cargo-called t) 0)))
          (should-error (tramp-rpc-deploy--ensure-local-binary "x86_64-linux")
                        :type 'remote-file-error)
          (should-error (tramp-rpc-deploy--build-binary "x86_64-linux")
                        :type 'remote-file-error)
          (should-not cargo-called))
      (delete-directory tramp-rpc-deploy-local-cache-directory t))))

(defconst my/tramp-rpc-test-managed-servers
  '((:host "managed.example.invalid" :user "rpc-user"
     :remoteBinaryPath "/home/rpc-user/.nix-profile/bin/tramp-rpc-server")
    (:host "all-users.example.invalid" :user nil
     :remoteBinaryPath "/opt/rpc/bin/tramp-rpc-server")))

(ert-deftest my/tramp-rpc-home-manager-managed-config-loads ()
  "The Nix check supplies the actual module-generated configuration."
  (skip-unless (getenv "MY_TRAMP_RPC_MANAGED_SERVERS_TEST"))
  (should (= (length my/tramp-rpc-managed-servers) 2))
  (dolist (entry my/tramp-rpc-test-managed-servers)
    (let ((actual (seq-find (lambda (server)
                              (equal (plist-get server :host)
                                     (plist-get entry :host)))
                            my/tramp-rpc-managed-servers)))
      (should actual)
      (should (equal (plist-get actual :user) (plist-get entry :user)))
      (should (equal (plist-get actual :remoteBinaryPath)
                     (plist-get entry :remoteBinaryPath)))))
  (let ((plan (tramp-rpc-deploy-plan
               (tramp-dissect-file-name "/rpc:rpc-user@managed.example.invalid:/"))))
    (should (eq (tramp-rpc-deploy-plan-mode plan) 'never))))

(ert-deftest my/tramp-rpc-managed-policy-is-host-user-and-method-scoped ()
  (let ((connection-local-profile-alist nil)
        (connection-local-criteria-alist nil))
    (my/tramp-rpc-configure-managed-servers my/tramp-rpc-test-managed-servers)
    (dolist (name '("/rpc:rpc-user@managed.example.invalid:/"
                    "/rpc:other@all-users.example.invalid:/"))
      (let ((plan (tramp-rpc-deploy-plan (tramp-dissect-file-name name))))
        (should (eq (tramp-rpc-deploy-plan-mode plan) 'never))
        (should-not (tramp-rpc-deploy-plan-binary-id plan))
        (should-not (tramp-rpc-deploy-plan-source-directory plan))
        (should-not (tramp-rpc-deploy-plan-prefer-build plan))
        (should (eq (tramp-rpc-deploy-plan-git-build-policy plan) 'release))))
    (dolist (name '("/rpc:other@managed.example.invalid:/"
                    "/rpc:rpc-user@managedXexample.invalid:/"
                    "/rpc:rpc-user@unrelated.example.invalid:/"
                    "/sshx:rpc-user@managed.example.invalid:/"))
      (let ((plan (tramp-rpc-deploy-plan (tramp-dissect-file-name name))))
        (should (eq (tramp-rpc-deploy-plan-mode plan) 'auto))
        (should (equal (tramp-rpc-deploy-plan-binary-id plan) "0.15.0"))))
    (should-not tramp-rpc-deploy-never-deploy)
    (should-not tramp-rpc-deploy-remote-binary-path)))

(ert-deftest my/tramp-rpc-managed-connect-never-acquires-or-transfers ()
  "Exercise upstream's real connect branch, including a missing server."
  (let ((connection-local-profile-alist nil)
        (connection-local-criteria-alist nil)
        (tramp-rpc-use-controlmaster nil)
        (vec (tramp-dissect-file-name "/rpc:rpc-user@managed.example.invalid:/"))
        attempted-path)
    (my/tramp-rpc-configure-managed-servers my/tramp-rpc-test-managed-servers)
    (cl-letf (((symbol-function 'tramp-rpc--ensure-controlmaster-directory) #'ignore)
              ((symbol-function 'tramp-rpc--detect-sudo-elevation) (lambda (&rest _) nil))
              ((symbol-function 'tramp-rpc--cleanup-bootstrap-connection) #'ignore)
              ((symbol-function 'tramp-rpc--cleanup-failed-connection) #'ignore)
              ((symbol-function 'tramp-rpc-deploy--ensure-local-binary)
               (lambda (&rest _) (ert-fail "Managed host acquired a binary")))
              ((symbol-function 'tramp-rpc-deploy--download-binary)
               (lambda (&rest _) (ert-fail "Managed host downloaded a binary")))
              ((symbol-function 'tramp-rpc-deploy--build-binary)
               (lambda (&rest _) (ert-fail "Managed host built a binary")))
              ((symbol-function 'copy-file)
               (lambda (&rest _) (ert-fail "Managed host transferred a binary"))))
      (cl-letf (((symbol-function 'tramp-rpc--start-server-process)
                 (lambda (_vec path &rest _)
                   (setq attempted-path path))))
        (tramp-rpc--connect vec)
        (should (equal attempted-path "/home/rpc-user/.nix-profile/bin/tramp-rpc-server")))
      (cl-letf (((symbol-function 'tramp-rpc--start-server-process)
                 (lambda (_vec path &rest _)
                   (setq attempted-path path)
                   (signal 'tramp-rpc-server-unavailable '("Missing server")))))
        (let ((err (should-error (tramp-rpc--connect vec) :type 'remote-file-error)))
          (should (string-match-p "no deployment attempted" (error-message-string err))))
        (should (equal attempted-path "/home/rpc-user/.nix-profile/bin/tramp-rpc-server"))))))

(ert-deftest my/tramp-rpc-managed-buffer-does-not-leak-policy-to-other-targets ()
  (let ((connection-local-profile-alist nil)
        (connection-local-criteria-alist nil))
    (my/tramp-rpc-configure-managed-servers my/tramp-rpc-test-managed-servers)
    (with-temp-buffer
      (setq default-directory "/rpc:rpc-user@managed.example.invalid:/")
      (hack-connection-local-variables-apply
       (connection-local-criteria-for-default-directory))
      (should tramp-rpc-deploy-never-deploy)
      (dolist (name '("/rpc:rpc-user@unrelated.example.invalid:/"
                      "/rpc:other@managed.example.invalid:/"))
        (let* ((vec (tramp-dissect-file-name name))
               (plan (tramp-rpc-deploy-plan vec)))
          (should (eq (tramp-rpc-deploy-plan-mode plan) 'auto))
          (should (equal (tramp-rpc-deploy-plan-binary-id plan) "0.15.0"))
          (should-not (equal (tramp-rpc-deploy-plan-remote-localname plan)
                             "/home/rpc-user/.nix-profile/bin/tramp-rpc-server"))))
      ;; The source buffer keeps its own policy after resolving other targets.
      (should tramp-rpc-deploy-never-deploy)
      (let ((plan (tramp-rpc-deploy-plan
                   (tramp-dissect-file-name "/rpc:other@all-users.example.invalid:/"))))
        (should (eq (tramp-rpc-deploy-plan-mode plan) 'never))
        (should (equal (tramp-rpc-deploy-plan-remote-localname plan)
                       "/opt/rpc/bin/tramp-rpc-server"))))))

(provide 'my-emacs-remote-tests)
;;; my-emacs-remote-tests.el ends here