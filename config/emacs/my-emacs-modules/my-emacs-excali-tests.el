;;; my-emacs-excali-tests.el --- Drawing integration checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'excali)
(require 'my-emacs-excali)

(defmacro my/excali-test-scene (&rest body)
  `(with-temp-buffer
     (setq major-mode 'excali-mode
           excali--doc (excali--empty-doc)
           excali--native-cache (make-hash-table :test #'eq))
     (cl-letf (((symbol-function 'excali--render) #'ignore)) ,@body)))

(ert-deftest my/excali-capabilities-not-just-version ()
  (my/excali--check-compatible)
  (let ((emacs-major-version 31))
    (should-error (my/excali--check-compatible) :type 'user-error))
  (cl-letf (((symbol-function 'canvas-refresh) nil))
    (should-error (my/excali--check-compatible) :type 'user-error)))

(ert-deftest my/excali-background-validates-before-changing ()
  (with-temp-buffer
    (should-error (my/excali-set-canvas-background "red") :type 'user-error))
  (my/excali-test-scene
   (let ((before (copy-tree excali--doc)))
     (should-error (my/excali-set-canvas-background "not-a-real-color") :type 'user-error)
     (should (equal before excali--doc))
     (should-not (buffer-modified-p)))
   (my/excali-set-canvas-background "red")
   (should (equal (excali--canvas-color) "#ff0000"))
   (my/excali-set-canvas-background "#f0eddf")
   (should (equal (excali--canvas-color) "#f0eddf"))
   (should (buffer-modified-p))))

(ert-deftest my/excali-background-prompt-accepts-theme-default ()
  (my/excali-test-scene
   (cl-letf (((symbol-function 'face-background) (lambda (&rest _) "#f0eddf"))
             ((symbol-function 'read-color)
              (lambda (prompt _convert allow-empty)
                (should (string-match-p "#f0eddf" prompt))
                (should allow-empty)
                "")))
     (call-interactively #'my/excali-set-canvas-background))
   (should (equal (excali--canvas-color) "#f0eddf"))))

(ert-deftest my/excali-opening-native-or-embedded-scenes-preserves-colours ()
  (my/excali-test-scene
   (dolist (file '("/existing.excalidraw" nil))
     ;; Embedded PNG/SVG imports also use nil for the native save path.
     (setq excali--file file)
     (my/excali--after-open)
     (should (equal (excali--canvas-color) "#ffffff"))
     (should-not (buffer-modified-p)))
   (let ((before (copy-tree excali--doc)))
     (run-hook-with-args 'disable-theme-functions 'old-theme)
     (run-hook-with-args 'enable-theme-functions 'new-theme)
     (should (equal before excali--doc)))))

(ert-deftest my/excali-native-new-drawing-uses-theme-once ()
  (let ((root (make-temp-file "excali-mode-" t)))
    (unwind-protect
        (let ((my/excali-directory root))
          (with-temp-buffer
            (excali-mode)
            (should (local-variable-p 'excali-after-open-hook))
            (should (memq #'my/excali--after-open excali-after-open-hook))
            (should (advice-member-p #'my/excali--new-drawing 'excali-new))
            (setq excali--doc (excali--empty-doc))
            (cl-letf (((symbol-function 'excali--render) #'ignore)
                      ((symbol-function 'face-background) (lambda (&rest _) "#f0eddf"))
                      ((symbol-function 'face-foreground) (lambda (&rest _) "#282820")))
              (my/excali--new-drawing (lambda () (run-hooks 'excali-after-open-hook))))
            (should (equal (excali--canvas-color) "#f0eddf"))
            (should (equal (alist-get 'strokeColor excali--current-style) "#282820"))
            (should (equal default-directory (file-name-as-directory root)))))
      (delete-directory root t))))

(ert-deftest my/excali-entry-points-use-default-directory-without-restricting-paths ()
  (let ((root (make-temp-file "excali-directory-" t)))
    (unwind-protect
        (let ((my/excali-directory (expand-file-name "diagrams" root)))
          (cl-letf (((symbol-function 'excali-new)
                     (lambda () (should (equal default-directory
                                              (file-name-as-directory my/excali-directory))))))
            (my/excali-new))
          (cl-letf (((symbol-function 'read-file-name)
                     (lambda (_prompt directory &rest _)
                       (should (equal directory (file-name-as-directory my/excali-directory)))
                       "/elsewhere/diagram.excalidraw"))
                    ((symbol-function 'excali-open)
                     (lambda (file) (should (equal file "/elsewhere/diagram.excalidraw")))))
            (call-interactively #'my/excali-open)))
      (delete-directory root t))))

(ert-deftest my/excali-background-survives-save-and-restore ()
  (let ((file (make-temp-file "excali-save-" nil ".excalidraw")))
    (unwind-protect
        (my/excali-test-scene
         (setq excali--file file)
         (my/excali-set-canvas-background "#f0eddf")
         (excali-save)
         (let ((doc (excali--restore-doc (excali--read-file file))))
           (should (equal (alist-get 'viewBackgroundColor (alist-get 'appState doc)) "#f0eddf"))
           (should-not (alist-get 'customData doc))))
      (delete-file file))))

(provide 'my-emacs-excali-tests)
;;; my-emacs-excali-tests.el ends here
