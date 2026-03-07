(uiop:define-package :cl-repository-packager/tests/all
  (:use :cl)
  (:use-reexport
   :cl-repository-packager/tests/manifest-builder-test
   :cl-repository-packager/tests/asdf-plugin-test))
