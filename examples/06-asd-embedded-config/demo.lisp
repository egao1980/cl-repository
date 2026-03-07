#!/usr/bin/env -S ros -Q --
;;; Demo: auto-package-spec reads OCI config from .asd :properties
;;; Requires: OCI registry at localhost:5050.

(asdf:load-system "cl-repository-packager")
(asdf:load-system "cl-repository-client")

;;; --- Register the example system's directory with ASDF ---

(let ((example-dir (uiop:pathname-directory-pathname *load-truename*)))
  (asdf:initialize-source-registry
   `(:source-registry
     (:tree ,(namestring example-dir))
     :inherit-configuration)))

;;; --- Introspect and publish string-tools ---

(format t "~%=== Introspecting string-tools from .asd ===~%")
(asdf:load-system "string-tools")

(let ((spec (cl-repository-packager/asdf-plugin:auto-package-spec "string-tools")))
  (format t "  Name:        ~a~%" (cl-repository-packager/build-matrix:package-spec-name spec))
  (format t "  Version:     ~a~%" (cl-repository-packager/build-matrix:package-spec-version spec))
  (format t "  Description: ~a~%" (cl-repository-packager/build-matrix::package-spec-description spec))
  (format t "  Depends-on:  ~a~%" (cl-repository-packager/build-matrix::package-spec-depends-on spec))
  (format t "  Provides:    ~a~%" (cl-repository-packager/build-matrix::package-spec-provides spec))

  (format t "~%=== Building OCI artifact ===~%")
  (let ((result (cl-repository-packager/build-matrix:build-package spec)))
    (format t "  Blobs:     ~d~%" (length (cl-repository-packager/build-matrix:build-result-blobs result)))
    (format t "  Manifests: ~d~%" (length (cl-repository-packager/build-matrix:build-result-manifests result)))

    (format t "~%=== Publishing to localhost:5050 ===~%")
    (cl-repository-packager/publisher:publish-package
      "http://localhost:5050" "cl-systems/string-tools" "1.0.0" result)))

;;; --- Also show crypto-wrapper spec (won't publish - no native libs present) ---

(format t "~%=== Introspecting crypto-wrapper from .asd ===~%")
(let ((spec (cl-repository-packager/asdf-plugin:auto-package-spec "crypto-wrapper")))
  (format t "  Name:           ~a~%" (cl-repository-packager/build-matrix:package-spec-name spec))
  (format t "  CFFI-libraries: ~a~%" (cl-repository-packager/build-matrix::package-spec-cffi-libraries spec))
  (format t "  Overlays:       ~d platform(s)~%"
          (length (cl-repository-packager/build-matrix:package-spec-overlays spec))))

;;; --- Install and use from OCI ---

(format t "~%=== Loading string-tools from OCI ===~%")
(cl-repo:add-registry "http://localhost:5050")
;; Clear to force re-discovery from OCI
(asdf:clear-system "string-tools")
(asdf:clear-source-registry)
(cl-repo:load-system "string-tools")

(format t "~%  (string-tools:kebab-case \"HelloWorld\") => ~a~%"
        (funcall (find-symbol "KEBAB-CASE" :string-tools) "HelloWorld"))
(format t "  (string-tools:snake-case \"FooBarBaz\") => ~a~%"
        (funcall (find-symbol "SNAKE-CASE" :string-tools) "FooBarBaz"))

(format t "~%=== Done ===~%")
