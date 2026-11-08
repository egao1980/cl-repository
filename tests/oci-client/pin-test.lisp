(defpackage :cl-oci-client/tests/pin-test
  (:use :cl :rove)
  (:import-from :cl-oci-client/pin #:with-loaded-systems-pinned
                #:loaded-system-shadows-newer #:shadowed-newer-version)
  (:import-from :cl-oci-client/registry #:signal-registry-error)
  (:import-from :cl-oci-client/conditions
                #:auth-error #:not-found-error #:registry-error #:registry-error-body))
(in-package :cl-oci-client/tests/pin-test)

(defmacro deftest-unpinned (name &body body)
  "DEFTEST whose BODY starts with no pin: cmd-test runs the suite inside its
   own WITH-LOADED-SYSTEMS-PINNED, which a nested one would reuse."
  (let ((doc (when (stringp (first body)) (list (pop body)))))
    `(deftest ,name ,@doc
       (let ((cl-oci-client/pin::*pinned* nil)
             (cl-oci-client/pin::*checked* nil))
         ,@body))))

;;; The suite runs inside test-op, whose ASDF session caches system lookups:
;;; each lookup gets a session of its own so registry changes show, as they do
;;; between two top-level cl-repo steps.
;;; WITH-ASDF-SESSION :OVERRIDE still saw the cached lookup (ASDF 3.3.1); unbind it.
(defun %find (name)
  (let ((asdf/session:*asdf-session* nil))
    (asdf:find-system name)))

(defun %load (name)
  (let ((asdf/session:*asdf-session* nil))
    (handler-bind ((warning #'muffle-warning)) (asdf:load-system name))))

(defun %tmp-tree (tag)
  (uiop:ensure-directory-pathname
   (merge-pathnames (format nil "cl-oci-pin-~a-~36r/" tag (random (expt 36 6)))
                    (uiop:temporary-directory))))

(defun %write-system (dir version)
  (ensure-directories-exist dir)
  (with-open-file (s (merge-pathnames "pin-demo.asd" dir) :direction :output :if-exists :supersede)
    (format s "(defsystem \"pin-demo\" :version ~s :components ((:file \"pin-demo\")))~%" version))
  (with-open-file (s (merge-pathnames "pin-demo.lisp" dir) :direction :output :if-exists :supersede)
    (format s "(defpackage :pin-demo (:use :cl)) (in-package :pin-demo) (defparameter *version* ~s)~%" version)))

(deftest-unpinned loaded-systems-stay-where-they-were-loaded-from
  "The client's http-protocol 0.3.9 was recompiled from an install tree's 0.3.0
   once that tree came first in the registry."
  (let ((live (%tmp-tree "live")) (stale (%tmp-tree "stale"))
        (saved asdf:*source-registry-parameter*))
    (%write-system live "2.0.0")
    (%write-system stale "1.0.0")
    (unwind-protect
         (progn
           (asdf:initialize-source-registry `(:source-registry (:directory ,live) :ignore-inherited-configuration))
           (%load "pin-demo")
           ;; The install tree now shadows the loaded copy.
           (asdf:initialize-source-registry
            `(:source-registry (:directory ,stale) (:directory ,live) :ignore-inherited-configuration))
           (with-loaded-systems-pinned ()
             (%load "pin-demo")
             (ok (equal "2.0.0" (asdf:component-version (%find "pin-demo"))))
             (ok (equal "2.0.0" (symbol-value (find-symbol "*VERSION*" "PIN-DEMO")))))
           (testing "unpinned, the registry order decides"
             (ok (equal "1.0.0" (asdf:component-version (%find "pin-demo"))))))
      (asdf:clear-system "pin-demo")
      (when (find-package "PIN-DEMO") (delete-package "PIN-DEMO"))
      (if saved (asdf:initialize-source-registry saved) (asdf:clear-source-registry))
      (uiop:delete-directory-tree live :validate t :if-does-not-exist :ignore)
      (uiop:delete-directory-tree stale :validate t :if-does-not-exist :ignore))))

(deftest registry-errors-are-typed-by-status
  (flet ((signalled (status)
           (handler-case (signal-registry-error status "https://r/v2/x" (babel:string-to-octets "{\"errors\":[]}"))
             (registry-error (e) e))))
    (ok (typep (signalled 401) 'auth-error))
    (ok (typep (signalled 403) 'auth-error))
    (ok (typep (signalled 404) 'not-found-error))
    (let ((e (signalled 503)))
      (ok (and (typep e 'registry-error) (not (typep e '(or auth-error not-found-error)))))
      (ok (equal "{\"errors\":[]}" (registry-error-body e))))))

(deftest-unpinned pinning-skips-the-checkout
  "cmd-test pins what the image already runs, except the project checkout:
   its systems must load from the checkout even when already loaded."
  (let ((live (%tmp-tree "co")) (other (%tmp-tree "co-other"))
        (saved asdf:*source-registry-parameter*))
    (%write-system live "2.0.0")
    (%write-system other "1.0.0")
    (unwind-protect
         (progn
           (asdf:initialize-source-registry `(:source-registry (:directory ,live) :ignore-inherited-configuration))
           (%load "pin-demo")
           (asdf:initialize-source-registry
            `(:source-registry (:directory ,other) :ignore-inherited-configuration))
           (with-loaded-systems-pinned ()
             (ok (equal "2.0.0" (asdf:component-version (%find "pin-demo")))))
           ;; The loaded copy lives in the excepted checkout: resolve normally.
           (with-loaded-systems-pinned (:except (list live))
             (ok (equal "1.0.0" (asdf:component-version (%find "pin-demo"))))))
      (asdf:clear-system "pin-demo")
      (when (find-package "PIN-DEMO") (delete-package "PIN-DEMO"))
      (if saved (asdf:initialize-source-registry saved) (asdf:clear-source-registry))
      (uiop:delete-directory-tree live :validate t :if-does-not-exist :ignore)
      (uiop:delete-directory-tree other :validate t :if-does-not-exist :ignore))))

(defun %shadow-warnings (loaded-version registry-version)
  "Load pin-demo LOADED-VERSION, put REGISTRY-VERSION first in the registry,
   resolve it twice under the pin: the warnings signalled and the version used."
  (let ((live (%tmp-tree "sh-live")) (other (%tmp-tree "sh-other"))
        (saved asdf:*source-registry-parameter*)
        (seen '()))
    (%write-system live loaded-version)
    (%write-system other registry-version)
    (unwind-protect
         (progn
           (asdf:initialize-source-registry `(:source-registry (:directory ,live) :ignore-inherited-configuration))
           (%load "pin-demo")
           (asdf:initialize-source-registry
            `(:source-registry (:directory ,other) (:directory ,live) :ignore-inherited-configuration))
           (handler-bind ((loaded-system-shadows-newer
                            (lambda (w) (push w seen) (muffle-warning w))))
             (with-loaded-systems-pinned ()
               (%find "pin-demo")
               (values (reverse seen)
                       (asdf:component-version (%find "pin-demo"))))))
      (asdf:clear-system "pin-demo")
      (when (find-package "PIN-DEMO") (delete-package "PIN-DEMO"))
      (if saved (asdf:initialize-source-registry saved) (asdf:clear-source-registry))
      (uiop:delete-directory-tree live :validate t :if-does-not-exist :ignore)
      (uiop:delete-directory-tree other :validate t :if-does-not-exist :ignore))))

(deftest-unpinned pinned-system-warns-when-the-registry-has-newer
  "A project that locks a newer version of a system the client runs gets told
   once that the image keeps the older copy."
  (multiple-value-bind (warnings used) (%shadow-warnings "1.0.0" "2.0.0")
    (ok (equal "1.0.0" used))
    (ok (= 1 (length warnings)))
    (ok (equal "2.0.0" (shadowed-newer-version (first warnings)))))
  (testing "same or older versions in the registry are quiet"
    (ok (null (%shadow-warnings "1.0.0" "1.0.0")))
    (ok (null (%shadow-warnings "2.0.0" "1.0.0")))))

(deftest-unpinned pinning-skips-systems-the-checkout-defines
  "A checkout of a system the client runs (http-backend-async) is tested from
   the checkout: its systems are not pinned to the client's loaded copy."
  (let ((client (%tmp-tree "cl-copy")) (checkout (%tmp-tree "co-def"))
        (saved asdf:*source-registry-parameter*))
    (%write-system client "1.0.0")
    (%write-system checkout "2.0.0")
    (unwind-protect
         (progn
           (asdf:initialize-source-registry `(:source-registry (:directory ,client) :ignore-inherited-configuration))
           (%load "pin-demo")
           (asdf:initialize-source-registry
            `(:source-registry (:directory ,checkout) (:directory ,client) :ignore-inherited-configuration))
           (with-loaded-systems-pinned (:except (list checkout))
             (ok (equal "2.0.0" (asdf:component-version (%find "pin-demo"))))))
      (asdf:clear-system "pin-demo")
      (when (find-package "PIN-DEMO") (delete-package "PIN-DEMO"))
      (if saved (asdf:initialize-source-registry saved) (asdf:clear-source-registry))
      (uiop:delete-directory-tree client :validate t :if-does-not-exist :ignore)
      (uiop:delete-directory-tree checkout :validate t :if-does-not-exist :ignore))))
