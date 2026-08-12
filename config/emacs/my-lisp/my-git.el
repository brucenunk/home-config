;;; my-git.el --- Git primitives -*- lexical-binding: t -*-

;; Author: James Lee
;; URL: https://github.com/brucenunk/home-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; Low-level git helper functions.
;;
;; Sync operations (acceptable for fast local ops):
;;   - my/git-run, my/git-run-in-dir — core sync primitives
;;   - my/git-run-or-error, my/git-run-or-error-in-dir — sync with error signaling
;;   - my/git-run-with-stdin, my/git-run-with-stdin-in-dir — sync with stdin
;;   - my/git-lines, my/git-success-p — general purpose sync wrappers
;;   - my/git-branch, my/git-origin-default-ref — fast rev-parse/symbolic-ref
;;   - my/git-in-merge-or-rebase-p — file existence checks
;;
;; Async operations (required for network/expensive ops):
;;   - my/git-run-async — core async primitive for all network ops
;;   - my/git-pr-merged-p — check if branch has merged PR via GitHub CLI

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;;; Core sync primitives

;;;###autoload
(defun my/git-run (&rest args)
  "Run git ARGS synchronously, return (EXIT-CODE . OUTPUT).
Captures both stdout and stderr. Does not log.
Uses `default-directory' as the working directory."
  (with-temp-buffer
    ;; BUFFER arg '(t t) means: output to current buffer, mix stderr with stdout.
    ;; First t = stdout to current buffer, second t = stderr to same buffer.
    (let ((exit-code (apply #'call-process "git" nil '(t t) nil args)))
      (cons exit-code (buffer-string)))))

;;;###autoload
(defun my/git-run-in-dir (dir &rest args)
  "Run git ARGS in DIR synchronously, return (EXIT-CODE . OUTPUT).
Captures both stdout and stderr. Does not log.
Use this in async callbacks where `default-directory' may not be set."
  (let ((default-directory dir))
    (apply #'my/git-run args)))

;;;###autoload
(defun my/git-run-with-stdin (stdin &rest args)
  "Run git ARGS with STDIN as input, return (EXIT-CODE . OUTPUT).
STDIN is sent to the process's stdin. Uses `default-directory'."
  (with-temp-buffer
    ;; START arg is the string to send; END arg nil means use whole string.
    ;; BUFFER arg '(t t) means: output to current buffer, mix stderr with stdout.
    (let ((exit-code
           (apply #'call-process-region stdin nil "git" nil '(t t) nil args)))
      (cons exit-code (buffer-string)))))

;;;###autoload
(defun my/git-run-with-stdin-in-dir (dir stdin &rest args)
  "Run git ARGS in DIR with STDIN as input, return (EXIT-CODE . OUTPUT).
STDIN is sent to the process's stdin."
  (let ((default-directory dir))
    (apply #'my/git-run-with-stdin stdin args)))

;;; Derived sync helpers

;;;###autoload
(defun my/git-run-or-error (&rest args)
  "Run git ARGS synchronously in `default-directory' and return output.
Signal an error with trimmed output when git exits non-zero."
  (pcase-let ((`(,code . ,output) (apply #'my/git-run args)))
    (if (zerop code)
        output
      (error "git %s failed (exit %d): %s"
             (string-join args " ")
             code
             (string-trim output)))))

;;;###autoload
(defun my/git-run-or-error-in-dir (dir &rest args)
  "Run git ARGS in DIR synchronously and return output.
Signal an error with trimmed output on non-zero exit.
Use this in functions that accept an explicit DIR argument."
  (let ((default-directory dir))
    (apply #'my/git-run-or-error args)))

;;;###autoload
(defun my/git-success-p (&rest args)
  "Run git ARGS synchronously; return non-nil if exit code is 0.
Uses `default-directory' as the working directory."
  (zerop (car (apply #'my/git-run args))))

;;;###autoload
(defun my/git-lines (&rest args)
  "Run git ARGS synchronously in `default-directory'.
Return output as a list of lines. Signal error on non-zero exit."
  (pcase-let ((`(,code . ,output) (apply #'my/git-run args)))
    (if (zerop code)
        (split-string (string-trim-right output) "\n" t)
      (error "git %s failed (exit %d): %s"
             (string-join args " ") code (string-trim output)))))

;;;###autoload
(defun my/git-lines-in-dir (dir &rest args)
  "Run git ARGS in DIR synchronously.
Return output as a list of lines. Signal error on non-zero exit.
Use this in functions that accept an explicit DIR argument."
  (let ((default-directory dir))
    (apply #'my/git-lines args)))

;;;###autoload
(defun my/git-success-in-dir-p (dir &rest args)
  "Run git ARGS in DIR synchronously; return non-nil if exit code is 0.
Use this in functions that accept an explicit DIR argument."
  (let ((default-directory dir))
    (apply #'my/git-success-p args)))

;;;###autoload
(defun my/git-branch (dir)
  "Return current branch name for git repo at DIR, or nil.
Returns nil if HEAD is detached."
  (pcase-let ((`(,code . ,output) (my/git-run-in-dir dir "rev-parse" "--abbrev-ref" "HEAD")))
    (when (zerop code)
      (let ((branch (string-trim output)))
        (unless (string= branch "HEAD")
          branch)))))

;;;###autoload
(defun my/git-origin-default-ref (dir)
  "Return the origin default branch ref for git repo at DIR.
Returns a string like \"origin/main\" or \"origin/master\".
Signals error if refs/remotes/origin/HEAD is not set."
  (pcase-let ((`(,code . ,output) (my/git-run-in-dir dir "symbolic-ref" "refs/remotes/origin/HEAD")))
    (unless (zerop code)
      (error "Cannot determine origin default branch in %s: %s" dir (string-trim output)))
    (let ((ref (string-trim output)))
      (if (string-prefix-p "refs/remotes/" ref)
          (substring ref (length "refs/remotes/"))
        ref))))

;;;###autoload
(defun my/git-in-merge-or-rebase-p (dir)
  "Return non-nil if DIR is in a merge, rebase, or cherry-pick state."
  (pcase-let ((`(,code . ,output) (my/git-run-in-dir dir "rev-parse" "--git-dir")))
    (when (zerop code)
      (let ((git-dir (expand-file-name (string-trim output) dir)))
        (or (file-exists-p (expand-file-name "MERGE_HEAD" git-dir))
            (file-directory-p (expand-file-name "rebase-merge" git-dir))
            (file-directory-p (expand-file-name "rebase-apply" git-dir))
            (file-exists-p (expand-file-name "CHERRY_PICK_HEAD" git-dir))
            (file-exists-p (expand-file-name "REVERT_HEAD" git-dir)))))))

;;; Async git operations

;;; GitHub CLI

;;;###autoload
(defun my/git-pr-merged-p (owner repo branch callback)
  "Check if BRANCH has a merged PR in OWNER/REPO via GitHub CLI.
CALLBACK receives `merged', `not-merged', or `error'."
  (let* ((repo-slug (format "%s/%s" owner repo))
         (buf (generate-new-buffer " *gh-pr-check*")))
    (make-process
     :name "git-pr-merged-check"
     :buffer buf
     :command (list "gh" "pr" "list" "--repo" repo-slug
                    "--head" branch "--state" "merged"
                    "--json" "number" "--jq" "length")
     :noquery t
     :sentinel
     (lambda (proc _event)
       (when (eq (process-status proc) 'exit)
         (let ((exit-code (process-exit-status proc))
               (output (with-current-buffer buf (string-trim (buffer-string)))))
           (kill-buffer buf)
           (cond
            ((and (zerop exit-code)
                  (string-match-p "\\`[0-9]+\\'" output)
                  (> (string-to-number output) 0))
             (funcall callback 'merged))
            ((zerop exit-code)
             (funcall callback 'not-merged))
            (t
             (message "git-pr-merged-p: gh failed (exit %d) for %s/%s branch %s: %s"
                      exit-code owner repo branch output)
             (funcall callback 'error)))))))))

(cl-defun my/git-run-async (dir args &key name on-success on-error stdin)
  "Run git ARGS in DIR asynchronously.
NAME is for buffer/process naming (defaults to \"git-async\").
ON-SUCCESS is called with (OUTPUT EXIT-CODE) on exit 0.
ON-ERROR is called with (EXIT-CODE OUTPUT) on non-zero exit.
STDIN, if provided, is sent to the process's stdin and then EOF.

If ON-ERROR is nil, non-zero exits are silently ignored.

Example:
  (my/git-run-async \"/path/to/repo\"
    \\='(\"fetch\" \"origin\")
    :name \"fetch\"
    :on-success (lambda (output _) (message \"Fetched: %s\" output))
    :on-error (lambda (code output) (message \"Failed %d: %s\" code output)))"
  (let* ((proc-name (format "git-%s-%s"
                            (or name "async")
                            (file-name-nondirectory (directory-file-name dir))))
         (buf-name (format " *%s*" proc-name))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf (erase-buffer))
    (condition-case err
        (let ((proc (make-process
                     :name proc-name
                     :buffer buf
                     :command (append (list "git" "-C" dir) args)
                     :noquery t
                     :connection-type 'pipe
                     :coding 'utf-8-unix
                     :sentinel
                     (lambda (proc _event)
                       (when (eq (process-status proc) 'exit)
                         (let ((exit-code (process-exit-status proc))
                               (output (with-current-buffer (process-buffer proc)
                                         (buffer-string))))
                           (condition-case sentinel-err
                               (if (zerop exit-code)
                                   (when on-success
                                     (funcall on-success output exit-code))
                                 (when on-error
                                   (funcall on-error exit-code output)))
                             (error
                              (message "git-run-async sentinel error: %S" sentinel-err)))))))))
          (when stdin
            (process-send-string proc stdin)
            (process-send-eof proc))
          proc)
      (error
       (when on-error
         (funcall on-error -1 (error-message-string err)))))))

(provide 'my-git)
;;; my-git.el ends here
