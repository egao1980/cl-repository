#!/usr/bin/env -S ros -Q --
;;; Publish the my-math system to a local OCI registry.
;;; Requires: OCI registry at localhost:5050.

(asdf:load-system "cl-repository-packager")

(let* ((spec (make-instance 'cl-repository-packager/build-matrix:package-spec
               :name "my-math"
               :version "1.0.0"
               :source-dir (merge-pathnames "my-math/"
                             (uiop:pathname-directory-pathname *load-truename*))
               :description "A tiny math library"
               :author "Example Author"
               :license "MIT"
               :depends-on nil
               :provides '("my-math")))
       (result (cl-repository-packager/build-matrix:build-package spec)))
  (format t "~%Built OCI artifact: ~a blobs, ~a manifests~%"
          (length (cl-repository-packager/build-matrix:build-result-blobs result))
          (length (cl-repository-packager/build-matrix:build-result-manifests result)))
  (cl-repository-packager/publisher:publish-package
    "http://localhost:5050" "cl-systems/my-math" "1.0.0" result)
  (format t "~%Published! Try: cl-repo:load-system \"my-math\"~%"))
