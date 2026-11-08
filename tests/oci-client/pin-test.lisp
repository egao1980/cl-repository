(defpackage :cl-oci-client/tests/pin-test
  (:use :cl :rove)
  (:import-from :cl-oci-client/pin #:with-loaded-systems-pinned)
  (:import-from :cl-oci-client/registry #:signal-registry-error)
  (:import-from :cl-oci-client/conditions
                #:auth-error #:not-found-error #:registry-error #:registry-error-body))
(in-package :cl-oci-client/tests/pin-test)

(defun %tmp-tree (tag)
  (uiop:ensure-directory-pathname
   (merge-pathnames (format nil "cl-oci-pin-~a-~36r/" tag (random (expt 36 6)))
                    (uiop:temporary-directory))))

(defun %write-system (dir version)
  (ensure-directories-exist dir)
  (with-open-file (s (merge-pathnames "pin-demo.asd" dir) :direction :output :if-exists :supersede)
    (format s "(defsystem \"pin-demo\" :version ~s :components ((:file \"pin-demo\")))~%" version))
  (with-open-file (s (merge-pathnames "pin-demo.lisp" dir) :direction :output :if-exists :supersede)
    (format s "(defpackage :pin-demo (:use :cl)) (in-package :pin-demo) (defparameter *version* ~s)~%" version)))

(deftest loaded-systems-stay-where-they-were-loaded-from
  "The client's http-protocol 0.3.9 was recompiled from an install tree's 0.3.0
   once that tree came first in the registry."
  (let ((live (%tmp-tree "live")) (stale (%tmp-tree "stale"))
        (saved asdf:*source-registry-parameter*))
    (%write-system live "2.0.0")
    (%write-system stale "1.0.0")
    (unwind-protect
         (progn
           (asdf:initialize-source-registry `(:source-registry (:directory ,live) :ignore-inherited-configuration))
           (handler-bind ((warning #'muffle-warning)) (asdf:load-system "pin-demo"))
           ;; The install tree now shadows the loaded copy.
           (asdf:initialize-source-registry
            `(:source-registry (:directory ,stale) (:directory ,live) :ignore-inherited-configuration))
           (with-loaded-systems-pinned ()
             (handler-bind ((warning #'muffle-warning)) (asdf:load-system "pin-demo"))
             (ok (equal "2.0.0" (asdf:component-version (asdf:find-system "pin-demo"))))
             (ok (equal "2.0.0" (symbol-value (find-symbol "*VERSION*" "PIN-DEMO")))))
           (testing "unpinned, the registry order decides"
             (ok (equal "1.0.0" (asdf:component-version (asdf:find-system "pin-demo"))))))
      (asdf:clear-system "pin-demo")
      (when (find-package "PIN-DEMO") (delete-package "PIN-DEMO"))
      (if saved (asdf:initialize-source-registry saved) (asdf:clear-source-registry))
      (uiop:delete-directory-tree live :validate t :if-does-not-exist :ignore)
      (uiop:delete-directory-tree stale :validate t :if-does-not-exist :ignore))))

(deftest registry-errors-are-typed-by-status
  (flet ((signalled (status)
           (handler-case (signal-registry-error status "https://r/v2/x" (babel:string-to-octets "{\"errors\":[]}"))
             (registry-error (e) e))))
    (ok (typep (signalled 401) 'auth-error))
    (ok (typep (signalled 403) 'auth-error))
    (ok (typep (signalled 404) 'not-found-error))
    (let ((e (signalled 503)))
      (ok (and (typep e 'registry-error) (not (typep e '(or auth-error not-found-error)))))
      (ok (equal "{\"errors\":[]}" (registry-error-body e))))))
