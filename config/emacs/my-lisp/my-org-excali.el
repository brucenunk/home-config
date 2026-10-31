;;; my-org-excali.el --- Org drawing integration -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Implementation for the configuration in my-emacs.org.
;; Public functions/commands:
;;   - my/excali-org-new
;;   - my/excali-org-save-and-return
;;   - my/excali-org-cancel
;;   - my/excali-org-register

;;   - my/excali-org-register

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'my-excali)

(defcustom my/excali-preview-directory
  (expand-file-name "excali/" (or (getenv "XDG_CACHE_HOME") "~/.cache/"))
  "Disposable SVG cache for Org previews and publication assets."
  :type 'directory :group 'my-excali)

(defcustom my/excali-org-preview-width 120
  "Default maximum Org preview width in frame character units.
Each unit is the base character width of the preview window's frame, not
the buffer's remapped prose font.  This follows frame font changes while
remaining stable across local text zoom and Writeroom entry/exit.
Previews shrink to the available text area.  An explicit ATTR_ORG width
overrides this cap, but cannot exceed that area."
  :type 'natnum :group 'my-excali)

(defun my/excali--org-base ()
  "Return the containing Org file's directory, never incidental cwd."
  (let ((file (or buffer-file-name
                  (buffer-file-name (buffer-base-buffer)))))
    (unless file
      (user-error "Save the Org document before using excali links"))
    (file-name-directory file)))

(defun my/excali--org-source (path)
  "Resolve and validate Org link PATH."
  (let ((file (expand-file-name (org-link-unescape path) (my/excali--org-base))))
    (unless (and (equal (file-name-extension file) "excalidraw")
                 (file-regular-p file) (file-readable-p file))
      (user-error "Missing or unreadable .excalidraw source: %s" file))
    file))

(defun my/excali--org-complete (&optional _arg)
  "Complete a scene filename and return a relative excali link."
  (let* ((base (my/excali--org-base))
         (file (read-file-name
                "Excalidraw scene: " my/excali-directory nil t nil
                (lambda (file)
                  (or (file-directory-p file)
                      (equal (file-name-extension file) "excalidraw"))))))
    (concat "excali:" (org-link-escape
                       (file-relative-name (my/excali--org-source file) base)))))

(defun my/excali--org-follow (path _arg)
  "Open authoritative scene PATH through the existing drawing integration."
  (my/excali-open (my/excali--org-source path)))

(defvar-local my/excali--org-origin nil "Origin insertion marker for this drawing.")

(defvar-local my/excali--org-window nil "Window from which this drawing was created.")

(defvar-local my/excali--org-target nil "Chosen new drawing filename.")

(defvar-local my/excali--org-saved nil "Whether this workflow has saved its target.")

(defvar-local my/excali--org-linked nil "Whether this workflow inserted its link.")

(defvar-local my/excali--org-baseline nil "Scene fingerprint at creation or last save.")

(defun my/excali--org-scene-fingerprint ()
  "Fingerprint persistent scene data, including current drawing defaults."
  (let ((doc (copy-alist excali--doc)))
    (setf (alist-get 'appState doc)
          (excali--save-current-style (alist-get 'appState doc)))
    (secure-hash 'sha256 (excali--serialize-doc doc excali--elements))))

(defun my/excali--org-can-kill ()
  "Confirm before discarding changes in a workflow drawing only."
  (or (equal my/excali--org-baseline (my/excali--org-scene-fingerprint))
      (yes-or-no-p "Discard unsaved drawing work? ")))

(defun my/excali--org-release-origin ()
  "Release this drawing's insertion marker when it is killed."
  (when (markerp my/excali--org-origin)
    (set-marker my/excali--org-origin nil)))

(define-minor-mode my/excali-org-creation-mode
  "Private buffer-local bindings for a drawing created from Org."
  :lighter " Org drawing"
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-c") #'my/excali-org-save-and-return)
            (define-key map (kbd "C-c C-k") #'my/excali-org-cancel)
            map))

(defun my/excali--org-path-key (file)
  "Canonicalize FILE for reservations, respecting its filesystem's case rules."
  (let ((canonical (file-truename file)))
    ;; FILE need not exist yet, so query its existing containing directory.
    (if (file-name-case-insensitive-p (file-name-directory canonical))
        (downcase canonical)
      canonical)))

(defun my/excali--org-check-new-path (file)
  "Reject existing FILE and another workflow's reserved path."
  (when (or (file-exists-p file) (file-symlink-p file)
            (seq-some
             (lambda (buffer)
               (and (not (eq buffer (current-buffer)))
                    (buffer-local-value 'my/excali-org-creation-mode buffer)
                    (equal (my/excali--org-path-key file)
                           (my/excali--org-path-key
                            (buffer-local-value 'my/excali--org-target buffer)))))
             (buffer-list)))
    (user-error "Drawing path already exists or is in use: %s" file)))

;;;###autoload
(defun my/excali-org-new (file)
  "Create a themed drawing for FILE, remembering this saved Org location.
Do not create FILE or insert a link until explicitly saved."
  (interactive
   (progn
     (unless (derived-mode-p 'org-mode) (user-error "Select an Org document first"))
     (my/excali--org-base)
     (barf-if-buffer-read-only)
     (list (read-file-name "New drawing: " my/excali-directory))))
  (unless (derived-mode-p 'org-mode) (user-error "Select an Org document first"))
  (my/excali--org-base)
  (barf-if-buffer-read-only)
  (setq file (expand-file-name file my/excali-directory))
  (unless (file-name-extension file) (setq file (concat file ".excalidraw")))
  (unless (equal (file-name-extension file) "excalidraw")
    (user-error "Choose an .excalidraw filename"))
  (my/excali--org-check-new-path file)
  (unless (file-directory-p (file-name-directory file))
    (user-error "Choose an existing directory: %s" (file-name-directory file)))
  (let ((origin (copy-marker (point) t))
        (window (selected-window))
        ready)
    (unwind-protect
        (progn
          (my/excali-new)
          (setq my/excali--org-origin origin
                my/excali--org-window window
                my/excali--org-target file
                excali--file file
                my/excali--org-baseline (my/excali--org-scene-fingerprint))
          (my/excali-org-creation-mode 1)
          (add-hook 'kill-buffer-query-functions #'my/excali--org-can-kill nil t)
          (add-hook 'kill-buffer-hook #'my/excali--org-release-origin nil t)
          (setq ready t)
          (message "Draw, then C-c C-c to save and return; C-c C-k to cancel"))
      (unless ready (set-marker origin nil)))))

(defun my/excali--org-workflow-save (save &rest args)
  "Call native SAVE, protecting the first write of a workflow target.
Unrelated drawings retain native save behavior.  A temporary sibling and
exclusive rename avoid overwriting a file created since naming the drawing."
  (if (not my/excali-org-creation-mode)
      (apply save args)
    (unless (equal excali--file my/excali--org-target)
      (user-error "Workflow drawing path changed; expected %s" my/excali--org-target))
    (let ((first-save (not my/excali--org-saved)))
      (if (not first-save)
          (apply save args)
        (my/excali--org-check-new-path my/excali--org-target)
        (let ((temporary (make-temp-file
                          (expand-file-name ".excali-new-"
                                            (file-name-directory my/excali--org-target)))))
          (unwind-protect
              (progn
                (let ((excali--file temporary)) (apply save args))
                (rename-file temporary my/excali--org-target nil)
                (setq my/excali--org-saved t))
            (when (file-exists-p temporary) (delete-file temporary)))))
      (setq my/excali--org-baseline (my/excali--org-scene-fingerprint))
      (set-buffer-modified-p nil)
      ;; Only the first save needs notification: native advice saw its temp path.
      (when first-save (my/excali--org-after-save)))
    (message "Saved %s" my/excali--org-target)))

(defun my/excali--org-return (origin window)
  "Return to ORIGIN in WINDOW if it survives, otherwise the current window."
  (unless (and (markerp origin) (marker-buffer origin))
    (user-error "Origin document is no longer available"))
  (when (window-live-p window) (select-window window))
  (switch-to-buffer (marker-buffer origin))
  (when (<= (point-min) origin (point-max)) (goto-char origin)))

;;;###autoload
(defun my/excali-org-save-and-return ()
  "Save this workflow drawing, insert its relative link once, and return."
  (interactive)
  (unless my/excali-org-creation-mode (user-error "Not an Org drawing workflow"))
  (excali-save)
  (let ((origin my/excali--org-origin)
        (window my/excali--org-window)
        (file my/excali--org-target)
        (drawing (current-buffer)))
    (condition-case err
        (progn
          (unless (and (markerp origin) (marker-buffer origin))
            (user-error "Origin document is no longer available"))
          (with-current-buffer (marker-buffer origin)
            (unless (and (derived-mode-p 'org-mode)
                         (<= (point-min) origin (point-max)))
              (user-error "Origin insertion location is unavailable"))
            (unless (buffer-local-value 'my/excali--org-linked drawing)
              (barf-if-buffer-read-only)
              (let ((link (org-link-make-string
                           (concat "excali:" (org-link-escape
                                             (file-relative-name file (my/excali--org-base)))))))
                (save-excursion
                  (goto-char origin)
                  (atomic-change-group (insert link)))
                ;; Record success before display, which may fail independently.
                (with-current-buffer drawing (setq my/excali--org-linked t)))))
          (my/excali--org-return origin window)
          (my/excali--org-inserted))
      (error (user-error "Drawing saved at %s; %s" file (error-message-string err))))))

;;;###autoload
(defun my/excali-org-cancel ()
  "Discard this workflow buffer and return, without inserting or deleting files."
  (interactive)
  (unless my/excali-org-creation-mode (user-error "Not an Org drawing workflow"))
  (let ((origin (copy-marker my/excali--org-origin))
        (window my/excali--org-window)
        (file (and my/excali--org-saved my/excali--org-target)))
    (unwind-protect
        (when (kill-buffer (current-buffer))
          (if (marker-buffer origin)
              (my/excali--org-return origin window)
            (message "Origin unavailable%s" (if file (format "; drawing preserved at %s" file) ""))))
      (set-marker origin nil))))

(defun my/excali--org-image (path publication)
  "Return cached SVG for PATH, using Doric Light when PUBLICATION is non-nil."
  (condition-case err
      (require 'excali)
    (error (user-error "Excalidraw previews require the native excali renderer: %s"
                       (error-message-string err))))
  (let* ((source (my/excali--org-source path))
         (palette (if publication (my/excali--read-palette "doric-light")
                    (my/excali--theme-palette)))
         (digest (with-temp-buffer
                   (insert-file-contents-literally source)
                   (secure-hash 'sha256 (current-buffer))))
         (key (secure-hash 'sha256
                           (prin1-to-string
                            (list 2 digest palette emacs-version
                                  (locate-library "excali")
                                  (and (boundp 'excali-font-families)
                                       excali-font-families)))))
         (output (expand-file-name (concat key ".svg") my/excali-preview-directory)))
    (unless (file-exists-p output)
      (make-directory my/excali-preview-directory t)
      (let ((temporary (make-temp-file (expand-file-name "render-" my/excali-preview-directory)
                                      nil ".svg")))
        (unwind-protect
            (progn
              (my/excali--render-file source (alist-get 'theme palette) temporary)
              (rename-file temporary output t))
          (when (file-exists-p temporary) (delete-file temporary)))))
    output))

(defun my/excali--org-default-width (window)
  "Return WINDOW's frame-font-relative default preview cap in pixels."
  (max 1 (* my/excali-org-preview-width
            (frame-char-width (window-frame window)))))

(defun my/excali--org-size-overlay (overlay window link)
  "Size OVERLAY for WINDOW's prose area, honouring LINK's Org width attribute."
  (require 'ox)
  (let* ((area (max 1 (- (window-body-width window t)
                         (with-selected-window window
                           (line-number-display-width t)))))
         (attribute (org-export-read-attribute
                     :attr_org (org-element-lineage link 'paragraph) :width))
         (width
          (cond
           ((null attribute) (my/excali--org-default-width window))
           ((string-match "\\`\\([0-9]+\\(?:\\.[0-9]+\\)?\\)%\\'" attribute)
            (max 1 (round (* area (/ (string-to-number (match-string 1 attribute)) 100.0)))))
           ((string-match-p "\\`[0-9]+\\(?:px\\)?\\'" attribute)
            (max 1 (string-to-number attribute)))
           ;; Like native Org image sizing, ignore unsupported attributes.
           (t (my/excali--org-default-width window))))
         ;; Never spill into margins, even for oversized explicit widths.
         (width (min area width))
         (file (overlay-get overlay 'my-excali-image))
         (image (overlay-get overlay 'display)))
    (overlay-put overlay 'window window)
    (unless (and image (equal (plist-get (cdr image) :file) file)
                 (= (or (plist-get (cdr image) :width) 0) width))
      (setq image (create-image file 'svg nil :width width :max-width area :scale 1))
      (overlay-put overlay 'display image))
    (overlay-put overlay 'before-string
                 (when (< width area)
                   ;; Default to centre for standalone diagrams, retaining an
                   ;; explicit left/right alignment and inline-prose semantics.
                   (let* ((org-image-align 'center)
                          (align (org-image--align link)))
                     (when (member align '("center" "right"))
                       (propertize " " 'face 'default 'display
                                   (if (equal align "right")
                                       `(space :align-to (- right ,image))
                                     `(space :align-to (- center (0.5 . ,image)))))))))))

(defun my/excali--org-layout (overlays)
  "Reconcile one link's OVERLAYS with its buffer's displayed windows."
  (save-restriction
    (widen)
    (let* ((template (car overlays))
           (link (save-excursion
                   (goto-char (overlay-start template))
                   (org-element-context)))
           (windows (get-buffer-window-list (current-buffer) nil t))
           retained)
      (dolist (window windows)
        (let ((ov (or (seq-find (lambda (ov) (eq (overlay-get ov 'window) window)) overlays)
                      (let ((copy (copy-overlay template)))
                        (overlay-put copy 'org-image-overlay t)
                        (push copy org-link-preview-overlays)
                        copy))))
          (my/excali--org-size-overlay ov window link)
          (push ov retained)))
      ;; Keep one overlay for hidden buffers, for save/theme refresh.
      (unless windows (push template retained))
      (dolist (ov overlays)
        (unless (memq ov retained)
          (delete-overlay ov)
          (setq org-link-preview-overlays (delq ov org-link-preview-overlays)))))))

(defun my/excali--org-resize (&optional _frame)
  "Resize displayed diagrams without rendering scenes or enabling hidden previews.
Use window-specific overlays so two views can have different prose widths."
  ;; Redisplay's window-state hooks do not preserve their caller's captures.
  (save-match-data
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (derived-mode-p 'org-mode)
          (let ((groups (make-hash-table)))
            (dolist (ov org-link-preview-overlays)
              (when (and (eq (overlay-buffer ov) buffer) (overlay-get ov 'my-excali-image))
                (push ov (gethash (overlay-start ov) groups))))
            (maphash (lambda (_beg overlays) (my/excali--org-layout overlays)) groups)))))))

(defun my/excali--org-preview (overlay path link)
  "Display generated SVG for PATH and LINK in Org OVERLAY."
  (when (display-graphic-p)
    (condition-case err
        (let ((source (my/excali--org-source path))
              (image (my/excali--org-image path nil))
              (reused (overlay-get overlay 'my-excali-image)))
          (unless (image-type-available-p 'svg)
            (user-error "This Emacs cannot display SVG images"))
          (require 'image)
          (overlay-put overlay 'my-excali-source source)
          (overlay-put overlay 'my-excali-path path)
          (overlay-put overlay 'my-excali-image image)
          (overlay-put overlay 'face 'default)
          (overlay-put overlay 'keymap image-map)
          (my/excali--org-size-overlay
           overlay (or (get-buffer-window (current-buffer) t) (selected-window)) link)
          ;; Native no-refresh display may reuse and re-register an overlay.
          ;; Reconcile that link's complete group, not unrelated previews.
          (when reused
            (setq org-link-preview-overlays (cons overlay (delq overlay org-link-preview-overlays))))
          (my/excali--org-layout
           (if reused
               (seq-filter (lambda (ov)
                             (and (eq (overlay-buffer ov) (current-buffer))
                                  (= (overlay-start ov) (overlay-start overlay))
                                  (overlay-get ov 'my-excali-image)))
                           (overlays-at (overlay-start overlay)))
             (list overlay)))
          t)
      (error (message "Excalidraw preview: %s" (error-message-string err)) nil))))

(defun my/excali--org-collect-previews (collect)
  "Run COLLECT before processing Org's native queue once.
Custom link scans must not turn each link into a synchronous render batch.
Nested collections leave processing to the outermost call."
  (let ((process (symbol-function 'org-link-preview--process-queue)))
    (cl-letf (((symbol-function 'org-link-preview--process-queue) #'ignore))
      (funcall collect))
    (when org-link-preview--queue (funcall process (current-buffer)))))

(defun my/excali--org-preview-described (preview &optional include-linked refresh beg end)
  "Let PREVIEW include described excali links, without changing other link types."
  (my/excali--org-collect-previews
   (lambda ()
     (funcall preview include-linked refresh beg end)
     (unless include-linked
       (save-excursion
         (goto-char (or beg (point-min)))
         (while (re-search-forward "\\[\\[excali:" end t)
           (let ((link (org-element-context)))
             (when (and (eq (org-element-type link) 'link)
                        (equal (org-element-property :type link) "excali")
                        (org-element-contents-begin link))
               (funcall preview t nil (org-element-begin link) (org-element-end link))))))))))

(defun my/excali--org-cloned ()
  "Give an indirect Org view its own preview tracking and displayed diagrams."
  (when (derived-mode-p 'org-mode)
    ;; The clone copied buffer-local lists, not the overlays or idle timer.
    ;; Never clear/cancel the original buffer's overlays or pending work.
    (setq org-link-preview-overlays nil
          org-link-preview--queue nil
          org-link-preview--timer nil)
    (my/excali--org-display)))

(defun my/excali--org-inserted (&rest _)
  "Preview an excali link just inserted or edited with `org-insert-link'."
  (save-excursion
    (when (> (point) (point-min)) (backward-char))
    (let ((link (org-element-lineage (org-element-context) 'link t)))
      (when (and link (equal (org-element-property :type link) "excali"))
        (org-link-preview-region t t (org-element-begin link) (org-element-end link))))))

(defun my/excali--org-display ()
  "Display excali links when opening an Org document."
  (when (and (or buffer-file-name (buffer-file-name (buffer-base-buffer)))
             (display-graphic-p))
    (my/excali--org-collect-previews
     (lambda ()
       (save-excursion
         (goto-char (point-min))
         (while (re-search-forward "\\[\\[excali:" nil t)
           (let* ((beg (match-beginning 0))
                  (link (org-element-context)))
             (when (and (eq (org-element-type link) 'link)
                        (equal (org-element-property :type link) "excali"))
               (org-link-preview-region nil nil beg (org-element-end link))))))))))

(defun my/excali--org-refresh (&optional source)
  "Refresh displayed excali overlays, restricting to SOURCE when supplied."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'org-mode)
        (dolist (ov (copy-sequence org-link-preview-overlays))
          (when-let* ((file (overlay-get ov 'my-excali-source))
                      ((or (null source) (file-equal-p file source)))
                      ((eq (overlay-buffer ov) buffer)))
            (let ((beg (overlay-start ov)) (end (overlay-end ov)))
              ;; Native refresh flushes image-cache entries as well as overlays.
              (org-link-preview-region t t beg end))))))))

(defun my/excali--org-after-save (&rest _)
  "Notify displayed previews after a native or ordinary scene save."
  (when-let* ((file (if (derived-mode-p 'excali-mode) excali--file buffer-file-name))
              ((equal (file-name-extension file) "excalidraw")))
    (my/excali--org-refresh (expand-file-name file))))

(defun my/excali--org-export (tree backend info)
  "Render excali links in export TREE for BACKEND using INFO.
Only the disposable export parse tree is changed.  Native image exporters
retain ownership of attributes, escaping and backend markup."
  (org-element-map tree 'link
    (lambda (link)
      (when (equal (org-element-property :type link) "excali")
        (unless (or (org-export-derived-backend-p backend 'html)
                    (org-export-derived-backend-p backend 'md))
          (user-error "excali links support HTML and Markdown export, not %s" backend))
        (let* ((buffer-file-name (plist-get info :input-file))
               (image (my/excali--org-image (org-element-property :path link) t))
               (description (and (org-element-contents link)
                                 (org-element-interpret-data (org-element-contents link)))))
          (org-element-put-property link :my-excali-image image)
          (org-element-put-property link :my-excali-description description)
          ;; Descriptions are alt text, not a request to link rather than embed.
          (org-element-set-contents link)
          (org-element-put-property link :contents-begin nil)
          (org-element-put-property link :contents-end nil)
          (org-element-put-property link :type "file")
          (org-element-put-property link :path image)
          (org-element-put-property link :raw-link (concat "file:" image))))))
  tree)

(defun my/excali--org-html-link (transcode link description info)
  "Embed a publication SVG in TRANSCODE's native HTML image for LINK.
Separate SVG image documents avoid collisions between Cairo glyph/clip IDs.
INFO and DESCRIPTION are passed through to the native translator."
  (let ((result (funcall transcode link description info)))
    (if-let* ((file (org-element-property :my-excali-image link)))
        (let* ((data (with-temp-buffer
                       (insert-file-contents-literally file)
                       (base64-encode-string (buffer-string) t)))
               (alt (org-html--make-attribute-string
                     (list :alt (or (org-element-property :my-excali-description link) "Diagram")))))
          (setq result (replace-regexp-in-string
                        "src=\"[^\"]*\"" (concat "src=\"data:image/svg+xml;base64," data "\"")
                        result t t))
          ;; Replace only the native filename default, preserving ATTR_HTML's
          ;; explicit accessibility text (including per-link attributes).
          (replace-regexp-in-string
           (concat "alt=\"" (regexp-quote (file-name-nondirectory file)) "\"") alt result t t))
      result)))

(defun my/excali--org-md-link (transcode link description info)
  "Deliver LINK's SVG beside the Markdown output and call native TRANSCODE.
Use the output basename for the asset directory, or the input basename for
buffer/string export.  DESCRIPTION and INFO are native translator arguments."
  (if-let* ((file (org-element-property :my-excali-image link)))
      (let* ((output (or (plist-get info :output-file) (plist-get info :input-file)
                         (user-error "Save the Org document before exporting diagrams")))
             (output (expand-file-name output))
             (assets (concat (file-name-sans-extension output) "-assets/"))
             (target (expand-file-name (file-name-nondirectory file) assets))
             (relative (file-relative-name target (file-name-directory output))))
        (require 'url-util)
        (make-directory assets t)
        (unless (file-exists-p target) (copy-file file target))
        (setq relative (mapconcat #'url-hexify-string (split-string relative "/") "/"))
        (org-element-put-property link :path relative)
        (org-element-put-property link :raw-link (concat "file:" relative))
        (let ((result (funcall transcode link description info))
              (alt (or (org-element-property :my-excali-description link) "Diagram")))
          ;; Org's Markdown image translator uses the literal alt text "img".
          (setq alt (replace-regexp-in-string "[][\\\\]" "\\\\\\&" alt))
          (replace-regexp-in-string "!\\[img\\]" (concat "![" alt "]") result t t)))
    (funcall transcode link description info)))

(defun my/excali--org-theme-enabled (&rest _)
  "Refresh displayed diagrams only when the active theme has a palette.
Unsupported themes leave existing previews intact.  Check before native Org
refresh removes overlays that cannot be regenerated without a palette."
  (let* ((theme (car custom-enabled-themes))
         (name (and theme (symbol-name theme))))
    (when (and name (file-readable-p
                     (expand-file-name (concat name ".json") my/excali-palette-directory)))
      (my/excali--org-refresh))))

;;;###autoload
;;;###autoload
(defun my/excali-org-register ()
  "Register deferred Org, exporter and drawing integrations."
  ;; This integration owns the combined Org/exporter/editor behavior.  Keep the
  ;; two-way gates here instead of duplicating the Org and Excali declarations or
  ;; forcing optional exporters/the graphical editor to load with this module.
  (with-eval-after-load 'org
    (org-link-set-parameters "excali"
                             :follow #'my/excali--org-follow
                             :complete #'my/excali--org-complete
                             :preview #'my/excali--org-preview)
    (add-hook 'org-mode-hook #'my/excali--org-display)
    (advice-add 'org-insert-link :after #'my/excali--org-inserted)
    (advice-add 'org-link-preview-region :around #'my/excali--org-preview-described)
    (add-hook 'clone-indirect-buffer-hook #'my/excali--org-cloned)
    (add-hook 'window-state-change-functions #'my/excali--org-resize)
    (add-hook 'enable-theme-functions #'my/excali--org-theme-enabled)
    (with-eval-after-load 'ox
      (require 'ox-md)
      (add-hook 'org-export-filter-parse-tree-functions #'my/excali--org-export))
    (with-eval-after-load 'ox-html
      (advice-add 'org-html-link :around #'my/excali--org-html-link))
    (with-eval-after-load 'ox-md
      (advice-add 'org-md-link :around #'my/excali--org-md-link))
    (add-hook 'after-save-hook #'my/excali--org-after-save)
    (with-eval-after-load 'excali
      (advice-add 'excali-save :around #'my/excali--org-workflow-save '((depth . -10)))
      (advice-add 'excali-save :after #'my/excali--org-after-save))))

(provide 'my-org-excali)
;;; my-org-excali.el ends here