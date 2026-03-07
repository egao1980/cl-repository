(defpackage :cl-repository-packager/tests/asdf-plugin-test
  (:use :cl :rove)
  (:import-from :cl-repository-packager/asdf-plugin #:auto-package-spec)
  (:import-from :cl-repository-packager/build-matrix
                #:package-spec #:package-spec-name #:package-spec-version
                #:package-spec-overlays))
(in-package :cl-repository-packager/tests/asdf-plugin-test)

(defun make-temp-system-dir ()
  "Create a temp directory with a .asd that uses :properties :cl-repo."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "cl-repo-asd-test-~a/" (get-universal-time))
                               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    (with-open-file (s (merge-pathnames "asd-test.asd" dir)
                       :direction :output :if-exists :supersede)
      (format s "(defsystem \"asd-test\"~%")
      (format s "  :version \"2.0.0\"~%")
      (format s "  :author \"Test Author\"~%")
      (format s "  :license \"MIT\"~%")
      (format s "  :description \"System with embedded OCI config\"~%")
      (format s "  :properties (:cl-repo (:cffi-libraries (\"libfoo\")~%")
      (format s "                         :provides (\"asd-test\" \"asd-test/extras\")~%")
      (format s "                         :overlays ((:platform (:os \"linux\" :arch \"amd64\")~%")
      (format s "                                     :native-paths (\"lib/libfoo.so\")))))~%")
      (format s "  :components ((:file \"main\")))~%"))
    (with-open-file (s (merge-pathnames "main.lisp" dir)
                       :direction :output :if-exists :supersede)
      (format s "(defpackage :asd-test (:use :cl))~%"))
    dir))

(deftest auto-package-spec-reads-standard-fields
  (let ((dir (make-temp-system-dir)))
    (unwind-protect
         (progn
           (asdf:initialize-source-registry
            `(:source-registry (:tree ,(namestring dir)) :inherit-configuration))
           (asdf:clear-system "asd-test")
           (let ((spec (auto-package-spec "asd-test")))
             (ok (string= (package-spec-name spec) "asd-test"))
             (ok (string= (package-spec-version spec) "2.0.0"))))
      (asdf:clear-system "asd-test")
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest auto-package-spec-reads-cl-repo-properties
  (let ((dir (make-temp-system-dir)))
    (unwind-protect
         (progn
           (asdf:initialize-source-registry
            `(:source-registry (:tree ,(namestring dir)) :inherit-configuration))
           (asdf:clear-system "asd-test")
           (let ((spec (auto-package-spec "asd-test")))
             ;; :provides from :cl-repo
             (ok (equal (cl-repository-packager/build-matrix::package-spec-provides spec)
                        '("asd-test" "asd-test/extras")))
             ;; :cffi-libraries from :cl-repo
             (ok (equal (cl-repository-packager/build-matrix::package-spec-cffi-libraries spec)
                        '("libfoo")))
             ;; :overlays from :cl-repo
             (ok (= (length (package-spec-overlays spec)) 1))
             (let ((overlay (first (package-spec-overlays spec))))
               (ok (string= (cl-repository-packager/build-matrix::overlay-spec-os overlay) "linux"))
               (ok (string= (cl-repository-packager/build-matrix::overlay-spec-arch overlay) "amd64")))))
      (asdf:clear-system "asd-test")
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest auto-package-spec-defaults-provides-to-system-name
  (testing "When no :provides in :cl-repo, defaults to system name"
    (let ((dir (uiop:ensure-directory-pathname
                (merge-pathnames (format nil "cl-repo-asd-test2-~a/" (get-universal-time))
                                 (uiop:temporary-directory)))))
      (ensure-directories-exist dir)
      (with-open-file (s (merge-pathnames "asd-test2.asd" dir)
                         :direction :output :if-exists :supersede)
        (format s "(defsystem \"asd-test2\" :version \"1.0\" :components ((:file \"m\")))~%"))
      (with-open-file (s (merge-pathnames "m.lisp" dir)
                         :direction :output :if-exists :supersede)
        (format s "(defpackage :asd-test2 (:use :cl))~%"))
      (unwind-protect
           (progn
             (asdf:initialize-source-registry
              `(:source-registry (:tree ,(namestring dir)) :inherit-configuration))
             (asdf:clear-system "asd-test2")
             (let ((spec (auto-package-spec "asd-test2")))
               (ok (equal (cl-repository-packager/build-matrix::package-spec-provides spec)
                          '("asd-test2")))
               (ok (null (cl-repository-packager/build-matrix::package-spec-cffi-libraries spec)))
               (ok (null (package-spec-overlays spec)))))
        (asdf:clear-system "asd-test2")
        (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)))))
