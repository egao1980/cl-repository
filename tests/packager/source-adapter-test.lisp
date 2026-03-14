(defpackage :cl-repository-packager/tests/source-adapter-test
  (:use :cl :rove)
  (:import-from :cl-oci/annotations #:+ann-source+ #:+ann-revision+)
  (:import-from :cl-oci/descriptor #:descriptor-annotations)
  (:import-from :cl-repository-packager/source-adapter
                #:github-repo-reference-p #:normalize-github-repo #:build-package-from-source)
  (:import-from :cl-repository-packager/build-matrix
                #:package-spec #:package-spec-name #:build-package #:build-result-manifests)
  (:import-from :cl-repository-packager/manifest-builder
                #:built-manifest #:built-manifest-descriptor))
(in-package :cl-repository-packager/tests/source-adapter-test)

(deftest github-reference-normalization
  (ok (github-repo-reference-p "owner/repo"))
  (ok (string= (normalize-github-repo "owner/repo") "owner/repo"))
  (ok (string= (normalize-github-repo "https://github.com/owner/repo")
               "owner/repo"))
  (ok (string= (normalize-github-repo "https://github.com/owner/repo.git")
               "owner/repo"))
  (ok (signals (normalize-github-repo "not-a-repo") 'error)))

(defun make-temp-source-dir ()
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "cl-repo-source-adapter-test-~a/" (get-universal-time))
                               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    (with-open-file (stream (merge-pathnames "x.lisp" dir)
                            :direction :output
                            :if-exists :supersede)
      (format stream "(in-package :cl-user)~%"))
    dir))

(defun write-test-system (dir system-name)
  (with-open-file (stream (merge-pathnames (format nil "~a.asd" system-name) dir)
                          :direction :output
                          :if-exists :supersede)
    (format stream "(defsystem \"~a\" :version \"0.1.0\" :components ((:file \"~a\")))~%"
            system-name system-name))
  (with-open-file (stream (merge-pathnames (format nil "~a.lisp" system-name) dir)
                          :direction :output
                          :if-exists :supersede)
    (format stream "(defpackage :~a (:use :cl))~%" system-name)))

(deftest build-package-includes-provenance-annotations
  (let ((source-dir (make-temp-source-dir)))
    (unwind-protect
         (let* ((spec (make-instance 'package-spec
                                     :name "prov-test"
                                     :version "1.0.0"
                                     :source-dir source-dir
                                     :source-url "https://github.com/example/prov-test"
                                     :revision "abc123"))
                (result (build-package spec))
                (manifest (first (build-result-manifests result)))
                (ann (descriptor-annotations
                      (built-manifest-descriptor manifest))))
           (ok (string= (gethash +ann-source+ ann)
                        "https://github.com/example/prov-test"))
           (ok (string= (gethash +ann-revision+ ann) "abc123")))
      (uiop:delete-directory-tree source-dir :validate t :if-does-not-exist :ignore))))

(deftest build-package-from-source-requires-system-when-ambiguous
  (let ((source-dir (make-temp-source-dir)))
    (unwind-protect
         (progn
           (write-test-system source-dir "app-main")
           (write-test-system source-dir "app-test")
           (ok (signals (build-package-from-source source-dir) 'error))
           (multiple-value-bind (spec result)
               (build-package-from-source source-dir :system-name "app-main")
             (declare (ignore result))
             (ok (string= (package-spec-name spec) "app-main"))))
      (uiop:delete-directory-tree source-dir :validate t :if-does-not-exist :ignore))))
