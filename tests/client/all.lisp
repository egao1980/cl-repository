(uiop:define-package :cl-repository-client/tests/all
  (:use :cl)
  (:use-reexport
   :cl-repository-client/tests/platform-resolver-test
   :cl-repository-client/tests/lockfile-test
   :cl-repository-client/tests/installer-test))
