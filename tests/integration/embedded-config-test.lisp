(in-package :cl-repository/tests/integration)

(defun make-embedded-config-source-dir ()
  "Create a temp directory with a .asd that uses :properties :cl-repo."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "cl-repo-embedded-~a/" (get-universal-time))
                               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    (with-open-file (s (merge-pathnames "embed-test.asd" dir)
                       :direction :output :if-exists :supersede)
      (format s "(defsystem \"embed-test\"~%")
      (format s "  :version \"3.0.0\"~%")
      (format s "  :author \"Test\"~%")
      (format s "  :license \"MIT\"~%")
      (format s "  :description \"Embedded OCI config test\"~%")
      (format s "  :properties (:cl-repo (:provides (\"embed-test\" \"embed-test/core\")))~%")
      (format s "  :components ((:file \"core\")))~%"))
    (with-open-file (s (merge-pathnames "core.lisp" dir)
                       :direction :output :if-exists :supersede)
      (format s "(defpackage :embed-test (:use :cl) (:export #:hello))~%")
      (format s "(in-package :embed-test)~%")
      (format s "(defun hello () \"hello from embedded config\")~%"))
    dir))

(deftest auto-package-spec-integration
  (testing "auto-package-spec reads :properties :cl-repo and builds+publishes successfully"
    (let ((dir (make-embedded-config-source-dir)))
      (unwind-protect
           (progn
             (asdf:initialize-source-registry
              `(:source-registry (:tree ,(namestring dir)) :inherit-configuration))
             (asdf:clear-system "embed-test")
             ;; Introspect
             (let ((spec (auto-package-spec "embed-test")))
               (ok (string= (package-spec-name spec) "embed-test"))
               (ok (string= (package-spec-version spec) "3.0.0"))
               (ok (equal (cl-repository-packager/build-matrix::package-spec-provides spec)
                          '("embed-test" "embed-test/core")))
               (ok (null (package-spec-overlays spec)))
               ;; Build
               (let ((result (build-package spec)))
                 (ok (typep result 'build-result))
                 (ok (plusp (length (build-result-blobs result))))
                 ;; Publish
                (let* ((reg (make-registry *registry-url*))
                       (repo (format nil "~a/embed-test" *test-namespace*))
                       (digest (publish-package reg *test-namespace* "3.0.0" result spec)))
                   (ok (stringp digest))
                   (ok (search "sha256:" digest))
                   ;; Verify image index round-trip
                   (let ((idx (pull-manifest reg repo "3.0.0")))
                     (ok (typep idx 'image-index))
                     (ok (= (length (image-index-manifests idx)) 1)))))))
        (asdf:clear-system "embed-test")
        (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)))))
