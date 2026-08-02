(defpackage :cl-repository-client/tests/installer-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/installer #:system-install-path #:role-subdirectory)
  (:import-from :cl-oci/config #:make-cl-system-config))
(in-package :cl-repository-client/tests/installer-test)

(deftest install-path-construction
  (let ((path (system-install-path "alexandria" "1.4")))
    (ok (search "alexandria" (namestring path)))
    (ok (search "1.4" (namestring path)))))

(deftest role-subdirectory-mapping
  (ok (null (cl-repository-client/installer::role-subdirectory "source")))
  (ok (string= (cl-repository-client/installer::role-subdirectory "native-library") "native"))
  (ok (string= (cl-repository-client/installer::role-subdirectory "cffi-grovel-output") "grovel-cache"))
  (ok (string= (cl-repository-client/installer::role-subdirectory "headers") "headers"))
  (ok (string= (cl-repository-client/installer::role-subdirectory "documentation") "docs")))

(defun read-init-file (path)
  "Read PATH as a string."
  (with-open-file (s path :direction :input)
    (let ((buf (make-string (file-length s))))
      (subseq buf 0 (read-sequence buf s)))))

(defun init-file-parses-p (path)
  "Verify the generated init file is a sequence of readable Lisp forms."
  (with-open-file (s path :direction :input)
    (let ((*read-eval* nil) (*package* (find-package :cl-user)))
      (handler-case
          (loop for form = (read s nil :eof) until (eq form :eof) finally (return t))
        (error () nil)))))

(deftest generate-init-file-emits-per-library-search-paths
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "cl-repo-init-test-~a/" (get-universal-time))
                               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    (unwind-protect
         (let* ((config (make-cl-system-config
                         :system-name "cl-calc"
                         :cffi-libraries '(("libcalc" :define-foreign-library "calc::libcalc"
                                            :canary "calc_init" :search-path "lib/")
                                           "libplain")))
                (path (merge-pathnames "cl-repo-init.lisp" dir)))
           (cl-repository-client/installer::generate-init-file dir config)
           (ok (uiop:file-exists-p path))
           (ok (init-file-parses-p path) "generated init file is valid Lisp")
           (let ((content (read-init-file path)))
             ;; native/ always wired up
             (ok (search "(add-dir \"native/\")" content))
             ;; explicit per-library search-path is added
             (ok (search "(add-dir \"lib/\")" content))
             ;; metadata recorded in comments for the canary pattern
             (ok (search "calc::libcalc" content))
             (ok (search "calc_init" content))
             (ok (search "libplain" content))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest generate-init-file-absolute-preloads-native-libs
  (testing "native/ shared libs are emitted as absolute load-foreign-library preloads"
    (let ((dir (uiop:ensure-directory-pathname
                (merge-pathnames (format nil "cl-repo-init-preload-~a/" (get-universal-time))
                                 (uiop:temporary-directory)))))
      (ensure-directories-exist (merge-pathnames "native/" dir))
      (unwind-protect
           (progn
             ;; Touch fake libs — crypto before ssl in emitted order
             (dolist (name '("libssl.so.3" "libcrypto.so.3" "libssl.so" "libcrypto.so"))
               (with-open-file (s (merge-pathnames (format nil "native/~a" name) dir)
                                  :direction :output :if-exists :supersede)
                 (write-string "fake" s)))
             (let* ((config (make-cl-system-config
                             :system-name "cl-stack-ssl"
                             :cffi-libraries '("libssl" "libcrypto")))
                    (path (merge-pathnames "cl-repo-init.lisp" dir)))
               (cl-repository-client/installer::generate-init-file dir config)
               (ok (init-file-parses-p path))
               (let ((content (read-init-file path)))
                 (ok (search "LOAD-FOREIGN-LIBRARY" content))
                 (ok (search "libcrypto.so.3" content))
                 (ok (search "libssl.so.3" content))
                 ;; crypto preload appears before ssl
                 (let ((i-crypto (search "libcrypto.so.3" content))
                       (i-ssl (search "libssl.so.3" content)))
                   (ok (and i-crypto i-ssl (< i-crypto i-ssl))
                       "libcrypto preload before libssl")))))
        (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)))))

(deftest shared-library-pathname-detection
  (ok (cl-repository-client/installer::shared-library-pathname-p #p"/x/libssl.so"))
  (ok (cl-repository-client/installer::shared-library-pathname-p #p"/x/libssl.so.3"))
  (ok (cl-repository-client/installer::shared-library-pathname-p #p"/x/libssl.dylib"))
  (ok (cl-repository-client/installer::shared-library-pathname-p #p"/x/libssl-3-x64.dll"))
  (ng (cl-repository-client/installer::shared-library-pathname-p #p"/x/README.md"))
  (ng (cl-repository-client/installer::shared-library-pathname-p #p"/x/libssl.a")))
