;;; url-scgi.el --- SCGI support for url.el  -*- lexical-binding: t -*-

;; Copyright (C) 2011-2022 Free Software Foundation, Inc.

;; Author: Stefan Kangas <stefankangas@gmail.com>
;; Version: 0.8
;; Keywords: comm, data, processes, scgi
;; Package-Requires: ((emacs "24.3"))
;; URL: https://github.com/skangas/url-scgi/
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Support for SCGI URLs in Emacs, with url.el.
;;
;; The SCGI specification document can be found at:
;;
;;     https://python.ca/scgi/protocol.txt
;;
;; Usage, with xml-rpc.el:
;;
;;     (require 'url-scgi)
;;     (xml-rpc-method-call "scgi://localhost:5000" "some.method")
;;
;; This is heavily based on the url-http.el library.

;; Bug reports, comments, and suggestions are welcome!  Send them to
;; Stefan Kangas <stefankangas@gmail.com> or report them on GitHub.

;;; Change Log:

;; 0.8 - Fix bug in `url-scgi-add-null-bytes'

;; 0.7 - Release on GNU ELPA

;; 0.6 - Documentation fixes

;; 0.5 - Fix using file socket on Emacs 25
;;       Fix cl-check-type bug on Emacs 26.1

;; 0.4 - Significant code cleanups

;; 0.3 - Support scgi over local socket

;; 0.2 - Support Emacs 24

;; 0.1 - First public version

;;; Code:

(require 'cl-lib)
(require 'url-parse)

(defvar url-scgi-connection-opened)

(defconst url-scgi-asynchronous-p t "SCGI retrievals are asynchronous.")

;; Silence byte-compiler
(defvar url-callback-function)
(defvar url-callback-arguments)
(defvar url-current-object)
(defvar url-request-data)

(defun url-scgi-string-to-netstring (str)
  "Convert string STR into a SCGI protocol netstring."
  (format "%d:%s," (length str) str))

(defun url-scgi-add-null-bytes (&rest args)
  (mapconcat (lambda (a) (concat a "\000")) args ""))

(defun url-scgi-make-request-header (data)
  (url-scgi-string-to-netstring
   (url-scgi-add-null-bytes
    "CONTENT_LENGTH" (number-to-string (length data))
    "SCGI" "1")))

(defun url-scgi-create-request ()
  (concat (url-scgi-make-request-header url-request-data)
          url-request-data))

(defun url-scgi-activate-callback ()
  "Activate callback specified when this buffer was created."
  (apply url-callback-function url-callback-arguments))

(defun url-scgi-handle-home-dir (filename)
  (expand-file-name
   (if (string-match "^/~" filename)
       (substring filename 1)
     filename)))

;;;###autoload
(defun url-scgi (url callback cbargs)
  "Handle SCGI URLs from internal Emacs functions.

URL must be a parsed URL.  See `url-generic-parse-url' for details.

When retrieval is completed, execute the function CALLBACK, passing it
an updated value of CBARGS as arguments."
  (if (>= emacs-major-version 26)
      (cl-check-type url url "Need a pre-parsed URL.")
    (cl-check-type url vector "Need a pre-parsed URL."))
  ;; (declare (special url-scgi-connection-opened
  ;;                   url-callback-function
  ;;                   url-callback-arguments
  ;;                   url-current-object))

  (let* ((host (url-host url))
         (port (url-port url))
         (filename (url-filename url))
         (is-local-socket (string-match "^/." filename))
         (bufname (format " *scgi %s*" (if is-local-socket
                                           filename
                                         (format "%s:%d" host port))))
         (buffer (generate-new-buffer bufname))
         (connection (cond
                      (is-local-socket
                       (let ((filename (url-scgi-handle-home-dir filename)))
                         (make-network-process :name "scgi"
                                               :buffer buffer
                                               :remote filename)))
                      (t ; scgi over tcp
                       (url-open-stream host buffer host port)))))
    (if (not connection)
        ;; Failed to open the connection for some reason
        (progn
          (kill-buffer buffer)
          (setq buffer nil)
          (error "Could not create connection to %s:%d" host port))
      (with-current-buffer buffer
        (setq url-current-object url
              mode-line-format "%b [%s]")

        (dolist (var '(url-scgi-connection-opened
                       url-callback-function
                       url-callback-arguments))
          (set (make-local-variable var) nil))

        (setq url-callback-function callback
              url-callback-arguments cbargs
              url-scgi-connection-opened nil)

        (pcase (process-status connection)
          (`connect
           ;; Asynchronous connection
           (set-process-sentinel connection 'url-scgi-async-sentinel))
          (`failed
           ;; Asynchronous connection failed
           (error "Could not create connection to %s:%d" host port))
          (_
           (set-process-sentinel connection 'url-scgi-sync-open-sentinel)
           (process-send-string connection (url-scgi-create-request))))))
    buffer))

(defun url-scgi-sync-open-sentinel (proc _)
  (when (buffer-name (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (url-scgi-activate-callback))))

(defun url-scgi-async-sentinel (proc why)
  ;; We are performing an asynchronous connection, and a status change
  ;; has occurred.
  (with-current-buffer (process-buffer proc)
    (cond
     (url-scgi-connection-opened
      (url-scgi-activate-callback))
     ((string= (substring why 0 4) "open")
      (setq url-scgi-connection-opened t)
      (process-send-string proc (url-scgi-create-request)))
     (t
      (setf (car url-callback-arguments)
            (nconc (list :error (list 'error 'connection-failed why
                                      :host (url-host url-current-object)
                                      :service (url-port url-current-object)))
                   (car url-callback-arguments)))
      (url-scgi-activate-callback)))))

(provide 'url-scgi)

;;; url-scgi.el ends here
