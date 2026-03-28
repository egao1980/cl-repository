(defpackage :cl-repository-client/tests/config-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/config
                #:read-config #:write-config #:merge-configs
                #:config-value #:generate-default-config
                #:find-project-config #:*project-config-filename*))
(in-package :cl-repository-client/tests/config-test)

(defun with-temp-dir (fn)
  "Create a temp dir, call FN with its path, then clean up."
  (let ((dir (merge-pathnames (format nil "cl-repo-test-~a/" (get-universal-time))
                              (uiop:temporary-directory))))
    (ensure-directories-exist (merge-pathnames "x" dir))
    (unwind-protect (funcall fn dir)
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

;;; read-config / write-config round-trip

(deftest test-read-write-roundtrip
  (with-temp-dir
   (lambda (dir)
     (let ((path (merge-pathnames "cl-repo.conf" dir))
           (config '(:default-source :any
                     :registries (("http://localhost:5050" :namespace "cl-systems"))
                     :sources (("alex" :ql))
                     :rules ((:deny "bad-lib"))
                     :protect ("swank"))))
       (write-config config path)
       (let ((loaded (read-config path)))
         (ok loaded)
         (ok (eq :any (config-value loaded :default-source)))
         (ok (equal '("swank") (config-value loaded :protect)))
         (ok (= 1 (length (config-value loaded :registries))))
         (ok (= 1 (length (config-value loaded :sources))))
         (ok (= 1 (length (config-value loaded :rules)))))))))

(deftest test-read-missing-file
  (ok (null (read-config "/nonexistent/path/cl-repo.conf"))))

;;; merge-configs

(deftest test-merge-scalar-project-wins
  (let ((project '(:default-source :oci))
        (global '(:default-source :ql)))
    (let ((merged (merge-configs project global)))
      (ok (eq :oci (config-value merged :default-source))))))

(deftest test-merge-list-keys-concatenated
  (let ((project '(:rules ((:deny "foo"))))
        (global '(:rules ((:deny "bar")))))
    (let ((merged (merge-configs project global)))
      (ok (= 2 (length (config-value merged :rules))))
      ;; Project rules come first
      (ok (equal '(:deny "foo") (first (config-value merged :rules)))))))

(deftest test-merge-list-keys-dedup
  (let ((project '(:protect ("swank")))
        (global '(:protect ("swank" "slynk"))))
    (let ((merged (merge-configs project global)))
      ;; "swank" already in project, so only "slynk" is appended
      (ok (= 2 (length (config-value merged :protect))))
      (ok (member "swank" (config-value merged :protect) :test #'string=))
      (ok (member "slynk" (config-value merged :protect) :test #'string=)))))

(deftest test-merge-nil-project
  (let ((global '(:default-source :ql :protect ("swank"))))
    (let ((merged (merge-configs nil global)))
      (ok (eq :ql (config-value merged :default-source)))
      (ok (equal '("swank") (config-value merged :protect))))))

(deftest test-merge-nil-global
  (let ((project '(:default-source :oci)))
    (let ((merged (merge-configs project nil)))
      (ok (eq :oci (config-value merged :default-source))))))

;;; find-project-config

(deftest test-find-project-config
  (with-temp-dir
   (lambda (dir)
     (let ((conf (merge-pathnames *project-config-filename* dir)))
       (write-config '(:default-source :any) conf)
       (let ((found (find-project-config dir)))
         (ok found)
         (ok (string= (namestring conf) (namestring found))))))))

(deftest test-find-project-config-walk-upward
  (with-temp-dir
   (lambda (dir)
     (let ((conf (merge-pathnames *project-config-filename* dir))
           (subdir (merge-pathnames "sub/deep/" dir)))
       (ensure-directories-exist (merge-pathnames "x" subdir))
       (write-config '(:default-source :oci) conf)
       (let ((found (find-project-config subdir)))
         (ok found)
         (ok (string= (namestring conf) (namestring found))))))))

(deftest test-find-project-config-not-found
  (with-temp-dir
   (lambda (dir)
     (ok (null (find-project-config dir))))))

;;; generate-default-config

(deftest test-generate-default-config
  (with-temp-dir
   (lambda (dir)
     (let ((path (generate-default-config (merge-pathnames "cl-repo.conf" dir))))
       (ok (probe-file path))
       (let ((config (read-config path)))
         (ok config)
         (ok (eq :any (config-value config :default-source))))))))
