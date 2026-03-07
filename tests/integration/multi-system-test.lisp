(in-package :cl-repository/tests/integration)

(defun make-multi-system-source-dir ()
  "Create a temp directory with multiple .asd files."
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "cl-repo-multi-~a/" (get-universal-time))
                               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    ;; Primary system
    (with-open-file (s (merge-pathnames "multi-main.asd" dir)
                       :direction :output :if-exists :supersede)
      (format s "(defsystem \"multi-main\"~%")
      (format s "  :version \"1.0.0\"~%")
      (format s "  :license \"MIT\"~%")
      (format s "  :description \"Multi-system test\"~%")
      (format s "  :properties (:cl-repo (:provides (\"multi-main\" \"multi-util\")))~%")
      (format s "  :components ((:file \"main\")))~%"))
    ;; Source file
    (with-open-file (s (merge-pathnames "main.lisp" dir)
                       :direction :output :if-exists :supersede)
      (format s "(defpackage :multi-main (:use :cl) (:export #:hello))~%")
      (format s "(in-package :multi-main)~%")
      (format s "(defun hello () \"multi-system test\")~%"))
    dir))

(deftest multi-system-publish-and-verify
  (testing "Publish a multi-system package and verify all repos have content"
    (let* ((source-dir (make-multi-system-source-dir))
           (reg (make-registry *registry-url*))
           (tag "1.0.0")
           (spec (make-instance 'package-spec
                                :name "multi-main"
                                :version tag
                                :source-dir source-dir
                                :license "MIT"
                                :description "Multi-system test"
                                :provides '("multi-main" "multi-util"))))
      (unwind-protect
           (let* ((result (build-package spec))
                  (digest (publish-package reg *test-namespace* tag result spec)))
             (ok (stringp digest))
             ;; Verify primary repo
             (let ((primary-repo (format nil "~a/multi-main" *test-namespace*)))
               (let ((idx (pull-manifest reg primary-repo tag)))
                 (ok (typep idx 'image-index))))
             ;; Verify secondary repo has same content
             (let ((secondary-repo (format nil "~a/multi-util" *test-namespace*)))
               (let ((idx (pull-manifest reg secondary-repo tag)))
                 (ok (typep idx 'image-index)))))
        (uiop:delete-directory-tree source-dir :validate t :if-does-not-exist :ignore)))))

(deftest system-name-anchor-exists
  (testing "System-name anchors are created at :latest"
    (let* ((source-dir (make-multi-system-source-dir))
           (reg (make-registry *registry-url*))
           (tag "1.0.0")
           (spec (make-instance 'package-spec
                                :name "multi-main"
                                :version tag
                                :source-dir source-dir
                                :license "MIT"
                                :provides '("multi-main" "multi-util"))))
      (unwind-protect
           (let ((result (build-package spec)))
             (publish-package reg *test-namespace* tag result spec)
             ;; Verify anchors at :latest exist
             (let ((anchor-repo (format nil "~a/multi-util" *test-namespace*)))
               (let ((obj (pull-manifest reg anchor-repo "latest")))
                 (ok obj)
                 (ok (typep obj 'manifest)))))
        (uiop:delete-directory-tree source-dir :validate t :if-does-not-exist :ignore)))))
