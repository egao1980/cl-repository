(defpackage :cl-repository-client/tests/installer-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/installer #:system-install-path #:role-subdirectory))
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
