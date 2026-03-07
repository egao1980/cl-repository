(defsystem "cl-oci"
  :version "0.1.0"
  :author "Nikolai Matiushev"
  :license "MIT"
  :description "CLOS library modeling OCI Image and Distribution specifications"
  :class :package-inferred-system
  :pathname "src/oci"
  :depends-on ("cl-oci/all")
  :in-order-to ((test-op (test-op "cl-oci/tests"))))

(defsystem "cl-oci/tests"
  :pathname "tests/oci"
  :depends-on ("cl-oci" "rove")
  :serial t
  :components ((:file "digest-test")
               (:file "descriptor-test")
               (:file "manifest-test")
               (:file "serialization-test")
               (:file "all"))
  :perform (test-op (o c)
            (symbol-call :rove :run c)))

(register-system-packages "yason" '(:yason))
(register-system-packages "babel" '(:babel))
(register-system-packages "ironclad" '(:ironclad))
(register-system-packages "alexandria" '(:alexandria))
