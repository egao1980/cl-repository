(defsystem "cffi-example"
  :version "1.0.0"
  :description "Example CFFI wrapper with native library"
  :depends-on ("cffi")
  :serial t
  :components ((:file "package")
               (:file "bindings")))
