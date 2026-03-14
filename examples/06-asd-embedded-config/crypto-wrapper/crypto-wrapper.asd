(defsystem "crypto-wrapper"
  :version "1.0.0"
  :author "Example Author"
  :license "MIT"
  :description "CFFI wrapper for a native crypto library"
  :depends-on ("cffi")
  ;; OCI packaging config embedded in the .asd
  :properties (:cl-repo (:cffi-libraries ("libcrypto-example")
                          :provides ("crypto-wrapper")
                          :overlays ((:platform (:os "linux" :arch "amd64")
                                      :layers ((:role "native-library"
                                                :files (("lib/linux-amd64/libcrypto-example.so"
                                                         . "libcrypto-example.so")))))
                                     (:platform (:os "linux" :arch "arm64")
                                      :layers ((:role "native-library"
                                                :files (("lib/linux-arm64/libcrypto-example.so"
                                                         . "libcrypto-example.so")))))
                                     (:platform (:os "darwin" :arch "arm64")
                                      :layers ((:role "native-library"
                                                :files (("lib/darwin-arm64/libcrypto-example.dylib"
                                                         . "libcrypto-example.dylib"))))))))
  :serial t
  :components ((:file "package")
               (:file "bindings")))
