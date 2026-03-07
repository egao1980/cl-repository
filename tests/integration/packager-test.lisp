(in-package :cl-repository/tests/integration)

(defun make-test-source-dir ()
  "Create a temp directory with a minimal CL system for testing."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "cl-repo-test-~a/" (get-universal-time))
                               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    ;; Write a minimal .asd
    (with-open-file (s (merge-pathnames "hello-test.asd" dir)
                       :direction :output :if-exists :supersede)
      (format s "(defsystem \"hello-test\"~%")
      (format s "  :version \"0.1.0\"~%")
      (format s "  :description \"A test system\"~%")
      (format s "  :license \"MIT\"~%")
      (format s "  :components ((:file \"hello\")))~%"))
    ;; Write a minimal source file
    (with-open-file (s (merge-pathnames "hello.lisp" dir)
                       :direction :output :if-exists :supersede)
      (format s "(defpackage :hello-test (:use :cl) (:export #:greet))~%")
      (format s "(in-package :hello-test)~%")
      (format s "(defun greet () \"Hello from OCI!\")~%"))
    dir))

(deftest build-and-publish-source-only
  (testing "Build a pure-Lisp package and publish to registry"
    (let* ((source-dir (make-test-source-dir))
           (reg (make-registry *registry-url*))
           (repo (format nil "~a/hello-test" *test-namespace*))
           (tag "0.1.0")
           (spec (make-instance 'package-spec
                                :name "hello-test"
                                :version tag
                                :source-dir source-dir
                                :license "MIT"
                                :description "A test system"
                                :depends-on nil
                                :provides '("hello-test"))))
      ;; Build
      (let ((result (build-package spec)))
        (ok (typep result 'build-result))
        (ok (plusp (length (build-result-blobs result))))
        (ok (plusp (length (build-result-manifests result))))
        (ok (stringp (build-result-index-json result)))
        (ok (search "sha256:" (build-result-index-digest result)))
        ;; Publish (new API: registry namespace tag build-result spec)
        (let ((digest (publish-package reg *test-namespace* tag result spec)))
          (ok (stringp digest))
          (ok (search "sha256:" digest))))
      ;; Verify: pull back the image index
      (let ((idx (pull-manifest reg repo tag)))
        (ok (typep idx 'image-index))
        (ok (= (length (image-index-manifests idx)) 1))
        ;; Pull the universal manifest
        (let* ((desc (first (image-index-manifests idx)))
               (m (pull-manifest reg repo (format nil "sha256:~a"
                                                  (digest-hex (descriptor-digest desc))))))
          (ok (typep m 'manifest))
          (ok (= (manifest-schema-version m) 2))
          ;; Verify config blob is pullable
          (let ((cfg-digest (format-digest (descriptor-digest (manifest-config m)))))
            (ok (blob-exists-p reg repo cfg-digest)))
          ;; Verify source layer is pullable
          (ok (plusp (length (manifest-layers m))))
          (let ((layer-digest (format-digest (descriptor-digest (first (manifest-layers m))))))
            (ok (blob-exists-p reg repo layer-digest)))))
      ;; Cleanup
      (uiop:delete-directory-tree source-dir :validate t :if-does-not-exist :ignore))))

(deftest build-and-publish-with-overlay
  (testing "Build a package with a platform overlay and publish"
    (let* ((source-dir (make-test-source-dir))
           ;; Create a fake native lib
           (native-dir (merge-pathnames "lib/linux-amd64/" source-dir)))
      (ensure-directories-exist native-dir)
      (with-open-file (s (merge-pathnames "libhello.so" native-dir)
                         :direction :output :if-exists :supersede
                         :element-type '(unsigned-byte 8))
        (write-sequence (babel:string-to-octets "FAKE-ELF-BINARY" :encoding :utf-8) s))
      (let* ((reg (make-registry *registry-url*))
             (repo (format nil "~a/hello-native" *test-namespace*))
             (tag "0.2.0")
             (spec (make-instance 'package-spec
                                  :name "hello-native"
                                  :version tag
                                  :source-dir source-dir
                                  :license "MIT"
                                  :description "A test system with native deps"
                                  :overlays (list (make-instance
                                                   'cl-repository-packager/build-matrix::overlay-spec
                                                   :os "linux" :arch "amd64"
                                                   :native-paths '("lib/linux-amd64/libhello.so"))))))
        ;; Build and publish
        (let* ((result (build-package spec))
               (digest (publish-package reg *test-namespace* tag result spec)))
          (declare (ignore digest))
          ;; Pull image index - should have 2 manifests (universal + linux/amd64)
          (let ((idx (pull-manifest reg repo tag)))
            (ok (typep idx 'image-index))
            (ok (= (length (image-index-manifests idx)) 2)))))
      ;; Cleanup
      (uiop:delete-directory-tree source-dir :validate t :if-does-not-exist :ignore))))
