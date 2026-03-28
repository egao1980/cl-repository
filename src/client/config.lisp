(defpackage :cl-repository-client/config
  (:use :cl)
  (:import-from :cl-oci/runtime #:msg)
  (:export #:*global-config-path*
           #:*project-config-filename*
           #:read-config
           #:write-config
           #:find-project-config
           #:load-merged-config
           #:apply-config
           #:config-value
           #:generate-default-config))
(in-package :cl-repository-client/config)

(defvar *global-config-path*
  (merge-pathnames "cl-repository/cl-repo.conf"
                   (or (uiop:getenv-absolute-directory "XDG_CONFIG_HOME")
                       (merge-pathnames ".config/" (user-homedir-pathname))))
  "Path to the global cl-repo configuration file.")

(defvar *project-config-filename* "cl-repo.conf"
  "Filename for project-local configuration.")

;;; Reading / writing

(defun read-config (path)
  "Read a cl-repo.conf file into a plist. Returns NIL if not found or unreadable."
  (when (and path (probe-file path))
    (handler-case
        (with-open-file (s path :direction :input)
          (let ((*read-eval* nil))
            (read s nil nil)))
      (error (e)
        (msg "~&; cl-repo: warning: could not read config ~a: ~a~%" path e)
        nil))))

(defun write-config (config path)
  "Write CONFIG plist to PATH."
  (ensure-directories-exist path)
  (with-open-file (s path :direction :output :if-exists :supersede)
    (format s ";;; cl-repo.conf -- source policy and registry configuration~%")
    (format s ";;; See https://github.com/cl-ai-project/cl-repository for documentation.~%")
    (let ((*print-case* :downcase)
          (*print-pretty* t)
          (*print-right-margin* 100))
      (prin1 config s))
    (terpri s)))

(defun generate-default-config (&optional (path (merge-pathnames *project-config-filename*
                                                                  (uiop:getcwd))))
  "Write a default cl-repo.conf to PATH."
  (write-config '(:default-source :any
                  :registries ()
                  :sources ()
                  :rules ()
                  :protect ("swank" "slynk"))
                path)
  path)

;;; Discovery

(defun find-project-config (&optional (start-dir (uiop:getcwd)))
  "Walk upward from START-DIR looking for cl-repo.conf. Returns path or NIL."
  (let ((dir (uiop:ensure-directory-pathname start-dir)))
    (loop
      for candidate = (merge-pathnames *project-config-filename* dir)
      when (probe-file candidate) do (return candidate)
      do (let ((parent (uiop:pathname-parent-directory-pathname dir)))
           (if (or (null parent) (equal (namestring parent) (namestring dir)))
               (return nil)
               (setf dir parent))))))

;;; Merging

(defvar *list-keys* '(:registries :sources :rules :protect)
  "Config keys whose values are lists and should be concatenated during merge.")

(defun merge-configs (project global)
  "Merge PROJECT and GLOBAL config plists.
   List-valued keys: project entries first, then global (deduped).
   Scalar keys: project wins."
  (let ((result (copy-list (or project global))))
    (when (and project global)
      ;; Merge list keys: project first, append global entries
      (dolist (key *list-keys*)
        (let ((pval (getf project key))
              (gval (getf global key)))
          (when (or pval gval)
            (setf (getf result key)
                  (append (or pval nil)
                          (remove-if (lambda (g)
                                       (member g (or pval nil) :test #'equal))
                                     (or gval nil)))))))
      ;; Scalar keys: project wins (already in result from copy-list of project)
      (loop for (key val) on global by #'cddr
            unless (or (member key *list-keys*)
                       (getf project key))
              do (setf (getf result key) val)))
    result))

(defun load-merged-config (&optional explicit-path)
  "Load and merge configuration. Returns a plist.
   EXPLICIT-PATH overrides project config discovery."
  (let ((global (read-config *global-config-path*))
        (project (if explicit-path
                     (read-config explicit-path)
                     (let ((found (find-project-config)))
                       (when found (read-config found))))))
    (merge-configs project global)))

;;; Applying config to runtime state

(defun apply-config (config)
  "Apply a merged config plist to cl-repository-client runtime variables.
   Deferred: actual variable writes happen in source-policy and quickload
   which import this module. This function returns the config for chaining."
  config)

(defun config-value (config key &optional default)
  "Get a value from a config plist."
  (getf config key default))
