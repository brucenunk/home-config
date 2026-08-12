;;; my-emacs-dictation-tests.el --- Tests for dictation helpers -*- lexical-binding: t -*-

;;; Commentary:

;; Regression coverage for transcription response handling.

;;; Code:

(require 'ert)
(require 'my-emacs-dictation)

(ert-deftest my/dictation-transcript-from-response-returns-text ()
  (should (equal (my/dictation--transcript-from-response 200 "{\"text\":\" hello \\n\"}")
                 "hello")))

(ert-deftest my/dictation-transcript-from-response-reports-invalid-json ()
  (let ((error-data (should-error (my/dictation--transcript-from-response 200 "2, 1, 2")
                                  :type 'user-error)))
    (should (string-match-p "invalid JSON with HTTP 200" (cadr error-data)))
    (should (string-match-p "2, 1, 2" (cadr error-data)))))

(ert-deftest my/dictation-transcript-from-response-reports-http-json-error ()
  (let ((error-data (should-error (my/dictation--transcript-from-response 502 "{\"error\":{\"message\":\"bad gateway\"}}")
                                  :type 'user-error)))
    (should (string-match-p "Transcription failed with HTTP 502: bad gateway"
                            (cadr error-data)))))

(ert-deftest my/dictation-response-excerpt-compacts-empty-body ()
  (should (equal (my/dictation--response-excerpt " \n\t ")
                 "empty response body")))

(provide 'my-emacs-dictation-tests)
;;; my-emacs-dictation-tests.el ends here
