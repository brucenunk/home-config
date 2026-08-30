;;; my-emacs-completion-tests.el --- Tests for completion configuration -*- lexical-binding: t -*-

;;; Commentary:

;; Regression coverage for Corfu auto-completion policy and Cape helpers.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'vertico)
(require 'marginalia)
(require 'eshell)
(require 'my-emacs-completion)

(ert-deftest my/corfu-auto-is-local-to-programming-and-eshell-modes ()
  (should global-corfu-mode)
  (should-not (default-value 'corfu-auto))
  (with-temp-buffer
    (text-mode)
    (should-not corfu-auto)
    (should-not (local-variable-p 'corfu-auto)))
  (with-temp-buffer
    (emacs-lisp-mode)
    (should corfu-auto)
    (should (local-variable-p 'corfu-auto))
    (should (= corfu-auto-delay 0.1))
    (should (= corfu-auto-prefix 2)))
  (with-temp-buffer
    (eshell-mode)
    (should corfu-auto)
    (should (local-variable-p 'corfu-auto))
    (should (eq (car completion-at-point-functions)
                #'pcomplete-completions-at-point))))

(ert-deftest my/cape-dabbrev-capf-is-a-low-priority-global-fallback ()
  (let ((capfs (default-value 'completion-at-point-functions)))
    (should (eq (car (last capfs)) #'my/cape-dabbrev-capf)))
  (with-temp-buffer
    (insert "ab")
    (should-not (my/cape-dabbrev-capf)))
  (should (eq (keymap-lookup cape-prefix-map "d") #'cape-dabbrev)))

(ert-deftest my/cape-file-uses-the-buffer-directory-without-prefix ()
  (let ((default-directory "/buffer/base/")
        seen-directory)
    (cl-letf (((symbol-function 'cape-file)
               (lambda (interactive)
                 (should interactive)
                 (setq seen-directory cape-file-directory))))
      (my/cape-file nil))
    (should-not seen-directory)
    (should (equal default-directory "/buffer/base/"))))

(ert-deftest my/cape-file-uses-a-temporary-prompted-directory-with-prefix ()
  (let ((default-directory "/buffer/base/")
        (selected-directory "/selected/worktree/")
        seen-capf-directory
        seen-table-directory
        seen-location-directory)
    (cl-letf (((symbol-function 'read-directory-name)
               (lambda (&rest _args) selected-directory))
              ((symbol-function 'cape-file)
               (lambda ()
                 (setq seen-capf-directory cape-file-directory)
                 (list (point) (point)
                       (lambda (&rest _args)
                         (setq seen-table-directory default-directory))
                       :company-location
                       (lambda (&rest _args)
                         (setq seen-location-directory default-directory)))))
              ((symbol-function 'cape-interactive)
               (lambda (context capf)
                 (should (equal context '(cape-file-directory-must-exist)))
                 (let* ((result (funcall capf))
                        (table (nth 2 result))
                        (properties (nthcdr 3 result)))
                   (funcall table "" nil t)
                   (funcall (plist-get properties :company-location)
                            "candidate")))))
      (my/cape-file '(4)))
    (should (equal seen-capf-directory selected-directory))
    (should (equal seen-table-directory selected-directory))
    (should (equal seen-location-directory selected-directory))
    (should (equal default-directory "/buffer/base/"))))

(ert-deftest my/cape-file-replaces-the-upstream-prefix-map-binding ()
  (should (eq (keymap-lookup global-map "C-c p") cape-prefix-map))
  (should (eq (keymap-lookup cape-prefix-map "f") #'my/cape-file)))

(provide 'my-emacs-completion-tests)
;;; my-emacs-completion-tests.el ends here
