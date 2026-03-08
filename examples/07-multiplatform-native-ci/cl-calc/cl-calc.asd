;; Guard for qlot/ASDF scanning -- cffi-grovel may not be loaded yet.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package "CFFI-GROVEL")
    (defpackage "CFFI-GROVEL" (:export "GROVEL-FILE"))))

(defsystem "cl-calc"
  :version "1.0.0"
  :description "Minimal CFFI wrapper around libcalc for multiplatform overlay demo"
  :license "MIT"
  :defsystem-depends-on ("cffi-grovel")
  :depends-on ("cffi")
  :properties (:cl-repo (:cffi-libraries ("libcalc")
                          :provides ("cl-calc")
                          :overlays ((:platform (:os "linux" :arch "amd64")
                                      :native-paths ("lib/linux-amd64/libcalc.so"))
                                     (:platform (:os "linux" :arch "arm64")
                                      :native-paths ("lib/linux-arm64/libcalc.so"))
                                     (:platform (:os "darwin" :arch "arm64")
                                      :native-paths ("lib/darwin-arm64/libcalc.dylib"))
                                     (:platform (:os "darwin" :arch "amd64")
                                      :native-paths ("lib/darwin-amd64/libcalc.dylib")))))
  :serial t
  :components ((:file "package")
               (cffi-grovel:grovel-file "grovel")
               (:file "bindings")))
