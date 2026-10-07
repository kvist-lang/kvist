;;; kvist-references-test.el --- Reference integration tests -*- lexical-binding: t; -*-
(require 'ert)
;; Keep the test runnable with -Q, just like test_tooling.sh.
(unless (require 'clojure-mode nil t)
  (defvar clojure-mode-map (make-sparse-keymap))
  (define-derived-mode clojure-mode prog-mode "Clojure")
  (defun clojure--put-indentation-spec (&rest _args) nil)
  (provide 'clojure-mode))
(require 'kvist-eval)
(setq kvist-command (getenv "KVIST_REFERENCE_CLI"))

(ert-deftest kvist-reference-keybindings ()
  (with-temp-buffer
    (kvist-mode)
    (should (eq (key-binding (kbd "M-?")) #'xref-find-references))
    (should (eq (key-binding (kbd "C-c g u")) #'kvist-find-usages))
    (kvist-eval-mode 1)
    (should (eq (key-binding (kbd "C-c g u")) #'kvist-find-usages))
    (should (eq (key-binding (kbd "C-c g g")) #'kvist-expand-form-at-point))))

(ert-deftest kvist-references-unsaved-local-symbol-and-utf8-location ()
  (let* ((dir (make-temp-file "kvist-references-emacs-" t))
         (file (expand-file-name "main.kvist" dir))
         (source "(package main)\n(def answer 1)\n(defn run [answer: int]\n  (println \"æ\" answer))\n(defn main [] (println answer))\n")
         buffer)
    (unwind-protect
        (progn
          (with-temp-file file (insert source))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (kvist-mode)
            (goto-char (point-min))
            (search-forward "[answer")
            (let* ((refs (xref-backend-references 'kvist "answer"))
                   (location (xref-item-location (car refs))))
              (should (= (length refs) 1))
              (should (equal (xref-file-location-file location) file))
              (should (= (xref-file-location-line location) 4))
              (should (= (xref-file-location-column location) 15)))
            ;; Query a global from a narrowed, unsaved buffer.  Search position
            ;; is still relative to the whole source; no temporary path leaks.
            (goto-char (point-max))
            (insert "(println answer)\n")
            (goto-char (point-min))
            (search-forward "(def answer")
            (narrow-to-region (line-beginning-position) (line-end-position))
            (let ((refs (xref-backend-references 'kvist "answer")))
              (should (= (length refs) 2))
              (should (equal (mapcar (lambda (ref)
                                      (xref-file-location-line (xref-item-location ref))) refs)
                             '(5 6)))
              (dolist (ref refs)
                (should (equal (xref-file-location-file (xref-item-location ref)) file))))
            (widen)
            (should (buffer-modified-p))
            (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) source))
            (should-not (directory-files dir nil "\\.kvist-symbols-"))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-directory dir t))))

(ert-deftest kvist-references-qualified-symbol-at-point ()
  (let* ((dir (make-temp-file "kvist-references-import-" t))
         (file (expand-file-name "main.kvist" dir))
         (lib-dir (expand-file-name "lib" dir))
         (lib-file (expand-file-name "lib.kvist" lib-dir))
         buffer)
    (unwind-protect
        (progn
          (make-directory lib-dir)
          (with-temp-file lib-file
            (insert "(package lib)\n(def answer 42)\n(defn value [] answer)\n"))
          (with-temp-file file
            (insert "(package main)\n(import service \"lib\")\n(defn main [] (println service.answer))\n"))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (kvist-mode)
            (goto-char (point-min))
            (search-forward "service.answer")
            (let ((refs (xref-backend-references 'kvist (kvist--identifier-at-point))))
              (should (= (length refs) 2))
              (should (file-equal-p (xref-file-location-file (xref-item-location (car refs)))
                                   lib-file))
              (should (= (xref-file-location-line (xref-item-location (car refs))) 3))
              (should (equal (xref-file-location-file (xref-item-location (cadr refs))) file)))
            (should-not (find-buffer-visiting lib-file))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory dir t))))

(ert-deftest kvist-xref-identifier-completion-keeps-source-context ()
  (with-temp-buffer
    (kvist-mode)
    (let* ((source (current-buffer))
           (table (xref-backend-identifier-completion-table 'kvist)))
      ;; Completion runs in the minibuffer, while symbols belong to the source.
      (with-temp-buffer
        (cl-letf (((symbol-function 'kvist--editor-symbols)
                   (lambda (&optional _file)
                     (should (eq (current-buffer) source))
                     '((:name "target") (:name "target-other") (:name "lib.target")))))
          (should (equal (sort (all-completions "target" table) #'string<)
                         '("target" "target-other"))))))))

(ert-deftest kvist-find-usages-interactive-command-paths ()
  (let* ((dir (make-temp-file "kvist-references-interactive-" t))
         (file (expand-file-name "main.kvist" dir))
         (source "(package main)\n(def answer 1)\n(defn run [answer: int]\n  (println answer))\n(defn main [] (run answer))\n")
         buffer)
    (unwind-protect
        (progn
          (with-temp-file file (insert source))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (kvist-mode)
            (kvist-eval-mode 1)
            (goto-char (point-min))
            (search-forward "[answer")
            (let* ((this-command (key-binding (kbd "C-c g u")))
                   (xref-prompt-for-identifier t)
                   (current-prefix-arg nil)
                   displayed
                   (xref-show-xrefs-function
                    (lambda (fetcher _action) (setq displayed (funcall fetcher)))))
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (&rest _) (ert-fail "At-point usages must not prompt"))))
                (call-interactively this-command))
              (should (= (length displayed) 1))
              (should (= (xref-file-location-line (xref-item-location (car displayed))) 4)))
            ;; Exercise M-? with Emacs' default prompting policy, plus the
            ;; Kvist prefix and no-symbol prompts, using real CLI completion.
            (dolist (case (list (list (key-binding (kbd "M-?")) nil nil)
                                (list #'kvist-find-usages '(4) nil)
                                (list #'kvist-find-usages nil t)))
              (when (nth 2 case) (goto-char (point-max)))
              (let* ((this-command (car case))
                     (xref-prompt-for-identifier (default-value 'xref-prompt-for-identifier))
                     (current-prefix-arg (nth 1 case))
                     prompted displayed
                     (xref-show-xrefs-function
                      (lambda (fetcher _action) (setq displayed (funcall fetcher)))))
                (cl-letf (((symbol-function 'completing-read)
                           (lambda (_prompt table &rest _args)
                             (setq prompted t)
                             (should (member "run" (all-completions "ru" table)))
                             "run")))
                  (call-interactively this-command))
                (should prompted)
                (should (= (length displayed) 1))
                (should (= (xref-file-location-line (xref-item-location (car displayed))) 5))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory dir t))))

(ert-deftest kvist-references-expand-project-root-under-home ()
  (let* ((dir (make-temp-file (expand-file-name ".kvist-xref-root-test-" "~") t))
         (file (expand-file-name "main.kvist" dir))
         buffer)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name ".git" dir))
          (with-temp-file file
            (insert "(package main)\n(def answer 1)\n(defn main [] (println answer))\n"))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (kvist-mode)
            (goto-char (point-min))
            (search-forward "(def answer")
            ;; locate-dominating-file abbreviates home paths to ~/..., while
            ;; subprocess arguments must contain the actual directory name.
            (should (string-prefix-p "~/" (locate-dominating-file dir ".git")))
            (should (equal (kvist--project-root file) (file-name-as-directory dir)))
            (let* ((this-command #'kvist-find-usages)
                   (current-prefix-arg nil)
                   displayed
                   (xref-show-xrefs-function
                    (lambda (fetcher _action) (setq displayed (funcall fetcher)))))
              (call-interactively #'kvist-find-usages)
              (should (= (length displayed) 1))
              (should (= (xref-file-location-line (xref-item-location (car displayed))) 3)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory dir t))))
