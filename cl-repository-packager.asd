(defsystem "cl-repository-packager"
  :version "0.1.0"
  :author "Nikolai Matiushev"
  :license "MIT"
  :description "ASDF plugin and build matrix for packaging CL systems as OCI artifacts"
  :class :package-inferred-system
  :pathname "src/packager"
  :depends-on ("cl-repository-packager/all")
  :in-order-to ((test-op (test-op "cl-repository-packager/tests"))))

(defsystem "cl-repository-packager/tests"
  :pathname "tests/packager"
  :depends-on ("cl-repository-packager" "rove")
  :serial t
  :components ((:file "manifest-builder-test")
               (:file "asdf-plugin-test")
               (:file "discover-systems-test")
               (:file "normalize-dep-test")
               (:file "anchor-manifest-test")
               (:file "all"))
  :perform (test-op (o c)
            (symbol-call :rove :run c)))

(register-system-packages "babel" '(:babel))
(register-system-packages "salza2" '(:salza2))
(register-system-packages "flexi-streams" '(:flexi-streams))
