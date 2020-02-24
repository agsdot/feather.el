;;; feather.el --- Parallel thread modern package manager        -*- lexical-binding: t; -*-

;; Copyright (C) 2018-2019  Naoya Yamashita

;; Author: Naoya Yamashita <conao3@gmail.com>
;; Maintainer: Naoya Yamashita <conao3@gmail.com>
;; Keywords: convenience package
;; Version: 0.1.0
;; URL: https://github.com/conao3/feather.el
;; Package-Requires: ((emacs "26.3") (async-await "1.0") (ppp "1.0") (page-break-lines "0.1"))

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Parallel thread modern Emacs package manager.


;;; Code:

(require 'feather-dashboard)
(require 'package)
(require 'async-await)
(require 'ppp)

(defgroup feather nil
  "Parallel thread modern Emacs package manager."
  :group 'applications)


;;; customize

(defcustom feather-max-process (or
                                (ignore-errors
                                  (string-to-number
                                   (shell-command-to-string
                                    "grep processor /proc/cpuinfo | wc -l")))
                                4)
  "Count of pallarel process number."
  :group 'feather
  :type 'number
  :set (lambda (sym val)
         (set-default sym val)
         (with-feather-dashboard-buffer
           (feather--dashboard-initialize))))

;; internal variables

(defvar feather-running nil
  "If non-nil, running feather main process.")

(defvar feather-package-install-args nil
  "List of `package-install' args.
see `feather--advice-package-install' and `feather--main-process'.")

(defvar feather-install-queue (make-hash-table :test 'eq)
  "All install queues, including dependencies.

Key is package name as symbol.
Value is alist.
  - STATUS is install status one of (queue install done).

  Additional info for parent package.
    - INDEX is index as integer.
    - PROCESS is process index as integer.
    - DEPENDS is list of ALL dependency like as (PKG VERSION).
    - QUEUE is list of ONLY dependency to be installed as list of symbol.
    - INSTALLED is list of package which have already installed.")

;; getters/setters

(defun feather--change-running-state (bool)
  "Change state `feather-running' to BOOL."
  (setq feather-running bool))

(defun feather--get-feather-running ()
  "Get state `feather-running' as boolean."
  feather-running)

(defun feather--push-package-install-args (val)
  "Push VAL to `feather-package-install-args'."
  (push val feather-package-install-args))

(defun feather--pop-package-install-args ()
  "Pop `feather-package-install-args'."
  (pop feather-package-install-args))

(defun feather--get-package-install-args ()
  "Get `feather-package-install-args'."
  feather-package-install-args)

(defun feather--add-install-queue (key val)
  "Add VAL for KEY to `feather-install-queue'."
  (setf (gethash key feather-install-queue) val))

(defun feather--get-install-queue (key)
  "Get value for KEY from `feather-install-queue'."
  (gethash key feather-install-queue))


;;; functions

(defun feather--resolve-dependencies-1 (pkgs)
  "Resolve dependencies for PKGS using package.el cache.
PKGS accepts package name symbol or list of these.
Return a list of dependencies, allowing duplicates."
  (when pkgs
    (mapcan
     (lambda (pkg)
       (let* ((pkg* (if (symbolp pkg) (list pkg '(0 1)) pkg))
              (elm  (assq (car pkg*) package-archive-contents))
              (req  (and elm (package-desc-reqs (cadr elm)))))
         (append req (funcall #'feather--resolve-dependencies-1 req))))
     (if (symbolp pkgs) (list pkgs) pkgs))))

(defun feather--resolve-dependencies (pkg)
  "Resolve dependencies for PKG.
PKGS accepts package name symbol.
Return a list of dependencies, duplicates are resolved by more
restrictive."
  (let (ret)
    (dolist (req (funcall #'feather--resolve-dependencies-1 pkg))
      (let ((sym (car  req))
            (ver (cadr req)))
        (if (assq sym ret)
            (when (version-list-< (car (alist-get sym ret)) ver)
              (setf (alist-get sym ret) (list ver)))
          (push req ret))))
    (append
     `((,pkg ,(package-desc-version
               (cadr (assq 'helm package-archive-contents)))))
     (nreverse ret))))


;;; promise

(defun feather--promise-fetch-package (pkg-desc)
  "Return promise to fetch PKG-DESC.

Install the package in the asynchronous Emacs.

Includes below operations
  - Fetch.  Fetch package tar file.
  - Install.  Untar tar and place .el files.
  - Generate.  Generate autoload file from ;;;###autoload comment.
  - Byte compile.  Generate .elc from .el file.
  - (Activate).  Add package path to `load-path', eval autoload.
  - (Load).  Actually load the package.

The asynchronous Emacs is killed immediately after the package
is installed, so the package-user-dir is populated with packages
ready for immediate loading.

see `package-download-transaction' and `package-install-from-archive'."
  (ppp-debug 'feather
    (ppp-plist-to-string
     (list :status 'start-fetch
           :package (package-desc-name pkg-desc))))
  (promise-then
   (promise:async-start
    `(lambda ()
       (let ((package-user-dir ,package-user-dir)
             (package-archives ',package-archives))
         (require 'package)
         (package-initialize)
         (package-install-from-archive ,pkg-desc))))
   (lambda (res)
     (ppp-debug 'feather
       (ppp-plist-to-string
        (list :status 'done-fetch
              :package (package-desc-name pkg-desc))))
     (promise-resolve res))
   (lambda (reason)
     (promise-reject `(fail-install-package ,reason)))))

(defun feather--promise-activate-package (pkg-desc)
  "Return promise to activate PKG-DESC.

Load the package which it can be loaded immediately is placed in
`package-user-dir' by `feather--promise-fetch-package'

see `package-install-from-archive' and `package-unpack'."
  (ppp-debug 'feather
    (ppp-plist-to-string
     (list :status 'start-activate
           :package (package-desc-name pkg-desc))))
  (promise-new
   (lambda (resolve reject)
     (let* ((_name (package-desc-name pkg-desc))
            (dirname (package-desc-full-name pkg-desc))
            (pkg-dir (expand-file-name dirname package-user-dir)))
       (condition-case err
           ;; Update package-alist.
           (let ((new-desc (package-load-descriptor pkg-dir)))
             (unless (equal (package-desc-full-name new-desc)
                            (package-desc-full-name pkg-desc))
               (error "The retrieved package (`%s') doesn't match what the archive offered (`%s')"
                      (package-desc-full-name new-desc) (package-desc-full-name pkg-desc)))
             ;; Activation has to be done before compilation, so that if we're
             ;; upgrading and macros have changed we load the new definitions
             ;; before compiling.
             (when (package-activate-1 new-desc :reload :deps)
               ;; FIXME: Compilation should be done as a separate, optional, step.
               ;; E.g. for multi-package installs, we should first install all packages
               ;; and then compile them.
               ;; (package--compile new-desc)

               ;; After compilation, load again any files loaded by
               ;; `activate-1', so that we use the byte-compiled definitions.
               (package--load-files-for-activation new-desc :reload))

             (ppp-debug 'feather
               (ppp-plist-to-string
                (list :status 'done-activate
                      :package (package-desc-name pkg-desc))))
             (funcall resolve pkg-dir))
         (error
          (funcall reject `(fail-activate-package ,err))))))))

(async-defun feather--install-packages (info pkg-descs)
  "Install PKGS async with additional INFO.
PKGS is `package-desc' list as (a b c).

This list must be processed orderd; b depends (a), and c depends (a b).

see `package-install' and `package-download-transaction'."
  (let-alist info
    (dolist (pkgdesc pkg-descs)
      (let ((pkg-name (package-desc-name pkgdesc)))
        (when-let (alist (gethash pkg-name feather-install-queue))
          (when (not (eq 'done (alist-get 'status alist)))
            (feather--dashboard-change-item-state .target-pkg 'wait
                                                  `((dep-pkg . ,pkg-name)))
            (feather--dashboard-change-process-state .process 'wait info)
            (while (not (eq 'done (alist-get 'status alist)))
             (ppp-debug 'feather
               "Wait for dependencies to be installed\n%s"
               (ppp-plist-to-string
                (list :package pkg-name
                      :dependency-from .target-pkg)))
             (await (promise:delay 0.5)))))))

    ;; set the status of the package to be installed to queue
    (dolist (pkgdesc pkg-descs)
      (let ((pkg-name (package-desc-name pkgdesc)))
        (if (gethash pkg-name feather-install-queue)
            (setf (alist-get 'status (gethash pkg-name feather-install-queue)) 'queue)
          (puthash pkg-name '((status . queue)) feather-install-queue))
        (feather--dashboard-change-item-state pkg-name 'queue)))

    ;; `package-download-transaction'
    (dolist (pkgdesc pkg-descs)
      (let ((pkg-name (package-desc-name pkgdesc)))
        (setf (alist-get 'status (gethash pkg-name feather-install-queue)) 'install)
        (feather--dashboard-change-item-state pkg-name 'install)
        (feather--dashboard-change-process-state .process 'install info)
        (condition-case err
            (progn
              (await (feather--promise-fetch-package pkgdesc))
              (await (feather--promise-activate-package pkgdesc)))
          (error
           (pcase err
             (`(error (fail-install-package ,reason))
              (ppp-debug :level :warning 'feather
                "Cannot install package\n%s"
                (ppp-plist-to-string
                 (list :package pkg-name
                       :reason reason))))
             (_
              (ppp-debug :level :warning 'feather
                "Something wrong while installing package\n%s"
                (ppp-plist-to-string
                 (list :package pkg-name
                       :reason err)))))))
        (setf (alist-get 'status (gethash pkg-name feather-install-queue)) 'done)
        (feather--dashboard-change-item-state pkg-name 'done)))
    (feather--dashboard-change-process-state .process 'done)))

(async-defun feather--main-process ()
  "Main process for feather."

  ;; preprocess
  (feather--change-running-state t)
  (await (promise:delay 1))             ; wait for continuous execution

  ;; `feather-package-install-args' may increase during execution of this loop
  (while (feather--get-package-install-args)
    (await
     (promise-concurrent-no-reject-immidiately
         feather-max-process (length (feather--get-package-install-args))
       (lambda (index)
         (seq-let (pkg dont-select) (feather--pop-package-install-args)

           ;; `package-install'

           ;; moved last of this function
           ;; (add-hook 'post-command-hook #'package-menu--post-refresh)
           (let ((pkg-name (if (package-desc-p pkg)
                           (package-desc-name pkg)
                         pkg)))
             (unless (or dont-select (package--user-selected-p pkg-name))
               (package--save-selected-packages
                (cons pkg-name package-selected-packages)))
             (if-let* ((transaction
                        (if (package-desc-p pkg)
                            (unless (package-installed-p pkg)
                              (package-compute-transaction (list pkg)
                                                           (package-desc-reqs pkg)))
                          (package-compute-transaction nil (list (list pkg))))))
                 (let* ((alist (gethash pkg-name feather-install-queue))
                        (status (alist-get 'status alist))
                        (processinx (1+ (mod index feather-max-process)))
                        (info `((index      . ,(1+ index))
                                (process    . ,(intern (format "process%s" processinx)))
                                (status     . install)
                                (target-pkg . ,pkg-name)
                                (depends    . ,(feather--resolve-dependencies pkg-name))
                                (queue      . ,(mapcar #'package-desc-name transaction))
                                (installed  . nil))))
                   (ppp-debug :break t 'feather
                     (ppp-plist-to-string
                      (mapcan
                       (lambda (elm)
                         (list (intern (format ":%s" (car elm))) (cdr elm)))
                       info)))
                   (cond
                    ((not alist)
                     (puthash pkg-name info feather-install-queue))
                    ((and alist (eq 'done status))
                     (setf (gethash pkg-name feather-install-queue) info))
                    ((and alist (not (eq 'done status)))
                     ;; TODO
                     ))
                   (feather--install-packages info transaction))
               (message "`%s' is already installed" pkg-name))))))))

  ;; postprocess
  (package-menu--post-refresh)
  (feather--change-running-state nil))


;;; advice

(defvar feather-advice-alist
  '((package-install . feather--advice-package-install))
  "Alist for feather advice.
See `feather--setup' and `feather--teardown'.")

(defun feather--advice-package-install (_fn &rest args)
  "Around advice for FN with ARGS.
This code based package.el bundled Emacs-26.3.
See `package-install'."
  (seq-let (pkg _dont-select) args
    (let ((pkg-name (if (package-desc-p pkg)
                    (package-desc-name pkg)
                  pkg)))
      (feather--push-package-install-args args)
      (feather--dashboard-add-new-item pkg-name)
      (feather--dashboard-change-item-state pkg-name 'queue)
      (unless (feather--get-feather-running)
        (feather--main-process)))))


;;; main

(defun feather--setup ()
  "Setup feather."
  (pcase-dolist (`(,sym . ,fn) feather-advice-alist)
    (advice-add sym :around fn)))

(defun feather--teardown ()
  "Teardown feather."
  (pcase-dolist (`(,sym . ,fn) feather-advice-alist)
    (advice-remove sym fn)))

;;;###autoload
(define-minor-mode feather-mode
  "Toggle feather."
  :global t
  (if feather-mode
      (feather--setup)
    (feather--teardown)))

(provide 'feather)

;; Local Variables:
;; indent-tabs-mode: nil
;; End:

;;; feather.el ends here
