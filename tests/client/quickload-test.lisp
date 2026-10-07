(defpackage :cl-repository-client/tests/quickload-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/quickload
                #:asdf-dep-name
                #:system-direct-deps
                #:collect-missing-asdf-deps
                #:extra-with-install-names
                #:compute-install-plan
                #:*missing-deps-accumulator*)
  (:import-from :cl-repository-client/source-policy
                #:*source-policy*
                #:call-with-policy-overrides)
  (:import-from :cl-repository-client/constraint-builder
                #:list-tags/retry
                #:*tag-list-attempts*)
  (:import-from :cl-oci-client/registry #:make-registry)
  (:import-from :cl-oci-client/conditions #:registry-error))
(in-package :cl-repository-client/tests/quickload-test)

(deftest test-asdf-dep-name-string
  (ok (string= "alexandria" (asdf-dep-name "Alexandria")))
  (ok (string= "alexandria" (asdf-dep-name 'alexandria))))

(deftest test-asdf-dep-name-version
  (ok (string= "foo" (asdf-dep-name '(:version "foo" "1.0")))))

(deftest test-asdf-dep-name-feature
  (ok (string= "uiop" (asdf-dep-name (list :feature (first *features*) "uiop"))))
  (ok (null (asdf-dep-name (list :feature (gensym) "nope")))))

(deftest test-asdf-dep-name-require
  (ok (null (asdf-dep-name '(:require "sb-posix")))))

(deftest test-system-direct-deps-findable
  (let ((deps (system-direct-deps "asdf")))
    (ok (listp deps))))

(deftest test-collect-missing-skips-local-root
  ;; asdf is always findable; collecting from it should not list "asdf" itself.
  (let ((missing (collect-missing-asdf-deps '("asdf"))))
    (ok (not (member "asdf" missing :test #'string=)))))

(deftest test-extra-with-install-names
  "CI :with must install even when ASDF already finds a QL dummy of the same name."
  (ok (equal '("mgl-pax" "dref" "autoload")
             (extra-with-install-names '("mgl-pax" "dref" "autoload"))))
  (ok (equal '("mgl-pax")
             (extra-with-install-names '(("mgl-pax" :version "0.5")))))
  (ok (equal '("mgl-pax")
             (extra-with-install-names '("mgl-pax" "MGL-PAX")))))

(deftest test-ensure-deps-with-own-secondary-is-local
  "compute-protocol#1 test-abcl: :with (\"foo/capability\") must not install a
   published FOO next to the checkout (it shadowed the system under test).
   The secondary is a local root; only its missing deps are installed."
  (let* ((dir (uiop:ensure-directory-pathname
               (uiop:ensure-pathname
                (format nil "~a/cl-repo-ensdep-~36r/" (uiop:temporary-directory) (random (expt 36 6))))))
         (asd (merge-pathnames "cl-ensdep-foo.asd" dir))
         (calls '())
         (sym 'cl-repository-client/quickload::ensure-systems)
         (orig (fdefinition sym)))
    (ensure-directories-exist dir)
    (with-open-file (out asd :direction :output :if-exists :supersede)
      (write-string "(defsystem \"cl-ensdep-foo\" :depends-on ())
(defsystem \"cl-ensdep-foo/extra\" :depends-on (\"cl-ensdep-foo\" \"cl-ensdep-bogus-dep\"))" out))
    (push dir asdf:*central-registry*)
    (unwind-protect
         (progn
           (setf (fdefinition sym)
                 (lambda (systems &rest keys)
                   (declare (ignore keys))
                   (push (copy-list systems) calls)
                   nil))
           (let ((*standard-output* (make-broadcast-stream)))
             (cl-repository-client/quickload:ensure-system-dependencies
              "cl-ensdep-foo" :also-tests nil :with '("cl-ensdep-foo/extra")))
           (let ((installed (reduce #'append calls)))
             (ok (member "cl-ensdep-bogus-dep" installed :test #'string=))
             (ng (member "cl-ensdep-foo" installed :test #'string=))
             (ng (member "cl-ensdep-foo/extra" installed :test #'string=))))
      (setf (fdefinition sym) orig)
      (setf asdf:*central-registry* (remove dir asdf:*central-registry*))
      (asdf:clear-system "cl-ensdep-foo")
      (asdf:clear-system "cl-ensdep-foo/extra")
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest test-compute-plan-ql-only-queues-fallback
  "cl-stack#165: :ql source must not die with 'not found in any registry'
   and must queue the system for Quicklisp fallback."
  (call-with-policy-overrides
   '(("not-in-oci-xyz" :ql)) nil nil nil
   (lambda ()
     (let ((plan (compute-install-plan '("not-in-oci-xyz") :force t)))
       (ok (null plan))
       (ok (member "not-in-oci-xyz" *missing-deps-accumulator* :test #'string=))))))

(deftest test-compute-plan-resolution-error-oci-direct-fallback
  "When SAT signals dependency-resolution-error but OCI is allowed, queue a
   direct install entry instead of dropping the system."
  (call-with-policy-overrides
   '(("missing-oci-pkg-xyz" :oci)) nil nil nil
   (lambda ()
     ;; No registries → build-install-plan errors \"not found in any registry\".
     (let ((cl-repository-client/quickload::*registries* nil)
           (plan (compute-install-plan '("missing-oci-pkg-xyz") :force t)))
       (ok (equal plan '(("missing-oci-pkg-xyz"))))
       (ok (null *missing-deps-accumulator*))))))

(deftest test-compute-plan-slash-secondary-dedupes-to-primary
  "ASDF foo/bar is not a GHCR repo. SAT/plan must install foo."
  (call-with-policy-overrides
   '(("not-in-oci-xyz/mcp" :oci) ("not-in-oci-xyz" :oci)) nil nil nil
   (lambda ()
     (let ((cl-repository-client/quickload::*registries* nil)
           (plan (compute-install-plan '("not-in-oci-xyz/mcp" "not-in-oci-xyz")
                                       :force t)))
       (ok (equal plan '(("not-in-oci-xyz"))))
       (ok (null *missing-deps-accumulator*))))))

(deftest test-compute-plan-plus-keeps-asdf-name
  "cl+ssl-style names stay the ASDF name in the plan; registry lookup encodes separately."
  (call-with-policy-overrides
   '(("not+plus-xyz" :oci)) nil nil nil
   (lambda ()
     (let ((cl-repository-client/quickload::*registries* nil)
           (plan (compute-install-plan '("not+plus-xyz") :force t)))
       (ok (equal plan '(("not+plus-xyz"))))
       (ok (null *missing-deps-accumulator*))))))
;;; list-tags/retry — transient registry failures must not be silent NILs.

(defun %call-capturing-log (fn)
  "Call FN with cl-oci msg output captured; return (values result log)."
  (let (result)
    (let ((log (with-output-to-string (s)
                 (let ((cl-oci/runtime:*quiet* nil)
                       (*standard-output* s))
                   (setf result (funcall fn))))))
      (values result log))))

(deftest test-list-tags-retry-logs-and-returns-nil
  "Unreachable registry: every attempt fails, each is logged, result is NIL (no signal)."
  (let ((*tag-list-attempts* 2)
        (reg (make-registry "http://127.0.0.1:9" :insecure-p t)))
    (multiple-value-bind (result log)
        (%call-capturing-log (lambda () (list-tags/retry reg "cl-systems/nope")))
      (ok (null result))
      (ok (search "tag listing failed (attempt 1/2)" log))
      (ok (search "tag listing failed (attempt 2/2)" log)))))

(deftest test-list-tags-retry-404-is-final
  "HTTP 404 is a real answer (unknown repo): no retry, no log, NIL."
  (let ((calls 0)
        (*tag-list-attempts* 3)
        (reg (make-registry "http://127.0.0.1:9" :insecure-p t)))
    (multiple-value-bind (result log)
        (%call-capturing-log
         (lambda ()
           (list-tags/retry reg "x/y"
                            :lister (lambda (r p)
                                      (declare (ignore r p))
                                      (incf calls)
                                      (error 'registry-error :status 404)))))
      (ok (null result))
      (ok (= calls 1))
      (ok (string= log "")))))

(deftest test-list-tags-retry-403-is-final
  "HTTP 401/403 (token denied for an unknown/private repo) is final: one call,
   one log line, NIL."
  (let ((calls 0)
        (*tag-list-attempts* 3)
        (reg (make-registry "http://127.0.0.1:9" :insecure-p t)))
    (multiple-value-bind (result log)
        (%call-capturing-log
         (lambda ()
           (list-tags/retry reg "x/y"
                            :lister (lambda (r p)
                                      (declare (ignore r p))
                                      (incf calls)
                                      (error 'registry-error :status 403)))))
      (ok (null result))
      (ok (= calls 1))
      (ok (search "not accessible" log))
      (ng (search "attempt" log)))))

(deftest test-list-tags-retry-recovers
  "A transient failure followed by success returns the tags."
  (let ((calls 0)
        (*tag-list-attempts* 3)
        (reg (make-registry "http://127.0.0.1:9" :insecure-p t)))
    (multiple-value-bind (result log)
        (%call-capturing-log
         (lambda ()
           (list-tags/retry reg "x/y"
                            :lister (lambda (r p)
                                      (declare (ignore r p))
                                      (if (= (incf calls) 1)
                                          (error 'registry-error :status 503)
                                          '("0.1.0" "latest"))))))
      (ok (equal result '("0.1.0" "latest")))
      (ok (= calls 2))
      (ok (search "(attempt 1/3)" log)))))
