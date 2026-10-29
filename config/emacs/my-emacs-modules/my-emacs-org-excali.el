;;; my-emacs-org-excali.el --- Local Org Excalidraw integration -*- lexical-binding: t; -*-

;;; Commentary:

;; Links, disposable preview caching, text-area layout and publication export.
;; Drawing/editor policy and native saved-scene rendering remain in
;; `my-emacs-excali'.  This is a local module, not a standalone package API.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'my-emacs-excali)

;;; Org links: saved scenes are the only input to disposable rendering.

(defcustom my/excali-preview-directory
  (expand-file-name "excali/" (or (getenv "XDG_CACHE_HOME") "~/.cache/"))
  "Disposable SVG cache for Org previews and publication assets."
  :type 'directory :group 'my-excali)

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
           ((null attribute) area)
           ((string-match "\\`\\([0-9]+\\(?:\\.[0-9]+\\)?\\)%\\'" attribute)
            (max 1 (round (* area (/ (string-to-number (match-string 1 attribute)) 100.0)))))
           ((string-match-p "\\`[0-9]+\\(?:px\\)?\\'" attribute)
            (max 1 (string-to-number attribute)))
           ;; Like native Org image sizing, ignore unsupported attributes.
           (t area)))
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
  "Refresh displayed diagram previews after enabling a theme."
  (my/excali--org-refresh))

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
    (advice-add 'excali-save :after #'my/excali--org-after-save)))

(provide 'my-emacs-org-excali)
;;; my-emacs-org-excali.el ends here