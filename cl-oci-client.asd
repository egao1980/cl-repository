(defsystem "cl-oci-client"
  :version "0.1.0"
  :author "Nikolai Matiushev"
  :license "MIT"
  :description "OCI Distribution Spec v1.1 HTTP client"
  :class :package-inferred-system
  :pathname "src/oci-client"
  :depends-on ("cl-oci-client/all")
  :in-order-to ((test-op (test-op "cl-oci-client/tests"))))

(defsystem "cl-oci-client/tests"
  :pathname "tests/oci-client"
  :depends-on ("cl-oci-client" "rove")
  :serial t
  :components ((:file "registry-test")
               (:file "all"))
  :perform (test-op (o c)
            (symbol-call :rove :run c)))

(register-system-packages "dexador" '(:dexador :dex))
(register-system-packages "quri" '(:quri))
(register-system-packages "cl-ppcre" '(:cl-ppcre))
(register-system-packages "cl-base64" '(:cl-base64))
(register-system-packages "babel" '(:babel))
(register-system-packages "yason" '(:yason))
