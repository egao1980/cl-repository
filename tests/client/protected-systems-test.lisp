(defpackage :cl-repository-client/tests/protected-systems-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/protected-systems
                #:*protected-system-prefixes*
                #:*protect-loaded-systems*
                #:*loaded-systems-snapshot*
                #:snapshot-loaded-systems
                #:ensure-snapshot
                #:implementation-system-p
                #:system-protected-p))
(in-package :cl-repository-client/tests/protected-systems-test)

(deftest normal-system-not-protected
  (testing "Ordinary system names are not protected"
    (let ((*protected-system-prefixes* '("swank" "slynk"))
          (*protect-loaded-systems* nil)
          (*loaded-systems-snapshot* nil))
      (ok (not (system-protected-p "alexandria")))
      (ok (not (system-protected-p "cl-ppcre")))
      (ok (not (system-protected-p "cffi"))))))

(deftest prefix-match-with-package-present
  (testing "Swank is protected when :SWANK package exists"
    (let ((*protected-system-prefixes* '("swank" "slynk"))
          (*protect-loaded-systems* nil)
          (*loaded-systems-snapshot* nil)
          (created nil))
      (unless (find-package :swank)
        (make-package :swank)
        (setf created t))
      (unwind-protect
           (progn
             (ok (system-protected-p "swank"))
             (ok (system-protected-p "swank/sbcl"))
             (ok (system-protected-p "swank/backend")))
        (when created (delete-package :swank))))))

(deftest prefix-match-without-package
  (testing "Swank prefix alone does not protect when package absent"
    (let ((*protected-system-prefixes* '("swank"))
          (*protect-loaded-systems* nil)
          (*loaded-systems-snapshot* nil))
      (unless (find-package :swank)
        (ok (not (system-protected-p "swank")))
        (ok (not (system-protected-p "swank/sbcl")))))))

(deftest slynk-prefix-protection
  (testing "Slynk subsystems are protected when :SLYNK package exists"
    (let ((*protected-system-prefixes* '("swank" "slynk"))
          (*protect-loaded-systems* nil)
          (*loaded-systems-snapshot* nil)
          (created nil))
      (unless (find-package :slynk)
        (make-package :slynk)
        (setf created t))
      (unwind-protect
           (progn
             (ok (system-protected-p "slynk"))
             (ok (system-protected-p "slynk/mrepl")))
        (when created (delete-package :slynk))))))

(deftest custom-prefix-protection
  (testing "User-added prefixes work"
    (let ((*protected-system-prefixes* '("my-server"))
          (*protect-loaded-systems* nil)
          (*loaded-systems-snapshot* nil)
          (created nil))
      (unless (find-package :my-server)
        (make-package :my-server)
        (setf created t))
      (unwind-protect
           (progn
             (ok (system-protected-p "my-server"))
             (ok (system-protected-p "my-server/utils"))
             (ok (not (system-protected-p "my-server-extra"))))
        (when created (delete-package :my-server))))))

(deftest snapshot-protects-loaded-systems
  (testing "Systems present in snapshot are protected"
    (let ((*protected-system-prefixes* nil)
          (*protect-loaded-systems* t)
          (*loaded-systems-snapshot* nil))
      (snapshot-loaded-systems)
      ;; asdf itself is always registered
      (ok (system-protected-p "asdf"))
      ;; Snapshot is a hash-table
      (ok (hash-table-p *loaded-systems-snapshot*)))))

(deftest snapshot-does-not-protect-new-systems
  (testing "Systems NOT in snapshot are not protected"
    (let ((*protected-system-prefixes* nil)
          (*protect-loaded-systems* t)
          (*loaded-systems-snapshot* (make-hash-table :test 'equal)))
      ;; Empty snapshot -- nothing is protected
      (ok (not (system-protected-p "some-new-system")))
      (ok (not (system-protected-p "alexandria"))))))

(deftest ensure-snapshot-lazy
  (testing "ensure-snapshot takes snapshot only once"
    (let ((*protected-system-prefixes* nil)
          (*protect-loaded-systems* t)
          (*loaded-systems-snapshot* nil))
      (ensure-snapshot)
      (let ((first-snapshot *loaded-systems-snapshot*))
        (ok (hash-table-p first-snapshot))
        (ensure-snapshot)
        (ok (eq first-snapshot *loaded-systems-snapshot*) "Same object, not re-taken")))))

(deftest implementation-systems-are-not-registry-packages
  (testing "Host ASDF and SBCL contribs are implementation systems; third-party names are not"
    (ok (implementation-system-p "uiop"))
    (ok (implementation-system-p "asdf"))
    (ok (implementation-system-p "ASDF"))
    (ok (not (implementation-system-p "alexandria")))
    (ok (not (implementation-system-p "acclimation")))
    (ok (not (implementation-system-p "sb-cga")))
    #+sbcl
    (progn
      (ok (implementation-system-p "sb-posix"))
      (ok (implementation-system-p "sb-rotate-byte")))))

(deftest ensure-snapshot-noop-when-disabled
  (testing "ensure-snapshot does nothing when *protect-loaded-systems* is NIL"
    (let ((*protected-system-prefixes* nil)
          (*protect-loaded-systems* nil)
          (*loaded-systems-snapshot* nil))
      (ensure-snapshot)
      (ok (null *loaded-systems-snapshot*)))))
