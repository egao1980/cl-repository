(uiop:define-package :cl-repository-client/tests/all
  (:use :cl)
  (:use-reexport
   :cl-repository-client/tests/platform-resolver-test
   :cl-repository-client/tests/lockfile-test
   :cl-repository-client/tests/qlot-integration-test
   :cl-repository-client/tests/installer-test
   :cl-repository-client/tests/solver-test
   :cl-repository-client/tests/digest-cache-test
   :cl-repository-client/tests/ocicl-compat-test
   :cl-repository-client/tests/integrity-test
   :cl-repository-client/tests/protected-systems-test
   :cl-repository-client/tests/config-test
   :cl-repository-client/tests/source-policy-test
   :cl-repository-client/tests/quickload-test))
