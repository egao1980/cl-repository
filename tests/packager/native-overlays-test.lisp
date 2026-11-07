(defpackage :cl-repository-packager/tests/native-overlays-test
  (:use :cl :rove)
  (:import-from :cl-repository-packager/asdf-plugin
                #:auto-package-spec #:derived-native-overlays #:check-native-libraries)
  (:import-from :cl-repository-packager/build-matrix
                #:package-spec-overlays #:overlay-spec-os #:overlay-spec-arch
                #:overlay-spec-layers))
(in-package :cl-repository-packager/tests/native-overlays-test)

;;; The packager reaches asdf-native through FIND-SYMBOL. Its CI doesn't load
;;; asdf-native, so a stand-in with the same exported names serves here when
;;; the real one isn't loaded; the real component is covered by every
;;; package's native publish.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *stand-in* (not (find-package "ASDF-NATIVE")))
  (unless (find-package "ASDF-NATIVE") (make-package "ASDF-NATIVE" :use '(:cl))))

(when *stand-in*
  (eval
   '(progn
     (defclass asdf-native::native-library (asdf:component)
       ((optional :initarg :optional :initform nil :reader asdf-native::native-library-optional-p)
        (versions :initarg :versions :initform nil)))
     (setf (find-class (intern "NATIVE-LIBRARY" :asdf/interface)) (find-class 'asdf-native::native-library))
     (defmethod asdf:component-relative-pathname ((c asdf-native::native-library)) nil)
     (defmethod asdf:input-files ((o asdf:operation) (c asdf-native::native-library)) nil)
     (defmethod asdf:output-files ((o asdf:operation) (c asdf-native::native-library)) (values nil t))
     (defmethod asdf:perform ((o asdf:operation) (c asdf-native::native-library)) nil)
     (defun asdf-native::native-library-names (c &key os)
       (let ((n (asdf:component-name c)))
         (ecase os
           (:darwin (list (format nil "lib~A.dylib" n)))
           (:windows (list (format nil "~A.dll" n) (format nil "lib~A.dll" n)))
           ((:linux :unix) (list (format nil "lib~A.so.1" n) (format nil "lib~A.so" n))))))
     (export '(asdf-native::native-library asdf-native::native-library-names
               asdf-native::native-library-optional-p)
             "ASDF-NATIVE"))))

(defun touch (path)
  (ensure-directories-exist path)
  (with-open-file (s path :direction :output :if-exists :supersede) (write-string "x" s)))

(defmacro with-project ((dir &key properties (components ''((:native-library "foo") (:native-library "gpu" :optional t))) files) &body body)
  `(let ((,dir (uiop:ensure-directory-pathname
                (merge-pathnames (format nil "cl-repo-native-~a/" (random 100000000))
                                 (uiop:temporary-directory)))))
     (ensure-directories-exist ,dir)
     (unwind-protect
          (progn
            (with-open-file (s (merge-pathnames "nat-demo.asd" ,dir) :direction :output :if-exists :supersede)
              (let ((*package* (find-package :asdf-user)))
                (write `(asdf:defsystem "nat-demo" :version "1.0.0"
                          :properties (:cl-repo ,,properties)
                          :components ,,components)
                       :stream s :case :downcase)))
            (dolist (f ,files) (touch (merge-pathnames f ,dir)))
            (asdf:clear-system "nat-demo")
            (asdf:load-asd (merge-pathnames "nat-demo.asd" ,dir))
            ,@body)
       (asdf:clear-system "nat-demo")
       (uiop:delete-directory-tree ,dir :validate t :if-does-not-exist :ignore))))

(defun overlay-summary (spec)
  "→ sorted ((\"os-arch\" file-name …) …)"
  (sort (loop for o in (package-spec-overlays spec)
              collect (cons (format nil "~A-~A" (overlay-spec-os o) (overlay-spec-arch o))
                            (sort (loop for layer in (overlay-spec-layers o)
                                        append (mapcar #'cdr (getf layer :files)))
                                  #'string<)))
        #'string< :key #'car))

(deftest discovered-platforms-ship-whole-directories
  (with-project (dir :files '("lib/linux-amd64/libfoo.so.1" "lib/linux-amd64/libfoo.so"
                              "lib/linux-amd64/libdep.so"
                              "lib/darwin-arm64/libfoo.dylib" "lib/darwin-arm64/libgpu.dylib"
                              "lib/notaplatform/libfoo.so"))
    (let ((spec (auto-package-spec "nat-demo")))
      (ok (equal (overlay-summary spec)
                 '(("darwin-arm64" "libfoo.dylib" "libgpu.dylib")
                   ("linux-amd64" "libdep.so" "libfoo.so" "libfoo.so.1")))
          "every file in lib/<os>-<arch>/, dependencies included; other dirs ignored")
      (ok (equal (cl-repository-packager/build-matrix::package-spec-cffi-libraries spec) '("foo" "gpu"))
          ":cffi-libraries default to the component names"))))

(deftest missing-required-library-fails
  (with-project (dir :files '("lib/linux-amd64/libgpu.so"))
    (ok (signals (auto-package-spec "nat-demo") 'error) "no libfoo for linux-amd64")))

(deftest declared-platforms-are-strict
  (with-project (dir :properties '(:native-platforms ("linux-amd64" ("windows-amd64" . "out/win/")))
                     :files '("lib/linux-amd64/libfoo.so" "out/win/foo.dll" "lib/darwin-arm64/libfoo.dylib"))
    (ok (equal (overlay-summary (auto-package-spec "nat-demo"))
               '(("linux-amd64" "libfoo.so") ("windows-amd64" "foo.dll")))
        "only the declared platforms; a pair can map to its own directory"))
  (with-project (dir :properties '(:native-platforms ("linux-amd64" "linux-arm64"))
                     :files '("lib/linux-amd64/libfoo.so"))
    (ok (signals (auto-package-spec "nat-demo") 'error) "a declared platform without a directory")))

(deftest directory-template
  (with-project (dir :properties '(:native-platforms ("linux-amd64") :native-directory "build/{os}/{arch}/")
                     :files '("build/linux/amd64/libfoo.so"))
    (ok (equal (overlay-summary (auto-package-spec "nat-demo")) '(("linux-amd64" "libfoo.so"))))))

(deftest explicit-overlays
  (with-project (dir :properties '(:overlays ((:platform (:os "linux" :arch "amd64")
                                               :native-paths ("lib/linux-amd64/libfoo.so")))))
                     :files '("lib/linux-amd64/libfoo.so" "lib/linux-amd64/libextra.so"))
    (ok (= 1 (length (package-spec-overlays (auto-package-spec "nat-demo"))))
        "explicit platform overlays replace the derived ones"))
  (with-project (dir :properties '(:overlays ((:name "cuda" :platform (:os "linux" :arch "amd64")
                                               :native-paths ("lib/linux-amd64-cuda/libggml-cuda.so")))))
                     :files '("lib/linux-amd64/libfoo.so"))
    (ok (= 2 (length (package-spec-overlays (auto-package-spec "nat-demo"))))
        "a named overlay adds to the derived ones")))

(deftest ci-skips-derivation
  (with-project (dir :files '("lib/linux-amd64/libgpu.so"))
    (ok (null (package-spec-overlays (auto-package-spec "nat-demo" :derive-native-overlays nil)))
        "no derivation, so no check of the checkout's lib/")
    (ok (signals (check-native-libraries (asdf:find-system "nat-demo") "linux-amd64" '("libgpu.so")) 'error)
        "the CI check on artifact files still catches a missing library")
    (ok (null (check-native-libraries (asdf:find-system "nat-demo") "windows-amd64" '("libfoo.dll")))
        "lib-prefixed Windows variant accepted; optional gpu may be missing")))

(deftest no-components-no-derivation
  (with-project (dir :components ''((:file "x")) :files '("lib/linux-amd64/libfoo.so" "x.lisp"))
    (ok (null (package-spec-overlays (auto-package-spec "nat-demo")))
        "a source-only system with a stray lib/ gets no overlays")))
