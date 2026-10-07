;;; my-emacs-remote-tests.el --- Tests for remote access configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Regression coverage for RPC integration and release-only server deployment.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'use-package)
(require 'my-emacs-remote)
;; Trigger the real module's deferred RPC setup, as a remote visit does.
(require 'tramp)
(require 'magit)
(require 'envrc)

(ert-deftest my/tramp-rpc-loads-with-linux-release-binaries ()
  (should (featurep 'tramp-rpc))
  (should (featurep 'tramp-rpc-magit))
  (should tramp-rpc-magit--magit-enabled)
  ;; Match envrc's remote-buffer predicate using TRAMP's parsed method string.
  (should envrc-remote)
  (should (seq-contains-p envrc-supported-tramp-methods
                          (file-remote-p "/rpc:user@example.invalid:/repo/" 'method)))
  (should (assoc "rpc" tramp-methods))
  (should (equal tramp-default-method "sshx"))
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

(provide 'my-emacs-remote-tests)
;;; my-emacs-remote-tests.el ends here