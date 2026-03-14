(uiop:define-package :cl-repository-packager/tests/all
  (:use :cl)
  (:use-reexport
   :cl-repository-packager/tests/manifest-builder-test
   :cl-repository-packager/tests/asdf-plugin-test
   :cl-repository-packager/tests/discover-systems-test
   :cl-repository-packager/tests/normalize-dep-test
   :cl-repository-packager/tests/source-adapter-test
   :cl-repository-packager/tests/anchor-manifest-test
   :cl-repository-packager/tests/layer-builder-test))
