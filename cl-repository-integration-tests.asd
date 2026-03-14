(defsystem "cl-repository-integration-tests"
  :version "0.1.0"
  :author "Nikolai Matiushev"
  :license "MIT"
  :description "Integration tests for cl-repository (requires Docker OCI registry at localhost:5050)"
  :pathname "tests/integration"
  :depends-on ("cl-oci"
               "cl-oci-client"
               "cl-repository-packager"
               "cl-repository-client"
               "cffi"
               "babel"
               "rove")
  :serial t
  :components ((:file "package")
               (:file "registry-test")
               (:file "packager-test")
               (:file "installer-test")
               (:file "embedded-config-test")
               (:file "multi-system-test")
               (:file "qlot-onboarding-test")
               (:file "overlay-test")
               (:file "all"))
  :perform (test-op (o c)
            (symbol-call :rove :run c)))
