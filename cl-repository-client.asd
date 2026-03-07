(defsystem "cl-repository-client"
  :version "0.1.0"
  :author "Nikolai Matiushev"
  :license "MIT"
  :description "Client library for installing CL packages from OCI registries"
  :class :package-inferred-system
  :pathname "src/client"
  :depends-on ("cl-repository-client/all")
  :in-order-to ((test-op (test-op "cl-repository-client/tests"))))

(defsystem "cl-repository-client/tests"
  :pathname "tests/client"
  :depends-on ("cl-repository-client" "rove")
  :serial t
  :components ((:file "platform-resolver-test")
               (:file "lockfile-test")
               (:file "installer-test")
               (:file "solver-test")
               (:file "digest-cache-test")
               (:file "all"))
  :perform (test-op (o c)
            (symbol-call :rove :run c)))

(register-system-packages "babel" '(:babel))
(register-system-packages "chipz" '(:chipz))
(register-system-packages "flexi-streams" '(:flexi-streams))
(register-system-packages "trivial-features" '(:trivial-features))
