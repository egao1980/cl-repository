(in-package :cl-repository/tests/integration)

(deftest install-source-only-system
  (testing "Install a previously published system and verify extracted files"
    ;; First publish something to install
    (let* ((source-dir (make-test-source-dir))
           (reg (make-registry *registry-url*))
           (repo (format nil "~a/installable" *test-namespace*))
           (tag "1.0.0")
           (spec (make-instance 'package-spec
                                :name "installable"
                                :version tag
                                :source-dir source-dir
                                :license "MIT"
                                :provides '("installable"))))
      (let ((result (build-package spec)))
        (publish-package reg *test-namespace* tag result spec))
      (uiop:delete-directory-tree source-dir :validate t :if-does-not-exist :ignore))
    ;; Now install it using the client
    (let* ((install-root (uiop:ensure-directory-pathname
                          (merge-pathnames (format nil "cl-repo-install-test-~a/"
                                                   (get-universal-time))
                                           (uiop:temporary-directory))))
           (repo (format nil "~a/installable" *test-namespace*)))
      ;; Override the systems root for testing
      (let ((cl-repository-client/installer::*systems-root* install-root))
        (let* ((result (cl-repository-client/installer:install-system
                        *registry-url* repo "1.0.0"))
               (install-path (cl-repository-client/installer:install-result-path result)))
          (ok (uiop:directory-exists-p install-path))
          ;; Verify .asd file was extracted
          (ok (uiop:file-exists-p (merge-pathnames "hello-test.asd" install-path)))
          ;; Verify source file was extracted
          (ok (uiop:file-exists-p (merge-pathnames "hello.lisp" install-path)))
          ;; Verify install-result carries registry info
          (ok (cl-repository-client/installer:install-result-registry-url result))))
      ;; Cleanup
      (uiop:delete-directory-tree install-root :validate t :if-does-not-exist :ignore))))
