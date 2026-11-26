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
  (:import-from :cl-oci-client/conditions #:registry-error #:registry-transport-error)
  (:import-from :cl-repository-client/quickload #:ensure-system-installed #:find-system-in-registry)
  (:import-from :cl-repository-client/constraint-builder
                #:system-lookup-error #:system-lookup-error-failures))
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
                   ;; The real installer would make the name findable. A stub that
                   ;; leaves it missing is the "not in the registry" error.
                   (dolist (name systems)
                     (with-open-file (out (merge-pathnames (format nil "~a.asd" name) dir)
                                          :direction :output :if-exists :supersede)
                       (format out "(defsystem ~s :depends-on ())" name))
                     (asdf:clear-system name))
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

(deftest test-list-tags-retry-unreachable-signals
  "#132: an unreachable registry is not an empty one. The transport error
   propagates, it is not NIL."
  (let ((*tag-list-attempts* 2)
        (cl-oci-client/http:*transport-retry* nil)
        (cl-oci-client/http:*host-outcomes* (make-hash-table :test 'equal))
        (reg (make-registry "http://127.0.0.1:9" :insecure-p t)))
    (ok (signals (%call-capturing-log (lambda () (list-tags/retry reg "cl-systems/nope")))
          'registry-transport-error))))

(deftest test-list-tags-retry-transport-error-is-not-retried-again
  (let ((calls 0)
        (*tag-list-attempts* 3)
        (reg (make-registry "http://127.0.0.1:9" :insecure-p t)))
    (ok (signals (%call-capturing-log
                  (lambda ()
                    (list-tags/retry reg "x/y"
                                     :lister (lambda (r p)
                                               (declare (ignore r p))
                                               (incf calls)
                                               (error 'registry-transport-error
                                                      :method :get :url "u")))))
                 'registry-transport-error))
    (ok (= calls 1))))

(deftest test-list-tags-retry-persistent-5xx-signals
  "A 503 on every attempt is a failed lookup: the last error propagates."
  (let ((calls 0)
        (*tag-list-attempts* 2)
        (reg (make-registry "http://127.0.0.1:9" :insecure-p t)))
    (ok (signals (%call-capturing-log
                  (lambda ()
                    (list-tags/retry reg "x/y"
                                     :lister (lambda (r p)
                                               (declare (ignore r p))
                                               (incf calls)
                                               (error 'registry-error :status 503)))))
                 'registry-error))
    (ok (= calls 2))))

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
      (ok (search "package not found in registry" log))
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

(deftest test-collect-missing-defsystem-depends-on-of-a-dependency
  "http-backend-async#44: an installed cl-stack-brotli.asd names asdf-native in
   :defsystem-depends-on, which its published metadata omits. Reading the .asd
   must make asdf-native missing, not abort the install."
  (let* ((dir (uiop:ensure-directory-pathname
               (uiop:ensure-pathname
                (format nil "~a/cl-repo-dsd-~36r/" (uiop:temporary-directory) (random (expt 36 6))))))
         (write-asd (lambda (name text)
                      (with-open-file (out (merge-pathnames (format nil "~a.asd" name) dir)
                                           :direction :output :if-exists :supersede)
                        (write-string text out)))))
    (ensure-directories-exist dir)
    (funcall write-asd "cl-dsd-root" "(defsystem \"cl-dsd-root\" :depends-on (\"cl-dsd-pkg\"))")
    (funcall write-asd "cl-dsd-pkg"
             "(defsystem \"cl-dsd-pkg\" :defsystem-depends-on (\"cl-dsd-definer\") :depends-on ())")
    (push dir asdf:*central-registry*)
    (unwind-protect
         (progn
           (ok (equal '("cl-dsd-definer") (collect-missing-asdf-deps '("cl-dsd-root"))))
           ;; Once the definer is installed, the next pass reads the package.
           (funcall write-asd "cl-dsd-definer" "(defsystem \"cl-dsd-definer\")")
           (asdf:clear-system "cl-dsd-pkg")
           ;; fresh ASDF session: test-op's caches the missing definer
           (ok (null (let ((asdf/session:*asdf-session* nil))
                       (collect-missing-asdf-deps '("cl-dsd-root"))))))
      (setf asdf:*central-registry* (remove dir asdf:*central-registry* :test #'equal))
      (dolist (s '("cl-dsd-root" "cl-dsd-pkg" "cl-dsd-definer"))
        (asdf:clear-system s))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest test-installed-but-too-old-is-resolved-again
  "lisp-mcp needs mcp-protocol 0.3.0; an installed 0.2.0 counted as \"already
   available via ASDF\", nothing was installed, and sync ended with \"system
   mcp-protocol is not in the registry\"."
  (let* ((dir (uiop:ensure-directory-pathname
               (format nil "~a/cl-repo-min-~36r/" (uiop:temporary-directory) (random (expt 36 6)))))
         (sym 'cl-repository-client/constraint-builder:build-install-plan)
         (orig (fdefinition sym))
         (calls '()))
    (ensure-directories-exist dir)
    (with-open-file (out (merge-pathnames "cl-min-demo.asd" dir) :direction :output :if-exists :supersede)
      (write-string "(defsystem \"cl-min-demo\" :version \"0.2.0\")" out))
    (push dir asdf:*central-registry*)
    (unwind-protect
         (progn
           (setf (fdefinition sym)
                 (lambda (name version registries &key force)
                   (declare (ignore registries force))
                   (push name calls)
                   (values (list (cons name (if (eq version :latest) "0.3.0" version))) nil)))
           (let ((*standard-output* (make-broadcast-stream))
                 (asdf/session:*asdf-session* nil))
             (ok (null (cl-repository-client/quickload::%resolve-one-into-plan
                        "cl-min-demo" nil nil :minimum "0.1.0"))
                 "new enough: kept")
             ;; the SAT plan pins installed versions: an empty plan for a
             ;; stale install still plans the package itself
             (let ((stub (fdefinition sym)))
               (setf (fdefinition sym) (lambda (&rest args) (declare (ignore args)) (values nil nil)))
               (ok (equal '(("cl-min-demo"))
                          (cl-repository-client/quickload::%resolve-one-into-plan
                           "cl-min-demo" nil nil :minimum "0.3.0"))
                   "planned although the SAT plan pinned the install")
               (setf (fdefinition sym) stub))
             (ok (equal '(("cl-min-demo" . "0.3.0"))
                        (cl-repository-client/quickload::%resolve-one-into-plan
                         "cl-min-demo" nil nil :minimum "0.3.0"))
                 "too old: resolved from the registry")
             (ok (equal '("cl-min-demo") calls))
             (ok (equal '(("cl-min-demo" . "0.3.1"))
                        (cl-repository-client/quickload::%resolve-one-into-plan
                         "cl-min-demo" "0.3.1" nil))
                 "an exact version other than the installed one is resolved")
             (ok (null (cl-repository-client/quickload::%resolve-one-into-plan
                        "cl-min-demo" "0.2.0" nil))
                 "the installed exact version is kept")))
      (setf (fdefinition sym) orig)
      (setf asdf:*central-registry* (remove dir asdf:*central-registry*))
      (asdf:clear-system "cl-min-demo")
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest test-secondary-below-minimum-resolves-its-package
  "ai-agent-protocol/tests needs conversation-protocol/summary 0.4.0. An
   installed conversation-protocol 0.3.0 counted as \"provided by installed\",
   nothing was installed, and sync ended with \"system
   conversation-protocol/summary is not in the registry\"."
  (let* ((dir (uiop:ensure-directory-pathname
               (format nil "~a/cl-repo-sec-~36r/" (uiop:temporary-directory) (random (expt 36 6)))))
         (sym 'cl-repository-client/constraint-builder:build-install-plan)
         (orig (fdefinition sym))
         (calls '()))
    (ensure-directories-exist dir)
    (with-open-file (out (merge-pathnames "cl-sec-demo.asd" dir) :direction :output
                                                                 :if-exists :supersede)
      (write-string "(defsystem \"cl-sec-demo\" :version \"0.3.0\")
(defsystem \"cl-sec-demo/sub\" :version \"0.3.0\")" out))
    (push dir asdf:*central-registry*)
    (unwind-protect
         (progn
           (setf (fdefinition sym)
                 (lambda (name version registries &key force)
                   (declare (ignore registries force))
                   (push name calls)
                   (values (list (cons name (if (eq version :latest) "0.4.0" version))) nil)))
           (let ((*standard-output* (make-broadcast-stream))
                 (asdf/session:*asdf-session* nil))
             (ok (null (cl-repository-client/quickload::%resolve-one-into-plan
                        "cl-sec-demo/sub" nil nil))
                 "no minimum: provided by the installed package")
             (ok (null (cl-repository-client/quickload::%resolve-one-into-plan
                        "cl-sec-demo/sub" nil nil :minimum "0.2.0"))
                 "new enough: kept")
             (ok (null calls))
             (ok (equal '(("cl-sec-demo" . "0.4.0"))
                        (cl-repository-client/quickload::%resolve-one-into-plan
                         "cl-sec-demo/sub" nil nil :minimum "0.4.0"))
                 "too old: its package is resolved from the registry")
             (ok (equal '("cl-sec-demo") calls))))
      (setf (fdefinition sym) orig)
      (setf asdf:*central-registry* (remove dir asdf:*central-registry*))
      (asdf:clear-system "cl-sec-demo/sub")
      (asdf:clear-system "cl-sec-demo")
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest installed-version-is-the-newest-not-the-last-in-path-order
  (let* ((root (uiop:ensure-directory-pathname
                (format nil "~a/cl-repo-iv-~36r/" (uiop:temporary-directory) (random (expt 36 6)))))
         (cl-repository-client/installer::*systems-root* root))
    (dolist (v '("0.9.0" "0.10.0" "0.2.1"))
      (ensure-directories-exist (merge-pathnames (format nil "cl-iv-demo/~a/" v) root)))
    (unwind-protect
         (ok (equal "0.10.0" (cl-repository-client/quickload:installed-system-version "cl-iv-demo")))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(deftest test-op-delegates-follow-in-order-to
  "A test-op that delegates to a system not named <name>/tests (http2 →
   http2/test → http2/test-samples) has its test systems walked too: their
   dependencies (fiasco) were never installed."
  (unwind-protect
       (progn
         (eval '(asdf:defsystem "cl-repo-deleg" :in-order-to ((asdf:test-op (asdf:test-op "cl-repo-deleg/test") (asdf:load-op "cl-repo-deleg")))))
         (eval '(asdf:defsystem "cl-repo-deleg/test" :in-order-to ((asdf:test-op (asdf:test-op "cl-repo-deleg/samples")))))
         (eval '(asdf:defsystem "cl-repo-deleg/samples"))
         (ok (equal '("cl-repo-deleg/test" "cl-repo-deleg/samples")
                    (cl-repository-client/quickload::test-op-delegates "cl-repo-deleg")))
         (ok (null (cl-repository-client/quickload::test-op-delegates "cl-repo-deleg/samples"))))
    (dolist (s '("cl-repo-deleg/samples" "cl-repo-deleg/test" "cl-repo-deleg"))
      (asdf:clear-system s))))

(deftest scan-installed-systems-takes-the-preferred-version
  "With 0.2.0 and 0.2.4 installed, the scan reports 0.2.4 (what ASDF loads),
   not the first directory listed: cl-repo lock pinned the oldest."
  (let* ((root (uiop:ensure-directory-pathname
                (merge-pathnames (format nil "cl-repo-scan-~D/" (random 1000000 (make-random-state t)))
                                 (uiop:temporary-directory))))
         (cl-repository-client/installer::*systems-root* root))
    (unwind-protect
         (progn
           (dolist (v '("0.2.0" "0.2.4" "0.2.10"))
             (ensure-directories-exist (merge-pathnames (format nil "demo-sys/~a/" v) root)))
           (ok (equal '(("demo-sys" . "0.2.10"))
                      (cl-repository-client/constraint-builder:scan-installed-systems)))
           (ok (= 3 (length (cl-repository-client/constraint-builder:installed-versions "demo-sys")))))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(deftest loaded-copy-below-minimum-is-satisfied-by-an-installed-newer-one
  "A system loaded in the client image (event-protocol 0.2.1 under the async
   backend) below a project's (:version ... \"0.2.2\") stays loaded; 0.2.2 is
   installed beside it. The walk counts that as satisfied (it asked again and
   failed: not in the registry), and protection does not stop the install."
  (let* ((root (uiop:ensure-directory-pathname
                (format nil "~a/cl-repo-lc-~36r/" (uiop:temporary-directory) (random (expt 36 6)))))
         (cl-repository-client/installer::*systems-root* root))
    (unwind-protect
         (progn
           (eval '(asdf:defsystem "cl-repo-lc-demo" :version "0.2.1"))
           (asdf:load-system "cl-repo-lc-demo")
           (ok (not (cl-repository-client/quickload::loaded-copy-satisfied-p
                     "cl-repo-lc-demo" "0.2.2"))
               "nothing new enough installed")
           (ensure-directories-exist (merge-pathnames "cl-repo-lc-demo/0.2.2/" root))
           (ok (cl-repository-client/quickload::loaded-copy-satisfied-p
                "cl-repo-lc-demo" "0.2.2"))
           (ok (cl-repository-client/quickload::satisfied-or-definer
                "cl-repo-lc-demo" "0.2.2"))
           (ok (not (cl-repository-client/quickload::loaded-copy-satisfied-p
                     "cl-repo-lc-demo" "0.3.0"))))
      (asdf:clear-system "cl-repo-lc-demo")
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(deftest issue-196-a-locked-copy-below-a-floor-gives-way-to-the-installed-one
  "cl-repository#196: the client image runs http-protocol (quri), the stale
   cl-repo.lock holds 0.4.4, and a package the re-resolve installs needs
   (:version \"http-protocol\" \"0.4.5\"), which is installed too. The walk
   counted the loaded copy plus the installed 0.4.5 as satisfied, but the
   registry still preferred the locked 0.4.4: the lock was rewritten with it
   and the fresh image's ASDF refused to load. Satisfied now means the copy
   the registry gives a fresh image is at the floor, and the lock follows.
   The loaded copy is pinned, as in a sync (WITH-LOADED-SYSTEMS-PINNED)."
  (let* ((tmp (uiop:ensure-directory-pathname
               (format nil "~a/cl-repo-196-~36r/" (uiop:temporary-directory)
                       (random (expt 36 6) (make-random-state t)))))
         (root (merge-pathnames "systems/" tmp))
         (client (merge-pathnames "client/" tmp))
         (name "cl-repo-lf-demo")
         (saved asdf/source-registry:*source-registry-parameter*)
         (cl-repository-client/installer::*systems-root* root)
         (cl-repository-client/asdf-integration:*locked-versions* (list (cons name "0.4.4"))))
    (flet ((write-asd (dir version)
             (ensure-directories-exist dir)
             (with-open-file (o (merge-pathnames (format nil "~a.asd" name) dir)
                                :direction :output :if-exists :supersede)
               (format o "(defsystem ~s :version ~s)~%" name version)))
           (fresh-image-version ()
             (cl-repository-client/dep-satisfy:registry-copy-version
              name (asdf:registered-system name))))
      (write-asd (merge-pathnames "cl-repo-lf-demo/0.4.4/" root) "0.4.4")
      (write-asd (merge-pathnames "cl-repo-lf-demo/0.4.5/" root) "0.4.5")
      (write-asd client "0.4.5")
      (unwind-protect
          (progn
            (let ((*standard-output* (make-broadcast-stream)))
              (asdf:load-asd (merge-pathnames "cl-repo-lf-demo.asd" client))
              (asdf:load-system name))
            (cl-oci-client/pin:with-loaded-systems-pinned (:warn-shadowing nil)
              (asdf:initialize-source-registry
               `(:source-registry
                 ,@(cl-repository-client/asdf-integration:preferred-install-trees
                    root cl-repository-client/asdf-integration:*locked-versions*)
                 (:tree ,(namestring root))
                 :ignore-inherited-configuration))
              (ok (equal "0.4.4" (fresh-image-version)) "the lock pins 0.4.4 at first")
              (ok (cl-repository-client/quickload::satisfied-or-definer name "0.4.5")
                  "satisfied: 0.4.5 is installed")
              (ok (equal "0.4.5" (fresh-image-version)) "a fresh image now gets 0.4.5")
              (ok (equal "0.4.5" (cdr (assoc name cl-repository-client/asdf-integration:*locked-versions*
                                             :test #'string=)))
                  "the lock written next holds 0.4.5")
              (ok (not (cl-repository-client/quickload::satisfied-or-definer name "0.5.0"))
                  "nothing installed at 0.5.0: not satisfied")))
        (asdf:clear-system name)
        (if saved (asdf:initialize-source-registry saved) (asdf:clear-source-registry))
        (uiop:delete-directory-tree tmp :validate t :if-does-not-exist :ignore)))))

(deftest test-collect-missing-takes-the-strongest-minimum
  "cl-repository#100: ai-agent-protocol needs conversation-protocol 0.3.0, its
   /tests 0.4.0. The walk checked the first (:version ...) it met, found the
   cached 0.3.0 new enough, and never looked at the test system's 0.4.0: sync
   fetched nothing and the test load failed. The same holds for :with extras."
  (let* ((dir (uiop:ensure-directory-pathname
               (format nil "~a/cl-repo-tmin-~36r/" (uiop:temporary-directory) (random (expt 36 6)))))
         (write-asd (lambda (name text)
                      (with-open-file (out (merge-pathnames (format nil "~a.asd" name) dir)
                                           :direction :output :if-exists :supersede)
                        (write-string text out)))))
    (ensure-directories-exist dir)
    (funcall write-asd "cl-tmin-dep" "(defsystem \"cl-tmin-dep\" :version \"0.3.0\")")
    (funcall write-asd "cl-tmin-main"
             "(defsystem \"cl-tmin-main\" :depends-on ((:version \"cl-tmin-dep\" \"0.3.0\")))
(defsystem \"cl-tmin-main/tests\"
  :depends-on (\"cl-tmin-main\" (:version \"cl-tmin-dep\" \"0.4.0\")))")
    (funcall write-asd "cl-tmin-extra"
             "(defsystem \"cl-tmin-extra\" :depends-on ((:version \"cl-tmin-dep\" \"0.5.0\")))")
    (push dir asdf:*central-registry*)
    (unwind-protect
         (let ((asdf/session:*asdf-session* nil))
           ;; ENSURE-SYSTEM-DEPENDENCIES puts the test system first
           (dolist (roots '(("cl-tmin-main/tests" "cl-tmin-main")
                            ("cl-tmin-main" "cl-tmin-main/tests")))
             (multiple-value-bind (missing minimums) (collect-missing-asdf-deps roots)
               (ok (equal '("cl-tmin-dep") missing) (format nil "~s: too old for /tests" roots))
               (ok (equal "0.4.0" (cdr (assoc "cl-tmin-dep" minimums :test #'string=))))))
           (ok (null (collect-missing-asdf-deps '("cl-tmin-main")))
               "the main system alone is satisfied by 0.3.0")
           (multiple-value-bind (missing minimums)
               (collect-missing-asdf-deps '("cl-tmin-main") '("cl-tmin-extra"))
             (ok (equal '("cl-tmin-dep") missing) ":with extra asks for more")
             (ok (equal "0.5.0" (cdr (assoc "cl-tmin-dep" minimums :test #'string=))))))
      (setf asdf:*central-registry* (remove dir asdf:*central-registry* :test #'equal))
      (dolist (s '("cl-tmin-main/tests" "cl-tmin-main" "cl-tmin-dep" "cl-tmin-extra"))
        (asdf:clear-system s))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest test-loaded-dependency-installed-mid-walk-stays-satisfied
  "#115: the image runs cl-ld-demo 0.1.0 and the project needs 0.2.0. The walk
   installs 0.2.0, then cleared the loaded system, so the next pass saw only
   the old copy and failed with \"system cl-ld-demo is not in the registry\"."
  (let* ((dir (uiop:ensure-directory-pathname
               (format nil "~a/cl-repo-ld-~36r/" (uiop:temporary-directory) (random (expt 36 6)))))
         (root (merge-pathnames "systems/" dir))
         (sym 'cl-repository-client/quickload::ensure-systems)
         (orig (fdefinition sym))
         (installs '()))
    (ensure-directories-exist root)
    (with-open-file (out (merge-pathnames "cl-ld-demo.asd" dir) :direction :output :if-exists :supersede)
      (write-string "(defsystem \"cl-ld-demo\" :version \"0.1.0\")" out))
    (with-open-file (out (merge-pathnames "cl-ld-root.asd" dir) :direction :output :if-exists :supersede)
      (write-string "(defsystem \"cl-ld-root\" :depends-on ((:version \"cl-ld-demo\" \"0.2.0\")))" out))
    (push dir asdf:*central-registry*)
    (unwind-protect
         (let ((*standard-output* (make-broadcast-stream))
               (cl-repository-client/installer::*systems-root* root))
           (asdf:load-system "cl-ld-demo")
           (setf (fdefinition sym)
                 (lambda (systems &rest keys)
                   (declare (ignore keys))
                   (dolist (s systems)
                     (push s installs)
                     (ensure-directories-exist (merge-pathnames (format nil "~a/0.2.0/" s) root)))))
           (ok (null (handler-case
                         (progn (cl-repository-client/quickload:ensure-system-dependencies
                                 "cl-ld-root" :also-tests nil)
                                nil)
                       (error (e) (princ-to-string e))))
               "no \"not in the registry\" after installing a loaded system")
           (ok (equal '("cl-ld-demo") installs) "installed once")
           (ok (asdf:component-loaded-p "cl-ld-demo") "the running copy stays registered"))
      (setf (fdefinition sym) orig)
      (setf asdf:*central-registry* (remove dir asdf:*central-registry* :test #'equal))
      (dolist (s '("cl-ld-root" "cl-ld-demo"))
        (asdf:clear-system s))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest test-newer-installed-copy-contributes-its-new-dependencies
  "#129: the image runs cl-nd-demo 0.1.0 (no deps); the project needs 0.2.0,
   which depends on cl-nd-new. ASDF answers for cl-nd-demo with the loaded
   copy, so the walk read 0.1.0's :depends-on and never installed cl-nd-new;
   the fresh test image then failed: component cl-nd-new not found."
  (let* ((dir (uiop:ensure-directory-pathname
               (format nil "~a/cl-repo-nd-~36r/" (uiop:temporary-directory) (random (expt 36 6)))))
         (root (merge-pathnames "systems/" dir))
         (sym 'cl-repository-client/quickload::ensure-systems)
         (orig (fdefinition sym))
         (installs '())
         (write-file (lambda (path text)
                       (ensure-directories-exist path)
                       (with-open-file (out path :direction :output :if-exists :supersede)
                         (write-string text out)))))
    (funcall write-file (merge-pathnames "cl-nd-demo.asd" dir)
             "(defsystem \"cl-nd-demo\" :version \"0.1.0\")")
    (funcall write-file (merge-pathnames "cl-nd-root.asd" dir)
             "(defsystem \"cl-nd-root\" :depends-on ((:version \"cl-nd-demo\" \"0.2.0\")))")
    (push dir asdf:*central-registry*)
    (unwind-protect
         (let ((*standard-output* (make-broadcast-stream))
               (cl-repository-client/installer::*systems-root* root))
           (asdf:load-system "cl-nd-demo")
           (setf (fdefinition sym)
                 (lambda (systems &rest keys)
                   (declare (ignore keys))
                   (dolist (s systems)
                     (push s installs)
                     (cond
                       ((string= s "cl-nd-demo")
                        (funcall write-file (merge-pathnames "cl-nd-demo/0.2.0/cl-nd-demo.asd" root)
                                 "(in-package :asdf-user)
(defsystem \"cl-nd-demo\" :version \"0.2.0\"
  :depends-on (\"cl-nd-new\" (:feature :cl-nd-never \"cl-nd-off\")))"))
                       (t
                        (funcall write-file (merge-pathnames (format nil "~a.asd" s) dir)
                                 (format nil "(defsystem ~s :version \"0.1.0\")" s)))))))
           (ok (null (handler-case
                         (progn (cl-repository-client/quickload:ensure-system-dependencies
                                 "cl-nd-root" :also-tests nil)
                                nil)
                       (error (e) (princ-to-string e)))))
           (ok (equal '("cl-nd-new" "cl-nd-demo") installs)
               "the installed 0.2.0's dependency is installed too")
           (ok (asdf:component-loaded-p "cl-nd-demo") "the running copy stays registered"))
      (setf (fdefinition sym) orig)
      (setf asdf:*central-registry* (remove dir asdf:*central-registry* :test #'equal))
      (dolist (s '("cl-nd-root" "cl-nd-demo" "cl-nd-new"))
        (asdf:clear-system s))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest client-copy-does-not-satisfy-what-the-registry-gives-older
  "#119: this image runs cl-rc-demo 0.2.0 from its own tree (the client's
   CL_REPOSITORY_DEST); the registry puts an installed 0.1.0 first. A fresh
   `cl-repo run` / `cl-repo test` image gets 0.1.0, so a (:version ... \"0.2.0\")
   is not satisfied until 0.2.0 is installed."
  (let* ((dir (uiop:ensure-directory-pathname
               (format nil "~a/cl-repo-rc-~36r/" (uiop:temporary-directory) (random (expt 36 6)))))
         (own (merge-pathnames "own/" dir))
         (systems (merge-pathnames "systems/" dir))
         (saved asdf/source-registry:*source-registry-parameter*)
         (write-file (lambda (path version)
                       (ensure-directories-exist path)
                       (with-open-file (out path :direction :output :if-exists :supersede)
                         (format out "(defsystem \"cl-rc-demo\" :version ~s)" version))))
         (use-registry (lambda (&rest trees)
                         (asdf:initialize-source-registry
                          `(:source-registry ,@(mapcar (lambda (d) (list :tree (namestring d))) trees)
                                             :ignore-inherited-configuration)))))
    (funcall write-file (merge-pathnames "cl-rc-demo.asd" own) "0.2.0")
    (funcall write-file (merge-pathnames "cl-rc-demo/0.1.0/cl-rc-demo.asd" systems) "0.1.0")
    (unwind-protect
         (progn
           (funcall use-registry own)
           (let ((*standard-output* (make-broadcast-stream)))
             (asdf:load-system "cl-rc-demo"))
           (funcall use-registry (merge-pathnames "cl-rc-demo/0.1.0/" systems) systems own)
           (let ((cl-oci-client/pin::*pinned* nil))
             (cl-oci-client/pin:with-loaded-systems-pinned ()
               (ok (equal "0.2.0" (asdf:component-version (asdf:find-system "cl-rc-demo")))
                   "this image answers with its own copy")
               (ng (cl-repository-client/dep-satisfy:system-satisfied-p "cl-rc-demo" "0.2.0")
                   "the registry's 0.1.0 is what a fresh image gets")
               (ng (cl-repository-client/quickload::satisfied-or-definer "cl-rc-demo" "0.2.0"))
               (ok (cl-repository-client/dep-satisfy:system-satisfied-p "cl-rc-demo" "0.1.0"))
               (ok (cl-repository-client/dep-satisfy:system-satisfied-p "cl-rc-demo"))))
           (funcall write-file (merge-pathnames "cl-rc-demo/0.2.0/cl-rc-demo.asd" systems) "0.2.0")
           (funcall use-registry (merge-pathnames "cl-rc-demo/0.2.0/" systems) systems own)
           (let ((cl-oci-client/pin::*pinned* nil))
             (cl-oci-client/pin:with-loaded-systems-pinned ()
               (ok (cl-repository-client/dep-satisfy:system-satisfied-p "cl-rc-demo" "0.2.0")
                   "satisfied once 0.2.0 is installed"))))
      (asdf:clear-system "cl-rc-demo")
      (asdf:initialize-source-registry saved)
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))
;;; #120 / #132: a registry that fails to answer is not one without the package.
;;; A fake transport (an http-protocol backend scripted per URL) stands in for
;;; ghcr.io.

(defclass %scripted-registry (http-protocol:http-backend)
  ((routes :initarg :routes :reader %routes)
   (calls :initform 0 :accessor %calls))
  (:default-initargs :name "scripted-registry"))

(defmethod http-protocol:send ((backend %scripted-registry) client request &key)
  (declare (ignore client))
  (incf (%calls backend))
  (let ((url (http-protocol:http-request-url request)))
    (loop for (suffix . action) in (%routes backend)
          when (search suffix url)
            do (return-from http-protocol:send (funcall action)))
    (%respond 404 "{\"errors\":[{\"code\":\"NAME_UNKNOWN\"}]}")))

(defun %respond (status body)
  (let ((headers (make-hash-table :test #'equal)))
    (setf (gethash "content-type" headers) "application/json")
    (make-instance 'http-protocol:http-response
                   :status status :headers headers
                   :body (babel:string-to-octets body :encoding :utf-8))))

(defun %incomplete ()
  (error 'http-protocol:http-protocol-error :message "incomplete HTTP response"))

(defun %with-scripted-registry (routes fn)
  "Call FN with *REGISTRIES* naming one fake registry that answers ROUTES,
   ((url-substring . thunk) ...); other URLs get a 404. No host has answered
   yet (*HOST-OUTCOMES*). FN gets the backend."
  (let* ((backend (make-instance '%scripted-registry :routes routes))
         (http-protocol:*http-backend* backend)
         (cl-oci-client/http::*http-clients* '())
         (cl-oci-client/http:*host-outcomes* (make-hash-table :test 'equal))
         (cl-oci-client/http:*transport-retry*
          (make-instance 'cl-oci-client/http::transport-retry
                         :total 2 :backoff-factor 0 :status nil
                         :allowed-methods '(:get :head)))
         (*tag-list-attempts* 1)
         (cl-repository-client/quickload::*registries*
          '(("https://r.test" :namespace "ns"))))
    (funcall fn backend)))

(deftest test-blob-pull-transport-failure-is-not-not-found
  "#120: the tag listing works, the manifest pull keeps getting an incomplete
   response. Each pull is retried; then the error says the pull failed and
   why, not that the system is not in the registry."
  (%with-scripted-registry
   (list (cons "/tags/list" (lambda () (%respond 200 "{\"name\":\"ns/fakesys\",\"tags\":[\"0.2.2\"]}")))
         (cons "/manifests/0.2.2" #'%incomplete))
   (lambda (backend)
     (let ((e nil) (log nil))
       (setf log (nth-value 1 (%call-capturing-log
                               (lambda ()
                                 (handler-case (ensure-system-installed "fakesys")
                                   (system-lookup-error (c) (setf e c)))))))
       (ok e)
       (ok (= 1 (length (system-lookup-error-failures e))))
       (ok (typep (cdr (first (system-lookup-error-failures e))) 'registry-transport-error))
       ;; one tag listing + three manifest attempts
       (ok (= 4 (%calls backend)))
       (let ((report (princ-to-string e)))
         (ok (search "incomplete HTTP response" report))
         (ok (search "pulling fakesys from https://r.test failed" report))
         (ng (search "not in" report)))
       (ok (search "pulling fakesys from https://r.test failed" log))))))

(deftest test-tag-listing-timeout-is-not-not-found
  "#132: a timed-out lookup signals from FIND-SYSTEM-IN-REGISTRY (NIL there
   means \"not in the registry\") and ENSURE-SYSTEM-INSTALLED reports it."
  (%with-scripted-registry
   (list (cons "/tags/list"
               (lambda () (error 'http-protocol:http-timeout-error :message "sync await timed out"))))
   (lambda (backend)
     (declare (ignore backend))
     (ok (signals (find-system-in-registry "https://r.test" "ns" "fakesys")
                  'registry-transport-error))
     (let ((e (handler-case (progn (%call-capturing-log
                                    (lambda () (ensure-system-installed "fakesys")))
                                   nil)
                (system-lookup-error (c) c))))
       (ok e)
       (ok (search "sync await timed out" (princ-to-string e)))))))

(deftest test-a-404-still-means-not-found
  "The registry answers 404 for the tag listing and the anchor: NAME is not
   there. ENSURE-SYSTEM-INSTALLED returns NIL without signalling."
  (%with-scripted-registry
   '()
   (lambda (backend)
     (declare (ignore backend))
     (ok (null (find-system-in-registry "https://r.test" "ns" "fakesys")))
     (ok (null (%call-capturing-log (lambda () (ensure-system-installed "fakesys"))))))))

(deftest test-a-token-endpoint-403-means-not-found
  "#131: ghcr answers 403 at the token endpoint for a repository it lacks.
   That is \"package not found in registry\", printed as text."
  (%with-scripted-registry
   (list (cons "/tags/list"
               (lambda ()
                 (let ((r (%respond 401 "{}")))
                   (setf (gethash "www-authenticate" (http-protocol:response-headers r))
                         "Bearer realm=\"https://r.test/token\",service=\"r.test\",scope=\"repository:ns/fakesys:pull\"")
                   r)))
         (cons "/token"
               (lambda ()
                 (%respond 403 "{\"errors\":[{\"code\":\"DENIED\",\"message\":\"requested access to the resource is denied\"}]}"))))
   (lambda (backend)
     (declare (ignore backend))
     (multiple-value-bind (result log)
         (%call-capturing-log
          (lambda () (find-system-in-registry "https://r.test" "ns" "fakesys" :type :ocicl)))
       (ok (null result))
       (ok (search "package not found in registry" log))
       (ok (search "DENIED: requested access to the resource is denied" log))
       (ng (search "#(" log))))))

(deftest test-minimum-applies-to-the-requested-system-only
  "ensure-systems http149 :minimum 0.1.1 with a plan that upgrades an
   installed x149 0.3.0 to 0.4.0: x149 is installed at 0.4.0. The root's
   minimum made 0.3.0 \"new enough\" and the upgrade was skipped (#149)."
  (let* ((root (uiop:ensure-directory-pathname
                (format nil "~a/cl-repo-min149-~36r/" (uiop:temporary-directory)
                        (random (expt 36 8) (make-random-state t)))))
         (plan-sym 'cl-repository-client/quickload::compute-install-plan)
         (install-sym 'cl-repository-client/quickload::ensure-system-installed)
         (orig-plan (fdefinition plan-sym))
         (orig-install (fdefinition install-sym))
         (installs '()))
    (ensure-directories-exist (merge-pathnames "x149/0.3.0/" root))
    (unwind-protect
         (let ((cl-repository-client/installer::*systems-root* root)
               (*standard-output* (make-broadcast-stream)))
           (setf (fdefinition plan-sym)
                 (lambda (&rest args)
                   (declare (ignore args))
                   (list (cons "x149" "0.4.0") (cons "http149" "0.1.1"))))
           (setf (fdefinition install-sym)
                 (lambda (name &key version minimum)
                   (push (list name version minimum) installs)
                   nil))
           (cl-repository-client/quickload:ensure-systems '("http149") :minimum "0.1.1")
           (ok (member '("x149" "0.4.0" nil) installs :test #'equal)
               "the upgrade is installed at the planned version")
           (ok (member '("http149" nil "0.1.1") installs :test #'equal)
               "the requested system keeps its minimum"))
      (setf (fdefinition plan-sym) orig-plan
            (fdefinition install-sym) orig-install)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))
