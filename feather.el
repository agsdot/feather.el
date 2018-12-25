;;; feather.el ---                                   -*- lexical-binding: t; -*-

;; Copyright (C) 2018  Naoya Yamashita

;; Author: Naoya Yamashita
;; Keywords: .emacs

;; This program is free software; you can redistribute it and/or modify
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

;;

(require 'feather-polyfill)
(require 'feather-variables)

(defgroup feather nil
  "Emacs package manager with parallel processing."
  :group 'lisp)

(defconst feather-version "0.0.1"
  "feather.el version")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;  Support functions
;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;  Shell controllers
;;

(defun feather-command-queue (pkg cmdlst)
  "Execute cmdlst(string-list) queue with `start-process'.

CMDLST is like ((\"pwd\") (\"echo\" \"$(whoami)\")).
CMDLST will be escaped (\"pwd\" \"echo \\\\$\\\\(whoami\\\\)\").

The arguments passed in are properly escaped, so address vulnerabilities
like OS command injection.
The case, user can't get user-name (just get \\$(shoami)).

If CMDLST is (A B C), if A fails, B and subsequent commands will not execute."
  (let* ((safe-cmdlst (mapcar
                       (lambda (x)
                         (mapconcat #'shell-quote-argument x " "))
                       cmdlst))
         (command     (mapconcat #'identity safe-cmdlst " && "))
         (buffer-name (format "*feather-async-%s-%s*" pkg (gensym)))
         (buffer      (get-buffer-create buffer-name))
         (directory   default-directory)
         (proc        (get-buffer-process buffer)))

    (when (get-buffer-process buffer)
      (setq buffer (generate-new-buffer buffer-name)))
    
    (with-current-buffer buffer
      (shell-command-save-pos-or-erase)
      (setq default-directory directory)
      (setq proc (start-process buffer-name
                                buffer
                                shell-file-name      ; /bin/bash (default)
				shell-command-switch ; -c (default)
                                command))
      (setq mode-line-process '(":%s"))
      (require 'shell) (shell-mode)
      (set-process-sentinel proc 'shell-command-sentinel)
      ;; Use the comint filter for proper handling of
      ;; carriage motion (see comint-inhibit-carriage-motion).
      (set-process-filter proc 'comint-output-filter)
      (display-buffer buffer '(nil (allow-no-window . t))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;  advice
;;

(defun feather-show-download-progress (_fmt _perc &rest _args)
  "show download progress.
`:before' advice for `url-display-percentage'"
  (setq-local url-show-status t))

(defun feather-advice-add (&rest args)
  "advice-add after check `advice-add' defined.

\(fn SYMBOL WHERE FUNCTION &optional PROPS)"
  (when (fboundp 'advice-add)
    (apply #'advice-add args)))

(defun feather-advice-remove (&rest args)
  "advice-remove after check `advice-remove' defined.

\(fn SYMBOL FUNCTION)"
  (when (fboundp 'advice-remove)
    (apply #'advice-remove args)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;  Git controllers
;;

;; (feather-git-clone-head "melpa" "https://github.com/melpa/melpa" feather-recipes-dir)
(defun feather-git-clone-head (pkg remote-url destdir)
  "Clone REMOTE-URL repository HEAD to DESTDIR. (shallow-clone)"
  (let ((destpath (concat destdir (file-name-nondirectory remote-url))))
    (if (file-directory-p destpath)
        (feather-git-pull-head pkg destpath)
      (let ((default-directory (expand-file-name destdir)))
        (feather-command-queue
         pkg
         `(("pwd")
           ("git" "clone" "-depth" "1" ,remote-url)))))))

;; (feather-git-clone-specific "https://github.com/conao3/cort.el"
;;                             "v0.1" feather-repos-dir)
(defun feather-git-clone-specific (pkg remote-url spec destdir)
  "Clone REMOTE-URL repository SPEC only to DESTDIR. (shallow-clone)"
  (let* ((repo-name (file-name-nondirectory remote-url))
         (destpath  (concat destdir repo-name)))
    (if (file-directory-p destpath)
        (let ((default-directory (expand-file-name destpath)))
          (feather-command-queue
           pkg
           `(("pwd")
             ("echo" "Repostory is already existed.")
             ("echo")
             ("echo" "If you want to check out to another commit,")
             ("echo" "first delete repository by `remove-package'."))))
      (let ((default-directory (expand-file-name destdir)))
        (feather-command-queue
         pkg
         `(("pwd")
           ("mkdir" ,repo-name)
           ("cd" ,repo-name)
           ("git" "init")
           ("git" "remote" "add" "origin" ,remote-url)
           ("git" "fetch" "-depth" "1" "origin" ,spec)
           ("git" "reset" "-hard" "FETCH_HEAD")))))))

;; (feather-git-pull-head (concat feather-recipes-dir "melpa"))
(defun feather-git-pull-head (pkg destpath)
  "Pull repository"
  (let ((default-directory (expand-file-name destpath)))
    (feather-command-queue
     pkg
     `(("pwd")
       ("git" "pull" "origin" "master")))))

(defun feather-git-unshalow (pkg destpath)
  "Unshallow repository to fetch whole repository.

see https://stackoverflow.com/questions/37531605/how-to-test-if-git-repository-is-shallow"
  (let ((default-directory (expand-file-name destpath)))
    (feather-command-queue
     pkg
     `(("pwd")
       ("git" "fetch" "-unshallow")
       ("git" "checkout" "master")))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;  Package contorollers
;;

(defun feather-activate (pkg)
  "Activate PKG with dependencies packages."
  )

(defun feather-generate-autoloads (pkg)
  "Generate autoloads .el file"
  )

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;  Interactive functions
;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;  General manage packages
;;

;;;###autoload
(defun feather-installed-package-info (pkg)
  "Return installed package info.
If package haven't installed yet, return nil.
If package have removed, return (:state :removed)"
  (let ((pkg* (intern (format ":%s" pkg))))
    (plist-member feather-installed-plist pkg*)))

;;;###autoload
(defun feather-package-installed-p (pkg)
  (let ((pkg* (intern (format ":%s" pkg))))
    (let ((info (feather-installed-package-info pkg)))
      (feather-truep
       (and info
            (not (eq (plist-get info :state) :removed)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;  Remove packages
;;

;;;###autoload
(defun feather-autoremove ()
  "Remove packages that are no more needed.
Packages that are no more needed by other packages in
`feather-selected-packages-list' and their dependencies will be deleted."
  (interactive)
  (feather-initialize)
  
  (let ((lst (feather-install-selected-packages)))
    (mapc (lambda (x) (delq x lst) feather-selected-packages-list))
    (mapc (lambda (x) (feather-remove x)) lst)))

;;;###autoload
(defun feather-remove (pkg &optional force-p)
  "Remove specified package named PKG.
If you want to remove packages no more needed, call `feather-autoremove'."
  (interactive "nRemove package: ")
  (feather-initialize)

  (let* ((pkg* (intern (format ":%s" pkg))))
    (when (and (feather-package-installed-p pkg)
               (or force-p
                   (y-or-n-p (format "Really remove %s?" pkg))))
      (condition-case err
          (let ((info (feather-installed-package-info pkg)))
            ;; delete package build-files
            (mapc #'delete-file (plist-get info :build-files))
            
            ;; delete package source dir
            (delete-directory (concat feather-repos-dir pkg))

            ;; show info
            (feather-message 'feather-remove
                             "Complete remove. Refresh Emacs."))
        (error (feather-message 'feather-remove err :warning))))))

;;;###autoload
(defun feather-clean ()
  "Clean feather working directory and build directory."
  (interactive)
  (feather-initialize)
  )

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;  Install packages
;;

;;;###autoload
(defun feather-install-selected-packages ()
  "Install `feather-selected-packages-list' listed packages."
  (interactive)
  (feather-initialize)
  
  (mapc (lambda (x) (feather-install x)) feather-selected-packages-list))

;;;###autoload
(defun feather-install (pkg)
  "Install specified package named PKG."
  (interactive)
  (feather-initialize)

  ;; remove old package if installed.
  (when (feather-package-installed-p pkg)
    (when (y-or-n-p (format "%s is already installed. Reinstall?" pkg))
      (feather-remove pkg))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;  Manage recipes
;;

;;;###autoload
(defun feather-refresh (&optional cache-p)
  "Reflesh package recipes specified `feather-fetcher-list'.
The URL corresponding to the symbol is managed with `feather-fetcher-url-alist'."
  (interactive)
  (feather-initialize)
  
  ;; clear all recipes.
  (setq feather-recipes (make-hash-table :test 'eq))

  ;; add advice to show progress
  (feather-advice-add 'url-display-percentage :before #'feather-show-download-progress)

  ;; download recipe files, read, append, save it.
  (mapc (lambda (x)
          (let* ((var-sym (intern (format "feather-recipes--%s" x)))
                 (filepath (format "%s%s.el" feather-recipes-dir var-sym)))

            ;; define recipe var
            (eval `(defvar ,var-sym))

            ;; load, or donload recipe if not recipe exist or chache-p is nil
            (condition-case err
                (progn
                  (with-temp-file filepath
                    (if (or (not cache-p) (not (file-exists-p filepath)))
                        (url-insert-file-contents
                         (cdr (assoc x feather-fetcher-url-alist)))
                      (insert-file-contents filepath))

                    ;; read file contents as sexp
                    ;; TODO: read from list support for Emacs-22
                    (eval `(setq ,var-sym (read (buffer-string)))))

                  ;; merge to main recipes var
                  (feather-asetq (it feather-recipes)
                    (feather-ht-merge it (eval var-sym))))
              (error
               (feather-message 'feather-refresh err :error)))))
        ;; updated after elements. first value will adoped.
        (reverse feather-fetcher-list))

  ;; remove advice
  (feather-advice-remove 'url-display-percentage #'feather-show-download-progress)

  ;; show status
  (feather-message 'feather-refresh
                   (format "Completed! %s recipes available."
                           (hash-table-count feather-recipes))))

;;;###autoload
(defun feather-list-packages ()
  "Show available packages list."
  (interactive)
  (feather-initialize)
  feather-recipes)

;;;###autoload
(defun feather-package-info (pkg)
  "Show package info.

such as (feather-package-info :zzz-to-char)"
  (interactive)
  (feather-initialize)
  (gethash pkg feather-recipes))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;  Initialize feather
;;

;;;###autoload
(defun feather-initialize ()
  "Initialize `feather'"
  (interactive)
  (unless feather-initialized
    ;; create dir
    (mapc (lambda (x) (unless (file-directory-p x)
                        (make-directory x t)))
          `(,feather-repos-dir ,feather-recipes-dir ,feather-build-dir))

    ;; add load-path
    (add-to-list 'load-path feather-build-dir)

    ;; initialized frg
    (setq feather-initialized t)))

(provide 'feather)
;;; feather.el ends here
