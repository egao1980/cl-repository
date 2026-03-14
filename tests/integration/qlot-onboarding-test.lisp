(in-package :cl-repository/tests/integration)

(deftest qlot-sync-infers-files-from-common-project-layout
  (let* ((root (uiop:ensure-directory-pathname
                (merge-pathnames (format nil "cl-repo-integration-qlot-~a/" (get-universal-time))
                                 (uiop:temporary-directory))))
         (work (merge-pathnames "sub/dir/" root))
         (installed nil)
         (handled nil))
    (unwind-protect
         (progn
           (ensure-directories-exist work)
           (with-open-file (stream (merge-pathnames "qlfile" root)
                                   :direction :output :if-exists :supersede)
             (format stream "ql split-sequence~%")
             (format stream "github fukamachi/sxql main~%"))
           (with-open-file (stream (merge-pathnames "qlfile.lock" root)
                                   :direction :output :if-exists :supersede)
             (format stream "ql alexandria 1.0.1~%")
             (format stream "github fukamachi/sxql abcdef~%"))
           (let ((orig (symbol-function 'cl-repository-client/commands::cmd-install)))
             (unwind-protect
                  (progn
                    (setf (symbol-function 'cl-repository-client/commands::cmd-install)
                          (lambda (reference &key registry-url namespace)
                            (declare (ignore registry-url namespace))
                            (push reference installed)))
                    (uiop:with-current-directory (work)
                      (cl-repository-client/commands:cmd-sync-qlot
                       :use-lock t
                       :source-handler (lambda (entry) (push entry handled)))))
               (setf (symbol-function 'cl-repository-client/commands::cmd-install) orig)))
           (ok (equal installed '("alexandria:1.0.1")))
           (ok (= (length handled) 1))
           (ok (eq (cl-repository-client/qlot-integration:qlot-entry-kind (first handled)) :github)))
      (when (probe-file root)
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))
