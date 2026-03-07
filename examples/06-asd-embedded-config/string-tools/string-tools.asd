(defsystem "string-tools"
  :version "1.0.0"
  :author "Example Author"
  :license "MIT"
  :description "String utility functions"
  :depends-on ("alexandria")
  ;; OCI packaging config -- auto-package-spec reads this
  :properties (:cl-repo (:provides ("string-tools")))
  :serial t
  :components ((:file "package")
               (:file "tools")))
