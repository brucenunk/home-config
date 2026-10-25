;;; my-emacs-excali-tests.el --- Drawing integration checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'excali)
(require 'my-emacs-excali)

(defun my/excali-test--fresh-emacs (&rest forms)
  "Check FORMS in a fresh Emacs with the current test's package paths."
  (with-temp-buffer
    (let ((status
           (call-process
            (expand-file-name invocation-name invocation-directory)
            nil t nil "--batch" "-Q"
            "--eval" (prin1-to-string `(setq load-path ',load-path))
            "--eval" "(require 'ert)"
            "--load" "my-emacs-excali"
            "--eval" (prin1-to-string `(progn ,@forms)))))
      (ert-info ((buffer-string))
        (should (equal status 0))))))

(ert-deftest my/excali-startup-is-lazy-and-defers-configuration ()
  (my/excali-test--fresh-emacs
   '(progn
      (should-not (featurep 'excali))
      (should-not (featurep 'excali-dsl))
      (dolist (command '(excali-open excali-new))
        (should (commandp command))
        (should (autoloadp (symbol-function command)))
        (should (equal (nth 1 (symbol-function command)) "excali")))
      (should (autoloadp (symbol-function 'excali-dsl-mode)))
      (should (equal (nth 1 (symbol-function 'excali-dsl-mode)) "excali-dsl"))
      (should (eq (cdr (assoc "\\.excalidsl\\'" auto-mode-alist)) 'excali-dsl-mode))
      (with-temp-buffer
        (setq buffer-file-name "drawing.excalidraw")
        (set-auto-mode)
        (should-not (derived-mode-p 'excali-mode 'excali-dsl-mode)))
      (should-not (featurep 'excali))
      (require 'excali)
      (should (advice-member-p #'my/excali--new-drawing 'excali-new))
      (should (memq #'my/excali--setup-buffer excali-mode-hook))
      (should (assq 6 excali-font-families))
      (should (assq 8 excali-font-families)))))

(ert-deftest my/excali-dsl-file-visits-work-before-opening-a-canvas ()
  (my/excali-test--fresh-emacs
   '(let ((file (make-temp-file "excali-source-" nil ".excalidsl"))
          buffer)
      (unwind-protect
          (progn
            (setq buffer (find-file-noselect file))
            (with-current-buffer buffer
              (should (eq major-mode 'excali-dsl-mode)))
            (should (featurep 'excali-dsl))
            (should-not (featurep 'excali)))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (delete-file file)))))

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
   ;; Named system colours differ between macOS GUI and terminal/X11.
   (should (equal (excali--canvas-color) (my/excali--hex "red")))
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

(defconst my/excali-test--palette-directory
  (let ((local (expand-file-name "../../excali/palettes/"
                                  (file-name-directory load-file-name))))
    (if (file-directory-p local) local my/excali-palette-directory)))

(defmacro my/excali-test--opening (&rest body)
  "Exercise native opening with only GUI presentation stubbed out."
  `(let ((my/excali-palette-directory my/excali-test--palette-directory))
     (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
               ((symbol-function 'image-type-available-p) (lambda (&rest _) t))
               ((symbol-function 'excali--sync-canvas) #'ignore)
               ((symbol-function 'excali--render) #'ignore)
               ((symbol-function 'excali--sync-views) #'ignore))
       (save-window-excursion
         (let (opened)
           (unwind-protect
               (progn
                 (advice-add 'excali--open :filter-return
                             (lambda (buffer) (push buffer opened) buffer)
                             '((name . my-excali-test-track)))
                 ,@body)
             (advice-remove 'excali--open 'my-excali-test-track)
             (dolist (buffer opened)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer (set-buffer-modified-p nil))
                 (kill-buffer buffer)))))))))

(ert-deftest my/excali-real-new-initializes-and-roundtrips-provenance ()
  (let ((root (make-temp-file "excali-new-" t)))
    (unwind-protect
        (my/excali-test--opening
         (let ((my/excali-directory root) (custom-enabled-themes '(doric-earth)))
           (excali-new)
           (let ((palette (my/excali--read-palette "doric-earth")))
             (should (equal my/excali--palette palette))
             (should (equal (excali--canvas-color) (alist-get 'canvas palette)))
             (should (equal (excali--style-value 'backgroundColor) "transparent"))
             (should (equal (excali--style-value 'strokeColor)
                            (alist-get 'stroke (alist-get 'default (alist-get 'presets palette)))))
             (setf (alist-get 'customData excali--doc) '((unrelated . "keep")))
             (setq excali--file (expand-file-name "new.excalidraw" root))
             (excali-save)
             (let ((file excali--file)
                   (metadata (copy-tree (alist-get 'homeConfigPalette excali--doc) t)))
               (my/excali-choose-palette "doric-obsidian")
               (should (equal metadata (alist-get 'homeConfigPalette excali--doc)))
               (let ((custom-enabled-themes '(doric-obsidian))) (excali-open file))
               (should (equal metadata (alist-get 'homeConfigPalette excali--doc)))
               (should (equal my/excali--palette palette))
               (should (equal (alist-get 'customData excali--doc) '((unrelated . "keep"))))))))
      (delete-directory root t))))

(ert-deftest my/excali-real-native-and-image-imports-preserve-saved-styling ()
  (let ((root (make-temp-file "excali-import-" t)))
    (unwind-protect
        (my/excali-test--opening
         (let* ((custom-enabled-themes '(doric-earth))
                (file (expand-file-name "fixed.excalidraw" root))
                (doc (excali--empty-doc)))
           (setf (alist-get 'viewBackgroundColor (alist-get 'appState doc)) "#123456"
                 (alist-get 'currentItemStrokeColor (alist-get 'appState doc)) "#fedcba")
           (with-temp-file file
             (insert (excali--serialize-doc doc
                      (list (excali--make-element "rectangle" 0 0
                             '(width . 200) '(height . 100)
                             '(strokeColor . "#abcdef") '(customData . ((other . 42))))))))
           (excali-open file)
           (excali-export-svg (expand-file-name "fixed.svg" root))
           (excali-export-png (expand-file-name "fixed.png" root))
           (dolist (suffix '("excalidraw" "svg" "png"))
             (excali-open (expand-file-name (concat "fixed." suffix) root))
             (should (equal (excali--canvas-color) "#123456"))
             (should (equal (excali--style-value 'strokeColor) "#fedcba"))
             (should (equal (excali--get (car excali--elements) 'strokeColor) "#abcdef"))
             (should-not my/excali--palette)
             (should-not (alist-get 'homeConfigPalette excali--doc))
             (unless (equal suffix "excalidraw") (should-not excali--file)))))
      (delete-directory root t))))

(defmacro my/excali-test--styled-scene (&rest body)
  `(my/excali-test-scene
    (let ((my/excali-palette-directory my/excali-test--palette-directory))
      (setq my/excali--palette (my/excali--read-palette "doric-earth")
            excali--elements
            (list (excali--make-element "rectangle" 0 0 '(id . "box")
                                       '(width . 100) '(height . 100)
                                       '(customData . ((other . 42))))
                  (excali--make-text-element 0 0 "Label" '(id . "label")
                                            '(containerId . "box"))
                  (excali--make-element "arrow" 0 200 '(id . "arrow")
                                       '(points . [[0 0] [100 0]]))
                  (excali--make-text-element 0 200 "Arrow label" '(id . "arrow-label")
                                            '(containerId . "arrow"))
                  (excali--make-text-element 0 300 "Standalone" '(id . "free"))
                  (excali--make-element "rectangle" 300 0 '(id . "fixed")
                                       '(width . 100) '(height . 100)
                                       '(strokeColor . "#ff0000"))))
      (excali--history-reset)
      ,@body)))

(ert-deftest my/excali-presets-pair-labels-and-preserve-fixed-elements ()
  (my/excali-test--styled-scene
   (let* ((fixed (copy-tree (nth 5 excali--elements) t))
          (preset (alist-get 'accented (alist-get 'presets my/excali--palette))))
     (setq excali--selection (list (nth 0 excali--elements) (nth 2 excali--elements)
                                 (nth 4 excali--elements)))
     (my/excali-use-preset 'accented)
     (should (equal (excali--get (nth 0 excali--elements) 'backgroundColor) (alist-get 'fill preset)))
     (should (equal (excali--get (nth 1 excali--elements) 'strokeColor)
                    (my/excali--text-color (alist-get 'text preset) (alist-get 'fill preset))))
     (dolist (index '(3 4))
       (should (equal (excali--get (nth index excali--elements) 'strokeColor)
                      (my/excali--text-color (alist-get 'text preset) "#ffffff"))))
     (should (equal fixed (nth 5 excali--elements)))
     (should (equal (excali--get (car excali--elements) 'customData) '((other . 42))))
     (should (= (length excali--undo-stack) 2)))))

(ert-deftest my/excali-palette-and-theme-changes-preserve-redo ()
  (my/excali-test--styled-scene
   (setq excali--selection (list (car excali--elements)))
   (my/excali-use-preset 'neutral)
   (let ((styled (copy-tree excali--elements t)))
     (excali-undo)
     (let ((undo excali--undo-stack) (redo excali--redo-stack)
           (scene (copy-tree excali--elements t)))
       (my/excali-choose-palette "doric-obsidian")
       (run-hook-with-args 'disable-theme-functions 'doric-earth)
       (run-hook-with-args 'enable-theme-functions 'doric-obsidian)
       (should (eq undo excali--undo-stack))
       (should (eq redo excali--redo-stack))
       (should (equal scene excali--elements)))
     (excali-redo)
     (should (equal styled excali--elements))
     ;; A subsequent geometry edit and undo must restore the styled scene.
     (excali--put (car excali--elements) 'x 123)
     (excali--touch (car excali--elements))
     (excali--commit)
     (excali-undo)
     (should (equal styled excali--elements))
     (excali-redo)
     (should (= (excali--get (car excali--elements) 'x) 123)))))

(ert-deftest my/excali-no-op-preset-preserves-redo-and-current-defaults-save ()
  (my/excali-test--styled-scene
   (setq excali--selection (list (car excali--elements)))
   (my/excali-use-preset 'neutral)
   (excali-undo)
   (setq excali--selection nil)
   (let ((redo excali--redo-stack))
     (my/excali-use-preset 'accented)
     (should (eq redo excali--redo-stack))
     (let ((state (excali--save-current-style nil)))
       (excali--load-current-style state)
       (should (equal (excali--style-value 'backgroundColor)
                      (alist-get 'fill (alist-get 'accented (alist-get 'presets my/excali--palette)))))))))

(ert-deftest my/excali-label-lookup-is-linear-and-does-not-scan-per-label ()
  (my/excali-test--styled-scene
   (setq excali--selection excali--elements)
   (cl-letf (((symbol-function 'excali--element-by-id)
              (lambda (&rest _) (ert-fail "Repeated parent lookup"))))
     (my/excali-use-preset 'neutral))))

(ert-deftest my/excali-preset-colours-survive-real-save-and-reopen ()
  (let ((file (make-temp-file "excali-styled-" nil ".excalidraw")))
    (unwind-protect
        (my/excali-test--opening
         (let (expected)
           (my/excali-test--styled-scene
            (setq excali--selection (list (car excali--elements))
                  excali--file file)
            (my/excali-use-preset 'neutral)
            (setq expected (mapcar (lambda (e) (excali--get e 'strokeColor)) excali--elements))
            (excali-save))
           (excali-open file)
           (let ((box (cl-find "box" excali--elements :key (lambda (e) (excali--get e 'id)) :test #'equal))
                 (fixed (cl-find "fixed" excali--elements :key (lambda (e) (excali--get e 'id)) :test #'equal)))
             (should (equal (excali--get box 'strokeColor) (car expected)))
             (should (equal (excali--get box 'customData) '((other . 42))))
             (should (equal (excali--get fixed 'strokeColor) "#ff0000")))))
      (delete-file file))))

(ert-deftest my/excali-new-labels-use-actual-background-until-native-override ()
  (my/excali-test--styled-scene
   (setq excali--selection (list (car excali--elements)))
   (my/excali-use-preset 'accented)
   (let* ((preset (alist-get 'accented (alist-get 'presets my/excali--palette)))
          (bound (excali--apply-current-style
                  (excali--make-text-element 0 0 "New bound" '(containerId . "box"))))
          (free (excali--apply-current-style (excali--make-text-element 0 0 "New free"))))
     (should (equal (excali--get bound 'strokeColor)
                    (my/excali--text-color (alist-get 'text preset) (alist-get 'fill preset))))
     (should (equal (excali--get free 'strokeColor)
                    (my/excali--text-color (alist-get 'text preset) "#ffffff"))))
   (setq excali--selection nil)
   (excali-set-style 'strokeColor "#ff0000")
   (should-not my/excali--current-preset)
   (should (equal (excali--get
                   (excali--apply-current-style (excali--make-text-element 0 0 "Fixed"))
                   'strokeColor) "#ff0000"))))

(ert-deftest my/excali-palette-browsing-preserves-applied-creation-colours ()
  (my/excali-test--styled-scene
   (my/excali-choose-palette "doric-obsidian")
   (my/excali-use-preset 'neutral)
   (let* ((applied (copy-tree my/excali--current-preset))
          (defaults (copy-tree excali--current-style))
          (before (excali--get
                   (excali--apply-current-style (excali--make-text-element 0 0 "Before"))
                   'strokeColor)))
     ;; Keep redo pending while merely browsing a different palette.
     (excali--put (car excali--elements) 'x 123)
     (excali--touch (car excali--elements))
     (excali--commit)
     (excali-undo)
     (let ((redo excali--redo-stack) (undo excali--undo-stack)
           (scene (copy-tree excali--elements t)))
       (my/excali-choose-palette "doric-earth")
       (should (equal applied my/excali--current-preset))
       (should (equal defaults excali--current-style))
       (should (eq redo excali--redo-stack))
       (should (eq undo excali--undo-stack))
       (should (equal scene excali--elements)))
     (should (equal before "#000000"))
     (should (equal before (excali--get
                           (excali--apply-current-style (excali--make-text-element 0 0 "After"))
                           'strokeColor)))
     ;; The next explicit preset replaces the snapshot, not a reference into
     ;; the palette browser's mutable data.
     (my/excali-use-preset 'accented)
     (let ((preset (alist-get 'accented (alist-get 'presets my/excali--palette))))
       (should (equal preset my/excali--current-preset))
       (setf (alist-get 'text preset) "#ff0000")
       (should-not (equal preset my/excali--current-preset))))))

(ert-deftest my/excali-sticky-creation-and-later-labels-stay-native ()
  (my/excali-test--styled-scene
   (my/excali-choose-palette "doric-obsidian")
   (dolist (role my/excali--presets)
     (setq excali--elements nil excali--selection nil)
     (my/excali-use-preset role)
     ;; Create an empty native note, then enter text through the real editing
     ;; command after applying a preset.  Both creation paths stay native.
     (cl-letf (((symbol-function 'excali--drag-loop) #'ignore)
               ((symbol-function 'excali-edit-text) #'ignore))
       (excali--create-sticky-note '(100 . 100)))
     (let ((note (car excali--selection)))
       (should (equal (excali--get note 'type) "stickynote"))
       (should (equal (excali--get note 'backgroundColor) "#ffdf6b"))
       (should (equal (excali--get note 'strokeColor) "#1e1e1e"))
       (my/excali-use-preset role)
       (cl-letf (((symbol-function 'excali--edit-text-live) (lambda (&rest _) "Native note")))
         (excali-edit-text))
       (let ((label (excali--bound-text-of note))
             (before (copy-tree excali--elements t)))
         (should (equal (excali--get label 'strokeColor) (excali--style-value 'strokeColor)))
         (setq excali--selection (list note label))
         (my/excali-use-preset role)
         (should (equal before excali--elements)))))))

(ert-deftest my/excali-native-alpha-colours-and-labels ()
  (my/excali-test--styled-scene
   ;; Imported/native RGBA remains editable, including a translucent canvas.
   (setf (alist-get 'viewBackgroundColor (alist-get 'appState excali--doc)) "#00000080")
   (let ((parent (car excali--elements)))
     (excali--put parent 'backgroundColor "#ff000080")
     (excali--put parent 'fillStyle "solid")
     (excali--put parent 'opacity 50)
     (should (equal (my/excali--label-background parent) "#9f5f5f"))
     (setq excali--selection (list (nth 1 excali--elements)))
     (my/excali-use-preset 'neutral)
     (should (equal (excali--get parent 'backgroundColor) "#ff000080"))
     (should (stringp (excali--get (nth 1 excali--elements) 'strokeColor)))
     (let ((label (excali--apply-current-style
                   (excali--make-text-element 0 0 "RGBA label" '(containerId . "box")))))
       (should (equal (excali--get label 'strokeColor)
                      (my/excali--text-color
                       (alist-get 'text (alist-get 'neutral (alist-get 'presets my/excali--palette)))
                       (my/excali--label-background parent))))))))

(ert-deftest my/excali-presets-skip-selected-notes-and-labels-in-mixed-scenes ()
  (my/excali-test--styled-scene
   (let* ((note (excali--make-element "stickynote" 500 0 '(id . "note")
                                      '(width . 250) '(height . 250)
                                      '(backgroundColor . "#ffdf6b")
                                      '(customData . ((keep . "native")))))
          (label (excali--make-text-element 500 0 "Native" '(containerId . "note"))))
     (setq excali--elements (append excali--elements (list note label)))
     (dolist (role my/excali--presets)
       (let ((before (copy-tree (list note label) t)))
         ;; Mixed selection still styles ordinary shapes and their labels.
         (setq excali--selection (list (car excali--elements) note label))
         (my/excali-use-preset role)
         (should (equal before (list note label)))
         (should (equal (excali--get (car excali--elements) 'backgroundColor)
                        (alist-get 'fill (alist-get role (alist-get 'presets my/excali--palette)))))))
     ;; A note/label-only selection must not add undo edits or discard redo.
     (excali--history-reset)
     (excali--put (car excali--elements) 'x 123)
     (excali--touch (car excali--elements))
     (excali--commit)
     (excali-undo)
     (let ((redo excali--redo-stack) (scene (copy-tree excali--elements t)))
       (dolist (property '(id containerId))
         (setq excali--selection
               (list (cl-find "note" excali--elements
                              :key (lambda (e) (excali--get e property)) :test #'equal)))
         (my/excali-use-preset 'neutral)
         (should (eq redo excali--redo-stack))
         (should (equal scene excali--elements)))))))

(ert-deftest my/excali-deleted-labels-do-not-create-spurious-history ()
  (my/excali-test--styled-scene
   (let ((deleted (excali--make-text-element 0 0 "Deleted"
                    '(containerId . "box") '(isDeleted . t) '(strokeColor . "#ff0000"))))
     (push deleted excali--elements)
     (setq excali--selection (list (nth 1 excali--elements)))
     (my/excali-use-preset 'neutral)
     (should (equal (excali--get deleted 'strokeColor) "#ff0000"))
     (excali--put (nth 1 excali--elements) 'x 123)
     (excali--touch (nth 1 excali--elements))
     (excali--commit)
     (excali-undo)
     (let ((redo excali--redo-stack))
       (my/excali-use-preset 'neutral)
       (should (eq redo excali--redo-stack))))))

(ert-deftest my/excali-shorthand-rgba-canvas-and-container ()
  (my/excali-test--styled-scene
   (setf (alist-get 'viewBackgroundColor (alist-get 'appState excali--doc)) "#fff8")
   (let ((parent (car excali--elements)))
     (excali--put parent 'backgroundColor "#f008")
     (excali--put parent 'fillStyle "solid")
     (should (equal (my/excali--label-background parent) "#ff7777"))
     (setq my/excali--current-preset
           (copy-tree (alist-get 'neutral (alist-get 'presets my/excali--palette))))
     (should (excali--apply-current-style
              (excali--make-text-element 0 0 "Short RGBA" '(containerId . "box"))))
     (setq excali--selection (list parent))
     (my/excali-use-preset 'neutral))))

(ert-deftest my/excali-real-open-ignores-malformed-optional-provenance ()
  (let ((file (make-temp-file "excali-provenance-" nil ".excalidraw")))
    (unwind-protect
        (my/excali-test--opening
         (dolist (metadata '(:null "not-an-object" 42 [1] ((initialPalette . :null))))
           (let ((doc (excali--empty-doc)))
             (setf (alist-get 'homeConfigPalette doc) metadata
                   (alist-get 'viewBackgroundColor (alist-get 'appState doc)) "#123456")
             (with-temp-file file (insert (excali--serialize-doc doc nil))))
           (excali-open file)
           (should (equal (alist-get 'homeConfigPalette excali--doc) metadata))
           (should (equal (excali--canvas-color) "#123456"))
           (should-not my/excali--palette)))
      (delete-file file))))

(ert-deftest my/excali-eyedropper-overrides-new-text-styling ()
  (my/excali-test--styled-scene
   (my/excali-use-preset 'neutral)
   (setq excali--selection nil)
   (excali--eyedropper-apply 'stroke "#ff0000" nil)
   (should-not my/excali--current-preset)
   (should (equal (excali--get
                   (excali--apply-current-style (excali--make-text-element 0 0 "Picked"))
                   'strokeColor) "#ff0000"))))

(ert-deftest my/excali-invalid-palette-does-not-change-document ()
  (my/excali-test--styled-scene
   (let ((my/excali--palette '((version . 9)))
         (before (copy-tree excali--elements t)))
     (should-error (my/excali-use-preset 'neutral) :type 'user-error)
     (should (equal before excali--elements)))))

(ert-deftest my/excali-graphical-multi-view-refresh-with-unchanged-canvas ()
  (skip-unless (display-graphic-p))
  (let ((my/excali-palette-directory my/excali-test--palette-directory)
        (custom-enabled-themes '(doric-earth))
        buffer frame)
    (save-window-excursion
      (unwind-protect
          (progn
            (excali-new)
            (setq buffer (current-buffer)
                  excali--elements (list (excali--make-element "rectangle" 10 10
                                          '(width . 100) '(height . 80)))
                  excali--selection excali--elements)
            (excali--history-reset)
            (excali--render)
            (let ((second (split-window-right)))
              (set-window-buffer second buffer)
              (excali--sync-canvas second)
              (setq frame (make-frame '((name . "Excali isolated second frame"))))
              (set-window-buffer (frame-selected-window frame) buffer)
              (excali--sync-canvas (frame-selected-window frame))
              (let ((background (excali--canvas-color)))
                (my/excali-use-preset 'neutral)
                (my/excali-choose-palette "doric-obsidian")
                (my/excali-use-preset 'accented)
                (should (equal background (excali--canvas-color)))
                (let ((stamp (excali--scene-stamp)))
                  (dolist (window (list second (frame-selected-window frame)))
                    (should (equal stamp (excali--view-value window 'excali--view-stamp))))))))
        (when (frame-live-p frame) (delete-frame frame))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest my/excali-native-menu-keeps-original-pickers ()
  (should (transient-get-suffix 'excali-style "s"))
  (should (transient-get-suffix 'excali-style "P"))
  (my/excali--install-palette-menu)
  (should (transient-get-suffix 'excali-style "P")))

(ert-deftest my/excali-generated-palettes-match-doric-face-pairs ()
  (require 'doric-themes)
  (let ((my/excali-palette-directory my/excali-test--palette-directory))
    (unwind-protect
        (dolist (theme doric-themes-collection)
          (mapc #'disable-theme custom-enabled-themes)
          (load-theme theme t)
          (let* ((palette (my/excali--read-palette (symbol-name theme)))
                 (presets (alist-get 'presets palette)))
            (should (equal (alist-get 'canvas palette) (face-background 'default nil t)))
            (should (equal (alist-get 'stroke (alist-get 'default presets)) (face-foreground 'default nil t)))
            (should (equal (alist-get 'fill (alist-get 'neutral presets)) (face-background 'highlight nil t)))
            (should (equal (alist-get 'fill (alist-get 'accented presets)) (face-background 'region nil t)))
            (should (equal (alist-get 'text (alist-get 'accented presets)) (face-foreground 'region nil t)))
            (should (equal (alist-get 'stroke (alist-get 'muted presets)) (face-foreground 'shadow nil t)))))
      (mapc #'disable-theme custom-enabled-themes))))

(provide 'my-emacs-excali-tests)
;;; my-emacs-excali-tests.el ends here
