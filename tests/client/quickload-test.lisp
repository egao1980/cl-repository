(defpackage :cl-repository-client/tests/quickload-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/quickload
                #:asdf-dep-name
                #:system-direct-deps
                #:collect-missing-asdf-deps
                #:compute-install-plan
                #:*missing-deps-accumulator*)
  (:import-from :cl-repository-client/source-policy
                #:*source-policy*
                #:call-with-policy-overrides))
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
   '(("ai-agent-protocol/mcp" :oci) ("ai-agent-protocol" :oci)) nil nil nil
   (lambda ()
     (let ((cl-repository-client/quickload::*registries* nil)
           (plan (compute-install-plan '("ai-agent-protocol/mcp" "ai-agent-protocol")
                                       :force t)))
       (ok (equal plan '(("ai-agent-protocol"))))
       (ok (null *missing-deps-accumulator*))))))

(deftest test-compute-plan-plus-keeps-asdf-name
  "cl+ssl stays the ASDF name in the plan; registry lookup encodes separately."
  (call-with-policy-overrides
   '(("cl+ssl" :oci)) nil nil nil
   (lambda ()
     (let ((cl-repository-client/quickload::*registries* nil)
           (plan (compute-install-plan '("cl+ssl") :force t)))
       (ok (equal plan '(("cl+ssl"))))
       (ok (null *missing-deps-accumulator*))))))