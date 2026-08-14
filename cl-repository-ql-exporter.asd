(defsystem "cl-repository-ql-exporter"
  :version "0.2.0"
  :author "Nikolai Matiushev"
  :license "MIT"
  :description "Quicklisp/Ultralisp to OCI artifact exporter"
  :class :package-inferred-system
  :pathname "src/ql-exporter"
  :depends-on ("cl-repository-ql-exporter/all")
  :in-order-to ((test-op (test-op "cl-repository-ql-exporter/tests"))))

(defsystem "cl-repository-ql-exporter/tests"
  :pathname "tests/ql-exporter"
  :depends-on ("cl-repository-ql-exporter" "rove")
  :serial t
  :components ((:file "dist-parser-test")
               (:file "repackager-test")
               (:file "all"))
  :perform (test-op (o c)
            (symbol-call :rove :run c)))

(register-system-packages "http-protocol" '(:http-protocol :http))
(register-system-packages "http-backend-dexador" '(:http-backend-dexador))
(register-system-packages "babel" '(:babel))
