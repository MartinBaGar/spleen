;;; standalone-init.el --- Lightweight Emacs profile for omni-splash -*- lexical-binding: t; -*-

;;;; 1. Fast, quiet startup
(setq inhibit-startup-screen t
      inhibit-startup-message t
      inhibit-startup-echo-area-message user-login-name
      initial-scratch-message nil
      frame-inhibit-implied-resize t
      ring-bell-function #'ignore
      use-short-answers t)

(menu-bar-mode -1)
(tool-bar-mode -1)
(scroll-bar-mode -1)

;; Frame defaults for cold non-daemon invocations (`emacs -Q -l ... -f omni-splash-show`)
(setq default-frame-alist
      '((name . "omni-splash")
        (title . "omni-splash")
        (undecorated . t)
        (alpha-background . 92)
        (internal-border-width . 24)
        (menu-bar-lines . 0)
        (tool-bar-lines . 0)
        (vertical-scroll-bars . nil)
        (horizontal-scroll-bars . nil)
        (cursor-type . nil)))

;;;; 2. Typography (Iosevka + Montserrat)
(defun my/omni-setup-fonts (&optional frame)
  "Configure variable-pitch and fixed-pitch faces on FRAME."
  (with-selected-frame (or frame (selected-frame))
    (when (display-graphic-p)
      (set-face-attribute 'default nil :family "Iosevka" :height 115)
      (set-face-attribute 'fixed-pitch nil :family "Iosevka" :height 1.0)
      (set-face-attribute 'variable-pitch nil :family "Montserrat" :height 1.0))))

(add-hook 'after-make-frame-functions #'my/omni-setup-fonts)
(my/omni-setup-fonts)

;;;; 3. Theme (Built-in Modus theme — zero external packages)
(load-theme 'modus-vivendi t)

;;;; 4. Built-in vertical completion (or add load-path for vertico/orderless/consult)
(fido-vertical-mode 1)
(setq completions-detailed t)

;;;; 5. Load `omni-splash`
(eval-and-compile
  (let* ((this-file (or load-file-name byte-compile-current-file buffer-file-name))
         (this-dir (if this-file (file-name-directory this-file) default-directory))
         (repo-root (expand-file-name ".." this-dir))
         (fallback-dir (expand-file-name "~/.config/omni-splash/")))
    (add-to-list 'load-path (if (file-exists-p (expand-file-name "omni-splash.el" repo-root))
                                repo-root
                              fallback-dir))))
(require 'omni-splash)
(provide 'standalone-init)
;;; standalone-init.el ends here
