(defpackage :cl-repository-client/tests/source-policy-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/source-policy
                #:*source-policy* #:*source-rules* #:*default-source*
                #:source-for #:system-denied-p #:oci-allowed-p #:ql-allowed-p
                #:registry-allowed-p #:ql-allowed-by-rules-p
                #:apply-source-config #:call-with-policy-overrides))
(in-package :cl-repository-client/tests/source-policy-test)

(defmacro with-clean-policy (&body body)
  `(let ((*source-policy* (make-hash-table :test 'equal))
         (*source-rules* nil)
         (*default-source* :any))
     ,@body))

;;; source-for

(deftest test-source-for-default
  (with-clean-policy
    (ok (eq :any (source-for "alexandria")))))

(deftest test-source-for-policy-hash
  (with-clean-policy
    (setf (gethash "alexandria" *source-policy*) :ql)
    (ok (eq :ql (source-for "alexandria")))))

(deftest test-source-for-deny-rule
  (with-clean-policy
    (push (list :deny "bad-lib") *source-rules*)
    (ok (eq :deny (source-for "bad-lib")))))

;;; system-denied-p

(deftest test-system-denied-p-no-rules
  (with-clean-policy
    (ok (not (system-denied-p "alexandria")))))

(deftest test-system-denied-p-blanket-deny
  (with-clean-policy
    (push (list :deny "bad-lib") *source-rules*)
    (ok (system-denied-p "bad-lib"))))

(deftest test-system-denied-p-deny-from-not-blanket
  "A :deny with :from is NOT a blanket deny."
  (with-clean-policy
    (push (list :deny "cl-protobufs" :from "ghcr.io") *source-rules*)
    (ok (not (system-denied-p "cl-protobufs")))))

;;; oci-allowed-p / ql-allowed-p

(deftest test-oci-ql-defaults
  (with-clean-policy
    (ok (oci-allowed-p "foo"))
    (ok (ql-allowed-p "foo"))))

(deftest test-oci-blocked-when-ql-only
  (with-clean-policy
    (setf (gethash "foo" *source-policy*) :ql)
    (ok (not (oci-allowed-p "foo")))
    (ok (ql-allowed-p "foo"))))

(deftest test-ql-blocked-when-oci-only
  (with-clean-policy
    (setf (gethash "foo" *source-policy*) :oci)
    (ok (oci-allowed-p "foo"))
    (ok (not (ql-allowed-p "foo")))))

;;; registry-allowed-p

(deftest test-registry-allowed-no-rules
  (with-clean-policy
    (ok (registry-allowed-p "foo" "http://localhost:5050"))))

(deftest test-registry-denied-from-specific
  (with-clean-policy
    (push (list :deny "cl-protobufs" :from "ghcr.io") *source-rules*)
    (ok (not (registry-allowed-p "cl-protobufs" "https://ghcr.io/v2")))
    (ok (registry-allowed-p "cl-protobufs" "http://localhost:5050"))))

(deftest test-registry-allow-from-whitelist
  "When :allow rules exist, only explicitly allowed registries are permitted."
  (with-clean-policy
    (push (list :allow "alexandria" :from "localhost:5050") *source-rules*)
    (ok (registry-allowed-p "alexandria" "http://localhost:5050/v2"))
    (ok (not (registry-allowed-p "alexandria" "https://ghcr.io/v2")))))

(deftest test-registry-allow-multiple-accumulate
  "Multiple :allow rules for same system accumulate."
  (with-clean-policy
    (push (list :allow "alex" :from "localhost:5050") *source-rules*)
    (push (list :allow "alex" :from "ghcr.io") *source-rules*)
    (ok (registry-allowed-p "alex" "http://localhost:5050/v2"))
    (ok (registry-allowed-p "alex" "https://ghcr.io/v2"))
    (ok (not (registry-allowed-p "alex" "https://other.io/v2")))))

(deftest test-registry-match-is-host-based-not-substring
  "A rule host must match the URL host exactly -- not as a substring."
  (with-clean-policy
    (push (list :allow "alexandria" :from "ghcr.io") *source-rules*)
    (ok (registry-allowed-p "alexandria" "https://ghcr.io/v2"))
    (ok (not (registry-allowed-p "alexandria" "https://evil-ghcr.io.attacker.com/v2")))
    (ok (not (registry-allowed-p "alexandria" "https://ghcr.io.attacker.com/v2")))))

(deftest test-registry-match-bare-host-matches-any-port
  (with-clean-policy
    (push (list :allow "alexandria" :from "localhost") *source-rules*)
    (ok (registry-allowed-p "alexandria" "http://localhost:5050"))
    (ok (registry-allowed-p "alexandria" "http://localhost"))
    (ok (not (registry-allowed-p "alexandria" "http://localhost.evil.com:5050")))))

;;; ql-allowed-by-rules-p

(deftest test-ql-allowed-by-rules-no-rules
  (with-clean-policy
    (ok (ql-allowed-by-rules-p "foo"))))

(deftest test-ql-blocked-by-allow-from-non-ql
  "When :allow rules exist for a system but none allow :ql, QL is blocked."
  (with-clean-policy
    (push (list :allow "foo" :from "localhost:5050") *source-rules*)
    (ok (not (ql-allowed-by-rules-p "foo")))))

(deftest test-ql-allowed-by-allow-from-ql
  (with-clean-policy
    (push (list :allow "closer-mop" :from :ql) *source-rules*)
    (ok (ql-allowed-by-rules-p "closer-mop"))))

;;; apply-source-config

(deftest test-apply-source-config
  (with-clean-policy
    (apply-source-config '(:default-source :oci
                           :sources (("foo" :ql) ("bar" :oci))
                           :rules ((:deny "bad"))))
    (ok (eq :oci *default-source*))
    (ok (eq :ql (gethash "foo" *source-policy*)))
    (ok (eq :oci (gethash "bar" *source-policy*)))
    (ok (= 1 (length *source-rules*)))
    (ok (system-denied-p "bad"))))

;;; call-with-policy-overrides

(deftest test-call-with-policy-overrides-restore
  (with-clean-policy
    (call-with-policy-overrides
     '(("foo" :ql)) '("bad") '((:allow "x" :from :ql)) :oci
     (lambda ()
       (ok (eq :oci *default-source*))
       (ok (eq :ql (gethash "foo" *source-policy*)))
       (ok (system-denied-p "bad"))))
    ;; After: should be restored
    (ok (eq :any *default-source*))
    (ok (null (gethash "foo" *source-policy*)))
    (ok (null *source-rules*))))
