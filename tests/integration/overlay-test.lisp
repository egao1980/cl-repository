(in-package :cl-repository/tests/integration)

(defvar *libcalc-dir*
  (merge-pathnames "examples/07-multiplatform-native-ci/libcalc/"
                   (asdf:system-source-directory "cl-repository-integration-tests")))

(defvar *cl-calc-dir*
  (merge-pathnames "examples/07-multiplatform-native-ci/cl-calc/"
                   (asdf:system-source-directory "cl-repository-integration-tests")))

(defun host-os ()
  (cond
    ((member :linux *features*) "linux")
    ((member :darwin *features*) "darwin")
    ((member :windows *features*) "windows")
    (t "linux")))

(defun host-arch ()
  (cond
    ((member :x86-64 *features*) "amd64")
    ((member :arm64 *features*) "arm64")
    (t "amd64")))

(defun host-lib-name ()
  (if (string= (host-os) "darwin") "libcalc.dylib" "libcalc.so"))

(defun build-libcalc ()
  "Build libcalc for the host platform. Returns path to the shared library."
  (let ((lib-path (merge-pathnames (host-lib-name) *libcalc-dir*)))
    (unless (probe-file lib-path)
      (uiop:run-program (list "make" "-C" (namestring *libcalc-dir*))
                         :output :interactive :error-output :interactive))
    lib-path))

(defun cleanup-libcalc ()
  (ignore-errors
    (uiop:run-program (list "make" "-C" (namestring *libcalc-dir*) "clean")
                       :output nil :error-output nil)))

;;; ---------- Test 1: Batch publish with native overlay ----------

(deftest batch-publish-with-native-overlay
  (testing "Build a package with a real native overlay and publish atomically"
    (let ((lib-path (build-libcalc)))
      (unwind-protect
           (let* ((reg (make-registry *registry-url*))
                  (tag "1.0.0")
                  (spec (make-instance 'package-spec
                           :name "cl-calc-batch"
                           :version tag
                           :source-dir *cl-calc-dir*
                           :license "MIT"
                           :description "Batch overlay test"
                           :depends-on '("cffi")
                           :provides '("cl-calc-batch")
                           :cffi-libraries '("libcalc")
                           :overlays (list
                                      (make-instance
                                       'cl-repository-packager/build-matrix::overlay-spec
                                       :os (host-os) :arch (host-arch)
                                       :native-paths (list (namestring lib-path)))))))
             ;; Build and publish
             (let* ((result (build-package spec))
                    (digest (publish-package reg *test-namespace* tag result spec)))
               (ok (stringp digest))
               (ok (search "sha256:" digest))
               ;; Pull image index -- should have 2 manifests
               (let* ((repo (format nil "~a/cl-calc-batch" *test-namespace*))
                      (idx (pull-manifest reg repo tag)))
                 (ok (typep idx 'image-index))
                 (ok (= (length (image-index-manifests idx)) 2))
                 ;; First is universal (no platform), second is overlay
                 (let ((universal-desc (first (image-index-manifests idx)))
                       (overlay-desc (second (image-index-manifests idx))))
                   (ok (null (cl-oci/descriptor:descriptor-platform universal-desc)))
                   (ok (not (null (cl-oci/descriptor:descriptor-platform overlay-desc))))))))
        (cleanup-libcalc)))))

;;; ---------- Test 2: Incremental overlay publish ----------

(deftest incremental-overlay-publish
  (testing "Publish source-only, then add overlays incrementally"
    (let ((lib-path (build-libcalc)))
      (unwind-protect
           (let* ((reg (make-registry *registry-url*))
                  (tag "2.0.0")
                  (repo-name "cl-calc-incr")
                  (repo (format nil "~a/~a" *test-namespace* repo-name))
                  ;; Source-only spec (no overlays)
                  (spec (make-instance 'package-spec
                           :name repo-name
                           :version tag
                           :source-dir *cl-calc-dir*
                           :license "MIT"
                           :depends-on '("cffi")
                           :provides (list repo-name)
                           :cffi-libraries '("libcalc"))))
             ;; Step 1: Publish source-only
             (let ((result (build-package spec)))
               (publish-package reg *test-namespace* tag result spec))
             ;; Verify: 1 manifest
             (let ((idx (pull-manifest reg repo tag)))
               (ok (typep idx 'image-index))
               (ok (= (length (image-index-manifests idx)) 1)))
             ;; Step 2: Add real overlay for host platform (with source layer for OCI compat)
             (let* ((overlay (make-instance
                              'cl-repository-packager/build-matrix::overlay-spec
                              :os (host-os) :arch (host-arch)
                              :native-paths (list (namestring lib-path))))
                    (src-layer (fetch-source-layer-info
                                reg *test-namespace* repo-name tag))
                    (ov-result (build-overlay repo-name overlay
                                              :version tag
                                              :source-layer src-layer)))
               (publish-overlay reg *test-namespace* repo-name tag ov-result))
             ;; Verify: 2 manifests now
             (let ((idx (pull-manifest reg repo tag)))
               (ok (= (length (image-index-manifests idx)) 2)))
             ;; Step 3: Add a fake overlay for a different platform
             (let* ((fake-lib-dir (uiop:ensure-directory-pathname
                                   (merge-pathnames "fake-native/"
                                                    (uiop:temporary-directory))))
                    (fake-lib (merge-pathnames "libcalc.so" fake-lib-dir)))
               (ensure-directories-exist fake-lib-dir)
               (with-open-file (s fake-lib :direction :output :if-exists :supersede
                                           :element-type '(unsigned-byte 8))
                 (write-sequence (babel:string-to-octets "FAKE-ELF" :encoding :utf-8) s))
               (unwind-protect
                    (let* ((overlay2 (make-instance
                                      'cl-repository-packager/build-matrix::overlay-spec
                                      :os "freebsd" :arch "amd64"
                                      :native-paths (list (namestring fake-lib))))
                           (src-layer (fetch-source-layer-info
                                       reg *test-namespace* repo-name tag))
                           (ov-result2 (build-overlay repo-name overlay2
                                                      :version tag
                                                      :source-layer src-layer)))
                      (publish-overlay reg *test-namespace* repo-name tag ov-result2))
                 (uiop:delete-directory-tree fake-lib-dir :validate t :if-does-not-exist :ignore)))
             ;; Verify: 3 manifests now
             (let ((idx (pull-manifest reg repo tag)))
               (ok (= (length (image-index-manifests idx)) 3))))
        (cleanup-libcalc)))))

;;; ---------- Test 3: Install and load native overlay via CFFI ----------

(deftest install-and-load-native-overlay
  (testing "Publish with overlay, install, load native lib, call into C"
    (let ((lib-path (build-libcalc)))
      (unwind-protect
           (let* ((reg (make-registry *registry-url*))
                  (tag "3.0.0")
                  (repo-name "cl-calc-e2e")
                  (repo (format nil "~a/~a" *test-namespace* repo-name))
                  (spec (make-instance 'package-spec
                           :name repo-name
                           :version tag
                           :source-dir *cl-calc-dir*
                           :license "MIT"
                           :depends-on '("cffi")
                           :provides (list repo-name)
                           :cffi-libraries '("libcalc")
                           :overlays (list
                                      (make-instance
                                       'cl-repository-packager/build-matrix::overlay-spec
                                       :os (host-os) :arch (host-arch)
                                       :native-paths (list (namestring lib-path)))))))
             ;; Publish
             (let ((result (build-package spec)))
               (publish-package reg *test-namespace* tag result spec))
             ;; Install into temp root
             (let* ((install-root (uiop:ensure-directory-pathname
                                   (merge-pathnames
                                    (format nil "cl-repo-overlay-e2e-~a/" (get-universal-time))
                                    (uiop:temporary-directory))))
                    (cl-repository-client/installer::*systems-root* install-root))
               (unwind-protect
                    (let* ((ir (install-system *registry-url* repo tag))
                           (install-dir (install-result-path ir)))
                      ;; Verify structural extraction
                      (ok (uiop:directory-exists-p install-dir))
                      (ok (uiop:file-exists-p (merge-pathnames "cl-calc.asd" install-dir)))
                      ;; Native lib in native/ subdir
                      (let ((native-lib (merge-pathnames
                                         (format nil "native/~a" (host-lib-name))
                                         install-dir)))
                        (ok (uiop:file-exists-p native-lib)
                            (format nil "Expected native lib at ~a" native-lib)))
                      ;; cl-repo-init.lisp generated
                      (ok (uiop:file-exists-p (merge-pathnames "cl-repo-init.lisp" install-dir)))
                      ;; Push native/ into CFFI search path
                      (let ((native-dir (merge-pathnames "native/" install-dir)))
                        (pushnew native-dir cffi:*foreign-library-directories* :test #'equal))
                      ;; Load the native library
                      (let ((lib (cffi:load-foreign-library
                                  (merge-pathnames (format nil "native/~a" (host-lib-name))
                                                   install-dir))))
                        (ok lib "Foreign library loaded")
                        ;; Call calc_version -- validates FFI call into the loaded lib
                        (let ((ver (cffi:foreign-funcall "calc_version" :string)))
                          (ok (string= ver "1.0.0")
                              (format nil "Expected version 1.0.0, got ~a" ver)))
                        ;; calc_add returns a struct by value, which needs the grovel
                        ;; bindings (defcstruct) to decode. That path is exercised by
                        ;; loading the full cl-calc ASDF system in the GH Actions
                        ;; workflows. Here the key validation is: native lib was
                        ;; packaged -> published -> installed -> extracted -> loaded -> callable.
                        (cffi:close-foreign-library lib)))
                 (uiop:delete-directory-tree install-root
                                             :validate t :if-does-not-exist :ignore))))
        (cleanup-libcalc)))))

;;; ---------- Test 4: Unified :layers schema + custom role extraction ----------

(deftest install-overlay-layers-with-custom-role
  (testing "Publish/install overlays with native, grovel and custom role payloads"
    (let* ((overlay-dir (uiop:ensure-directory-pathname
                         (merge-pathnames (format nil "cl-repo-overlay-layered-~a/"
                                                  (get-universal-time))
                                          (uiop:temporary-directory))))
           (native-file (merge-pathnames (host-lib-name) overlay-dir))
           (grovel-file (merge-pathnames "calc.cffi.lisp" overlay-dir))
           (custom-file (merge-pathnames "marker.txt" overlay-dir)))
      (ensure-directories-exist overlay-dir)
      (with-open-file (s native-file :direction :output :if-exists :supersede
                                   :element-type '(unsigned-byte 8))
        (write-sequence (babel:string-to-octets "FAKE-NATIVE-PAYLOAD" :encoding :utf-8) s))
      (with-open-file (s grovel-file :direction :output :if-exists :supersede)
        (format s ";; test grovel output~%"))
      (with-open-file (s custom-file :direction :output :if-exists :supersede)
        (format s "custom role payload~%"))
      (unwind-protect
           (let* ((reg (make-registry *registry-url*))
                  (tag "4.0.0")
                  (repo-name "cl-calc-layered")
                  (repo (format nil "~a/~a" *test-namespace* repo-name))
                  (spec (make-instance 'package-spec
                           :name repo-name
                           :version tag
                           :source-dir *cl-calc-dir*
                           :license "MIT"
                           :depends-on '("cffi")
                           :provides (list repo-name)
                           :cffi-libraries '("libcalc")
                           :overlays
                           (list
                            (make-instance 'cl-repository-packager/build-matrix::overlay-spec
                                           :os (host-os) :arch (host-arch)
                                           :layers
                                           (list
                                            (list :role "native-library"
                                                  :files (list
                                                          (cons (namestring native-file)
                                                                (host-lib-name))))
                                            (list :role "cffi-grovel-output"
                                                  :files (list
                                                          (cons (namestring grovel-file)
                                                                "calc.cffi.lisp")))
                                            (list :role "custom-role"
                                                  :files (list
                                                          (cons (namestring custom-file)
                                                                "marker.txt")))))))))
             (let ((result (build-package spec)))
               (publish-package reg *test-namespace* tag result spec))
             (let* ((install-root (uiop:ensure-directory-pathname
                                   (merge-pathnames
                                    (format nil "cl-repo-overlay-layered-install-~a/"
                                            (get-universal-time))
                                    (uiop:temporary-directory))))
                    (cl-repository-client/installer::*systems-root* install-root))
               (unwind-protect
                    (let* ((ir (install-system *registry-url* repo tag))
                           (install-dir (install-result-path ir)))
                      (ok (uiop:file-exists-p (merge-pathnames
                                               (format nil "native/~a" (host-lib-name))
                                               install-dir)))
                      (ok (uiop:file-exists-p (merge-pathnames "grovel-cache/calc.cffi.lisp"
                                                               install-dir)))
                      ;; Unknown/custom roles fall back to package root extraction.
                      (ok (uiop:file-exists-p (merge-pathnames "marker.txt" install-dir))))
                 (uiop:delete-directory-tree install-root
                                             :validate t :if-does-not-exist :ignore))))
        (uiop:delete-directory-tree overlay-dir :validate t :if-does-not-exist :ignore)))))
