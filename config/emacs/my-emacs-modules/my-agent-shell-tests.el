;;; my-agent-shell-tests.el --- Isolated GC policy tests -*- lexical-binding: t -*-

;;; Commentary:
;; No daemon, live agents, remote connections or user worktrees are used.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-shell-gc)
;; Load policy without starting global tracking outside a disposable fixture.
(cl-letf (((symbol-function 'agent-shell-gc-mode) #'ignore))
  (require 'my-agent-shell))

(defvar my/agent-shell-test--buffers nil)

(defmacro my/agent-shell-test--isolated (&rest body)
  "Run BODY with isolated GC state and a disposable filesystem root."
  (declare (indent 0))
  `(let* ((root (make-temp-file "agent-gc-policy-" t))
          (default-directory (file-name-as-directory root))
          (user-emacs-directory default-directory)
          (my/agent-shell-transcript-directory (expand-file-name "transcripts/" root))
          (agent-shell-gc-store-file (expand-file-name "gc/state.eld" root))
          (agent-shell-gc--sessions (make-hash-table :test 'equal))
          (agent-shell-gc--worktrees (make-hash-table :test 'equal))
          (agent-shell-gc--worktree-cache (make-hash-table :test 'equal))
          (agent-shell-gc--store-loaded nil)
          (agent-shell-gc--timer nil)
          (agent-shell-gc--save-timer nil)
          (agent-shell-gc--last-tick nil)
          (agent-shell-gc--grace-until 0)
          (agent-shell-gc-notify-function #'ignore)
          (agent-shell-gc-mode nil)
          (my/agent-shell-test--buffers nil))
     (unwind-protect
         (progn ,@body)
       (agent-shell-gc-mode -1)
       (dolist (buffer my/agent-shell-test--buffers)
         (when (buffer-live-p buffer)
           (let ((kill-buffer-query-functions nil)) (kill-buffer buffer))))
       (when (timerp agent-shell-gc--save-timer)
         (cancel-timer agent-shell-gc--save-timer))
       (delete-directory root t))))

(defun my/agent-shell-test--shell ()
  "Start a native Pi shell, replacing only ACP bootstrapping."
  (let ((agent-shell-pi-acp-command (list (executable-find "git")))
        (agent-shell-show-welcome-message nil)
        (agent-shell-show-busy-indicator nil)
        (agent-shell-session-strategy 'new))
    (cl-letf (((symbol-function 'agent-shell--handle) #'ignore))
      (let* ((shell (agent-shell-start :config (agent-shell-pi-make-agent-config)))
             (viewport (agent-shell-viewport--buffer :shell-buffer shell)))
        (push shell my/agent-shell-test--buffers)
        (when viewport (push viewport my/agent-shell-test--buffers))
        (with-current-buffer shell
          (setf (map-elt agent-shell--state :session)
                (list (cons :id (buffer-name shell))))
          (agent-shell--emit-event :event 'init-finished)
          (agent-shell--append-transcript :text "Fixture session\n"
                                          :file-path agent-shell--transcript-file))
        shell))))

(defun my/agent-shell-test--expire (shell)
  "Give SHELL activity older than the configured session TTL."
  (with-current-buffer shell
    (setq agent-shell-gc--activity
          (- (float-time) agent-shell-gc-idle-session-ttl 60))))

(defun my/agent-shell-test--git (dir &rest args)
  "Run Git ARGS in fixture DIR, failing on errors."
  (let ((default-directory (file-name-as-directory dir)))
    (with-temp-buffer
      (unless (zerop (apply #'process-file "git" nil t nil args))
        (error "Fixture git %S failed: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defun my/agent-shell-test--repo (root &optional bare)
  "Create a source and linked task worktree beneath ROOT.
When BARE is non-nil, use a bare source like the supported launcher layout."
  (let ((main (expand-file-name "main" root))
        (task (expand-file-name "task" root)))
    (make-directory main)
    (my/agent-shell-test--git main "init" "-q" "-b" "main")
    (my/agent-shell-test--git main "config" "user.name" "GC Test")
    (my/agent-shell-test--git main "config" "user.email" "gc@example.invalid")
    (my/agent-shell-test--git main "config" "commit.gpgsign" "false")
    (my/agent-shell-test--git main "commit" "-qm" "Initial" "--allow-empty")
    (when bare
      (let ((source (expand-file-name "master.git" root)))
        (my/agent-shell-test--git root "clone" "--bare" main source)
        (setq main source)))
    (my/agent-shell-test--git main "worktree" "add" "-qb" "task" task)
    (list main task)))

(ert-deftest my/agent-shell-gc-configured-mode-and-settings ()
  (my/agent-shell-test--isolated
    ;; Exercise the actual :config enablement, not a mocked mode call.
    (load "my-agent-shell" nil t)
    (should agent-shell-gc-mode)
    (should (timerp agent-shell-gc--timer))
    (should (agent-shell-gc--in-grace-p))
    (should (= agent-shell-gc-idle-session-ttl (* 4 86400)))
    (should-not agent-shell-gc-idle-worktree-ttl)
    (should (= agent-shell-gc-poll-interval 60))
    (should (= agent-shell-gc-grace 300))
    (should-not agent-shell-gc-delete-worktree-branch)
    (should-not agent-shell-gc-dry-run)
    (should (equal agent-shell-gc-session-protect-functions
                   '(my/agent-shell-gc-protect-in-flight-p
                     my/agent-shell-gc-protect-queued-input-p
                     agent-shell-gc-protect-pending-input-p
                     my/agent-shell-gc-protect-viewport-draft-p
                     agent-shell-gc-protect-kept-p)))
    (should (eq agent-shell-preferred-agent-config 'pi))
    (should agent-shell-prefer-viewport-interaction)
    (should agent-shell-tramp-mode)
    (should (eq agent-shell-transcript-file-path-function
                #'my/agent-shell--transcript-file-path))))

(ert-deftest my/agent-shell-gc-protects-busy-blocked-and-unknown-status ()
  (my/agent-shell-test--isolated
    (agent-shell-gc-mode 1)
    (let ((shell (my/agent-shell-test--shell)))
      (my/agent-shell-test--expire shell)
      ;; Use the pinned public status implementation, including its busy guard.
      (dolist (blocked '(nil permission elicitation))
        (cl-letf (((symbol-function 'shell-maker-busy) (lambda () t))
                  ((symbol-function 'agent-shell--permission-pending-p)
                   (lambda (&rest _) (eq blocked 'permission)))
                  ((symbol-function 'agent-shell-elicitation--pending-p)
                   (lambda (&rest _) (eq blocked 'elicitation))))
          (should (eq (agent-shell-status :shell-buffer shell)
                      (if blocked 'blocked 'busy)))
          (agent-shell-gc--sweep-sessions)
          (should (buffer-live-p shell))))
      (cl-letf (((symbol-function 'agent-shell-status)
                 (lambda (&rest _) (error "Unknown status"))))
        (agent-shell-gc--sweep-sessions)
        (should (buffer-live-p shell))))))

(ert-deftest my/agent-shell-gc-ready-session-with-queued-input-is-protected ()
  (my/agent-shell-test--isolated
    (agent-shell-gc-mode 1)
    (let ((shell (my/agent-shell-test--shell)))
      (my/agent-shell-test--expire shell)
      (with-current-buffer shell
        (setf (map-elt agent-shell--state :pending-prompts) '("Unsent queued prompt")))
      (should (eq (agent-shell-status :shell-buffer shell) 'ready))
      (should (eq (agent-shell-gc--protected-by shell)
                  #'my/agent-shell-gc-protect-queued-input-p))
      (agent-shell-gc--sweep-sessions)
      (should (buffer-live-p shell))
      (with-current-buffer shell
        (setf (map-elt agent-shell--state :pending-prompts) nil))
      (agent-shell-gc--sweep-sessions)
      (should-not (buffer-live-p shell)))))

(ert-deftest my/agent-shell-gc-drafts-pin-and-viewport-activity ()
  (my/agent-shell-test--isolated
    (agent-shell-gc-mode 1)
    (let* ((shell (my/agent-shell-test--shell))
           (viewport (agent-shell-viewport--buffer :shell-buffer shell :existing-only t)))
      (should (buffer-live-p viewport))
      (my/agent-shell-test--expire shell)
      (with-current-buffer viewport (insert "Unsent draft"))
      (should (my/agent-shell-gc-protect-viewport-draft-p shell))
      (agent-shell-gc--sweep-sessions)
      (should (buffer-live-p shell))
      ;; A draft stashed while viewing output is still work worth keeping.
      (with-current-buffer viewport
        (setq agent-shell-viewport--compose-snapshot '((:content . "Saved draft")))
        (agent-shell-viewport-view-mode))
      (should (my/agent-shell-gc-protect-viewport-draft-p shell))
      (with-current-buffer viewport
        (setq agent-shell-viewport--compose-snapshot nil)
        (agent-shell-viewport-edit-mode)
        (insert "  \n"))
      (should-not (my/agent-shell-gc-protect-viewport-draft-p shell))
      (with-current-buffer shell
        (goto-char (point-max))
        (insert "Shell draft"))
      (should (agent-shell-gc-protect-pending-input-p shell))
      (agent-shell-gc--sweep-sessions)
      (should (buffer-live-p shell))
      (with-current-buffer shell
        (delete-region (marker-position (cdr comint-last-prompt)) (point-max)))
      (with-current-buffer viewport (agent-shell-gc-toggle-keep))
      (agent-shell-gc--sweep-sessions)
      (should (buffer-live-p shell))
      (with-current-buffer viewport
        (agent-shell-gc-toggle-keep)
        (run-hooks 'post-command-hook))
      (should (< (agent-shell-gc--idle shell) 5))
      (agent-shell-gc--sweep-sessions)
      (should (buffer-live-p shell)))))

(ert-deftest my/agent-shell-gc-closes-visible-session-process-and-viewport-only ()
  (my/agent-shell-test--isolated
    (agent-shell-gc-mode 1)
    (let* ((shell (my/agent-shell-test--shell))
           (viewport (agent-shell-viewport--buffer :shell-buffer shell :existing-only t))
           (client (acp-make-client :command "cat" :context-buffer shell))
           (process (make-process :name "gc-fixture-client" :command '("cat") :noquery t))
           (transcript (with-current-buffer shell agent-shell--transcript-file))
           (saved-session (expand-file-name "saved-session.json" root)))
      (setf (map-elt client :process) process)
      (with-current-buffer shell
        (setf (map-elt agent-shell--state :client) client)
        (should-not agent-shell--pending-directory-cleanup)
        (agent-shell--append-transcript :text "Keep transcript\n" :file-path transcript))
      (write-region "Persisted agent session" nil saved-session)
      (save-window-excursion
        ;; Visible shell and viewport are both eligible after the TTL.
        (dolist (buffer (list shell viewport))
          (set-window-buffer (selected-window) buffer)
          (should (get-buffer-window buffer))
          (should-not (agent-shell-gc--protected-by shell)))
        (my/agent-shell-test--expire shell)
        (should (process-live-p process))
        (agent-shell-gc-now))
      (should-not (buffer-live-p shell))
      (should-not (buffer-live-p viewport))
      (should-not (process-live-p process))
      (should (file-exists-p transcript))
      (should (equal (with-temp-buffer (insert-file-contents saved-session) (buffer-string))
                     "Persisted agent session"))
      (should (file-directory-p root)))))

(ert-deftest my/agent-shell-gc-native-temporary-directory-cleanup ()
  (my/agent-shell-test--isolated
    (agent-shell-gc-mode 1)
    (let ((shell (my/agent-shell-test--shell))
          (temporary-session (expand-file-name "temporary-session" root)))
      (make-directory temporary-session)
      ;; Only agent-shell's explicit temporary-session marker causes this.
      (with-current-buffer shell
        (setq agent-shell--pending-directory-cleanup temporary-session))
      (my/agent-shell-test--expire shell)
      (agent-shell-gc--sweep-sessions)
      (should-not (file-exists-p temporary-session))
      (should (file-directory-p root)))))

(ert-deftest my/agent-shell-gc-session-cleanup-preserves-worktree-and-branch ()
  (dolist (bare '(nil t))
    (my/agent-shell-test--isolated
      (pcase-let* ((`(,source ,task) (my/agent-shell-test--repo root bare))
                   (default-directory (file-name-as-directory task)))
        (agent-shell-gc-mode 1)
        (let* ((shell (my/agent-shell-test--shell))
               (transcript (buffer-local-value 'agent-shell--transcript-file shell)))
          ;; Seed an ancient entry too: even tracked worktrees cannot be removed.
          (puthash (agent-shell-gc--normalize-dir task)
                   (list (cons :last-activity 0) (cons :repo source)
                         (cons :branch "task") (cons :origin 'session))
                   agent-shell-gc--worktrees)
          (my/agent-shell-test--expire shell)
          (cl-letf (((symbol-function 'agent-shell-gc--collect-worktree)
                     (lambda (&rest _) (ert-fail "Worktree collection is disabled"))))
            (agent-shell-gc-now))
          (should-not (buffer-live-p shell))
          (should (file-exists-p (expand-file-name ".git" task)))
          (should (file-directory-p source))
          (should (equal (my/agent-shell-test--git source "branch" "--format=%(refname:short)"
                                                 "--list" "task") "task"))
          (should (file-exists-p transcript)))))))

(ert-deftest my/agent-shell-gc-session-cleanup-with-rpc-cwd ()
  (my/agent-shell-test--isolated
    (agent-shell-gc-mode 1)
    (let* ((shell (my/agent-shell-test--shell))
           (transcript (buffer-local-value 'agent-shell--transcript-file shell))
           (remote "/rpc:gc-fixture.invalid:/srv/task/")
           (lookups 0))
      (with-current-buffer shell (setq default-directory remote))
      (my/agent-shell-test--expire shell)
      ;; Worktree resolution is unsupported and deletion disabled.  Simulate
      ;; its nil result at that boundary, without touching a remote filesystem.
      (cl-letf (((symbol-function 'agent-shell-gc--worktree-info)
                 (lambda (dir)
                   (should (equal dir remote))
                   (cl-incf lookups)
                   nil)))
        (agent-shell-gc-now))
      (should (> lookups 0))
      (should-not (buffer-live-p shell))
      (should (file-exists-p transcript)))))

(ert-deftest my/agent-shell-gc-rpc-stat-connection-error-preserves-tracking ()
  (require 'tramp-rpc)
  (my/agent-shell-test--isolated
    (let ((remote "/rpc:gc-fixture.invalid:/srv/task")
          (remote-file-name-inhibit-cache t)
          (calls 0))
      (puthash remote '((:last-activity . 1)) agent-shell-gc--worktrees)
      ;; Exercise pinned RPC's real file-directory-p/stat error conversion.
      ;; Replace only the transport, never connect to a host.
      (cl-letf (((symbol-function 'tramp-rpc--call)
                 (lambda (&rest _)
                   (cl-incf calls)
                   (signal 'file-error '("GC fixture connection unavailable")))))
        (should-error (agent-shell-gc--prune) :type 'file-error))
      (should (> calls 0))
      (should (gethash remote agent-shell-gc--worktrees)))))

(ert-deftest my/agent-shell-gc-unavailable-directory-tracking-is-best-effort ()
  (my/agent-shell-test--isolated
    (let ((remote "/rpc:offline.invalid:/srv/task"))
      (puthash remote '((:last-activity . 1)) agent-shell-gc--worktrees)
      ;; A signalled connection failure aborts pruning without dropping state.
      (cl-letf (((symbol-function 'file-directory-p)
                 (lambda (_) (signal 'file-error '("Connection unavailable")))))
        (should-error (agent-shell-gc--prune) :type 'file-error))
      (should (gethash remote agent-shell-gc--worktrees))
      ;; Accepted upstream limitation: a nil probe is interpreted as absence.
      ;; This test does not assert that real RPC connection errors return nil.
      (cl-letf (((symbol-function 'file-directory-p) (lambda (_) nil)))
        (agent-shell-gc--prune))
      (should-not (gethash remote agent-shell-gc--worktrees)))))

(provide 'my-agent-shell-tests)
;;; my-agent-shell-tests.el ends here