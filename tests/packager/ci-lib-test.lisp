(defpackage :cl-repository-packager/tests/ci-lib-test
  (:use :cl :rove))
(in-package :cl-repository-packager/tests/ci-lib-test)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (load (merge-pathnames ".github/actions/ci/ci-lib.lisp"
                         (uiop:pathname-directory-pathname
                          (asdf:system-source-file "cl-repository-packager")))))

(defun make-temp-dir ()
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "cl-repo-ci-lib-~a/" (get-universal-time))
                               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    dir))

(defun write-asd (dir filename &key systems (extra ""))
  (let ((path (merge-pathnames filename dir)))
    (with-open-file (s path :direction :output :if-exists :supersede)
      (dolist (name systems)
        (format s "(defsystem ~s ~a :components ((:file \"m\")))~%" name extra)))
    path))

(deftest discover-skips-tests-and-slash-names
  (let ((dir (make-temp-dir)))
    (unwind-protect
         (progn
           (write-asd dir "http-protocol.asd"
                      :systems '("http-protocol" "http-protocol/tests" "http-protocol/conformance"))
           (let ((names (cl-repository-ci-lib:discover-primary-systems dir)))
             (ok (equal names '("http-protocol")))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest discover-prefers-directory-name
  (let ((dir (make-temp-dir)))
    (unwind-protect
         (progn
           (write-asd dir "foo.asd" :systems '("foo"))
           (write-asd dir "bar.asd" :systems '("bar"))
           (let* ((subdir (merge-pathnames "foo/" dir)))
             (ensure-directories-exist subdir)
             (write-asd subdir "foo.asd" :systems '("foo"))
             (write-asd subdir "bar.asd" :systems '("bar"))
             (ok (string= (cl-repository-ci-lib:discover-primary-system subdir) "foo"))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest discover-errors-when-empty
  (let ((dir (make-temp-dir)))
    (unwind-protect
         (ok (signals (cl-repository-ci-lib:discover-primary-system dir)))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest ci-plist-from-asd
  (let ((dir (make-temp-dir)))
    (unwind-protect
         (progn
           (write-asd dir "ci-demo.asd"
                      :systems '("ci-demo")
                      :extra ":properties (:cl-repo (:ci (:with (\"dissect\") :sources ((\"rove\" :ql)) :also-tests t)))")
           (with-open-file (s (merge-pathnames "m.lisp" dir) :direction :output :if-exists :supersede)
             (format s "(defpackage :ci-demo (:use :cl))~%"))
           (asdf:initialize-source-registry
            `(:source-registry (:directory ,(namestring dir)) :inherit-configuration))
           (asdf:clear-system "ci-demo")
           (let* ((ci (cl-repository-ci-lib:system-ci-plist "ci-demo"))
                  (with (cl-repository-ci-lib:ci-with ci '("extra")))
                  (sources (cl-repository-ci-lib:ci-sources ci)))
             (ok (cl-repository-ci-lib:ci-also-tests ci))
             (ok (member "dissect" with :test #'string=))
             (ok (member "extra" with :test #'string=))
             (ok (equal (first sources) '("rove" :ql)))))
      (asdf:clear-system "ci-demo")
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest ci-defaults-when-absent
  (ok (eq (cl-repository-ci-lib:ci-also-tests nil) t))
  (ok (null (cl-repository-ci-lib:ci-with nil)))
  (ok (null (cl-repository-ci-lib:ci-sources nil)))
  (ok (null (cl-repository-ci-lib:ci-load-before-test nil)))
  (ok (null (cl-repository-ci-lib:ci-record-versions nil))))

(deftest split-ws-and-hooks
  (ok (equal (cl-repository-ci-lib:split-ws "dissect cl-stack-ssl")
             '("dissect" "cl-stack-ssl")))
  (ok (equal (cl-repository-ci-lib:split-ws "a, b") '("a" "b")))
  (let ((cl-repository-ci-lib::*extra-with* '("hooked")))
    (ok (member "hooked" (cl-repository-ci-lib:ci-with nil) :test #'string=))))

(deftest discover-asd-system-names-includes-tests
  (let ((dir (make-temp-dir)))
    (unwind-protect
         (progn
           (write-asd dir "http-encoding-chipz.asd"
                      :systems '("http-encoding-chipz" "http-encoding-chipz/tests"))
           (let ((names (cl-repository-ci-lib:discover-asd-system-names dir)))
             (ok (equal names '("http-encoding-chipz" "http-encoding-chipz/tests")))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest run.lisp-unshadows-checkout-before-client-load
  "Client load uses the OCI dest as a list registry, not a CL_SOURCE_REGISTRY string."
  (let* ((root (uiop:pathname-directory-pathname
                (asdf:system-source-file "cl-repository-packager")))
         (text (uiop:read-file-string (merge-pathnames ".github/actions/ci/run.lisp" root))))
    (ok (search "%load-client" text))
    (ok (search "CL_REPOSITORY_DEST" text))
    (ok (search ":ignore-inherited-configuration" text))
    (ok (search "clear-checkout-systems" text))
    (ok (not (search "client-bootstrap-registry" text)))))

(deftest run.lisp-readable-before-packager
  "ros -l run.lisp reads the whole file before %ensure-packager. Package-qualified
   packager/oci-client symbols blow up install+test (schema-protocol canary)."
  (let* ((root (uiop:pathname-directory-pathname
                (asdf:system-source-file "cl-repository-packager")))
         (text (uiop:read-file-string (merge-pathnames ".github/actions/ci/run.lisp" root))))
    (dolist (pkg '("cl-repository-packager/asdf-plugin:"
                   "cl-repository-packager/build-matrix:"
                   "cl-repository-packager/publisher:"
                   "cl-oci-client/auth:"
                   "cl-oci-client/registry:"))
      (ok (not (search pkg text)) pkg))))

(deftest publish.lisp-keeps-auto-package-spec-provides
  "Do not wipe :provides to (list system) — slash secondaries must stay annotated."
  (let* ((root (uiop:pathname-directory-pathname
                (asdf:system-source-file "cl-repository-packager")))
         (text (uiop:read-file-string (merge-pathnames ".github/actions/ci/publish.lisp" root))))
    (ok (not (search "(list system)" text)))
    (ok (search "filter-publish-provides" text))))

(deftest native-publish-loads-packager-via-client
  "Native publish bootstraps like canned ci phase:publish. No QL, no packager
   symbols in the files LOADed before ensure-systems."
  (let* ((root (uiop:pathname-directory-pathname
                (asdf:system-source-file "cl-repository-packager")))
         (entry (uiop:read-file-string
                 (merge-pathnames "scripts/ci/publish-native-package.lisp" root)))
         (ensure (uiop:read-file-string
                  (merge-pathnames "scripts/ci/ensure-packager.lisp" root)))
         (workflow (uiop:read-file-string
                    (merge-pathnames ".github/workflows/publish-native-package.yml" root))))
    (dolist (text (list entry ensure))
      (ok (not (search "ql:quickload" text)))
      (ok (not (search "quicklisp/setup.lisp" text)))
      (dolist (pkg '("cl-repository-packager/asdf-plugin:"
                     "cl-repository-packager/build-matrix:"
                     "cl-repository-packager/publisher:"
                     "cl-oci-client/auth:"
                     "cl-oci-client/registry:"))
        (ok (not (search pkg text)) pkg)))
    (ok (search "ensure-packager.lisp" entry))
    (ok (search "cl-repo:ensure-systems" ensure))
    (ok (search "setup-lisp@main" workflow))
    (ok (search "job.workflow_sha" workflow))
    ;; the comment beside it names github.workflow_sha; the expression must not appear
    (ok (not (search "${{ github.workflow_sha" workflow)))
    (ok (not (search "apt-get install -y sbcl" workflow)))
    (ok (not (search "quicklisp.lisp" workflow)))))

(deftest classpath-entries-keeps-existing-in-order
  "Only entries that exist survive; separator follows the platform flag."
  (let* ((dir (make-temp-dir))
         (jar (merge-pathnames "jna.jar" dir)))
    (with-open-file (s jar :direction :output :if-exists :supersede)
      (write-string "" s))
    (let ((cp (format nil "~a:~a:~a" (namestring jar) "/nonexistent/x.jar"
                      (namestring dir))))
      (ok (equal (cl-repository-ci-lib:classpath-entries cp nil)
                 (list (namestring (probe-file jar))
                       (namestring (probe-file dir))))))
    (ok (equal (cl-repository-ci-lib:classpath-entries
                (format nil "~a;/nonexistent/y.jar" (namestring jar)) t)
               (list (namestring (probe-file jar)))))
    (ok (null (cl-repository-ci-lib:classpath-entries nil)))
    (ok (null (cl-repository-ci-lib:classpath-entries "" nil)))
    (uiop:delete-directory-tree dir :validate t)))

(deftest ci-action-files-read-balanced
  "Every .lisp file of the canned CI action reads to the end. This suite never
   loads run.lisp, so an unbalanced edit (#84) broke every repo's CI first.
   *READ-SUPPRESS* reads the structure without needing the packages."
  (let ((dir (merge-pathnames ".github/actions/ci/"
                              (uiop:pathname-directory-pathname
                               (asdf:system-source-file "cl-repository-packager")))))
    (dolist (file (directory (merge-pathnames "*.lisp" dir)))
      (ok (handler-case
              (with-open-file (in file)
                (let ((*read-suppress* t) (*read-eval* nil))
                  (loop until (eq (read in nil in) in))
                  t))
            (end-of-file () nil)
            (reader-error () nil))
          (format nil "~a reads to the end" (file-namestring file))))))

(deftest asd-system-versions-read-literal-version
  (let ((dir (make-temp-dir)))
    (unwind-protect
         (progn
           (write-asd dir "json-protocol.asd" :systems '("json-protocol" "json-protocol/tests")
                                              :extra ":version \"0.2.1\"")
           (write-asd dir "json-backend-jzon.asd" :systems '("json-backend-jzon")
                                                  :extra ":version \"0.2.0\"")
           (write-asd dir "computed.asd" :systems '("computed")
                                         :extra ":version (:read-file-form \"v.sexp\")")
           (let ((pairs (cl-repository-ci-lib:discover-asd-system-versions dir)))
             (ok (equal (cdr (assoc "json-protocol" pairs :test #'string=)) "0.2.1"))
             (ok (equal (cdr (assoc "json-backend-jzon" pairs :test #'string=)) "0.2.0"))
             (ok (assoc "computed" pairs :test #'string=))
             (ok (null (cdr (assoc "computed" pairs :test #'string=))))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest publish-provides-system-first-drops-other-versions
  "json-protocol#19: every job of a multi-.asd checkout pushed to the first
   sibling's repo and mounted itself onto the others at its own tag."
  (let ((declared '(("json-backend-jzon" . "0.2.0")
                    ("json-backend-yason" . "0.2.0")
                    ("json-protocol" . "0.2.1")
                    ("extras" . nil))))
    (multiple-value-bind (kept dropped)
        (cl-repository-ci-lib:publish-provides
         "json-protocol" "0.2.1"
         '("json-backend-jzon" "json-backend-yason" "json-protocol" "json-protocol/x" "extras")
         declared)
      (ok (equal kept '("json-protocol" "json-protocol/x" "extras")))
      (ok (equal dropped '("json-backend-jzon" "json-backend-yason"))))
    (multiple-value-bind (kept dropped)
        (cl-repository-ci-lib:publish-provides
         "json-backend-yason" "0.2.0"
         '("json-backend-jzon" "json-backend-yason" "json-protocol")
         declared)
      (ok (equal kept '("json-backend-yason" "json-backend-jzon")))
      (ok (equal dropped '("json-protocol"))))))

(deftest check-publish-version-refuses-mismatched-tag
  (ok (equal (cl-repository-ci-lib:check-publish-version "foo" nil "1.0") "1.0"))
  (ok (equal (cl-repository-ci-lib:check-publish-version "foo" "1.0" "1.0") "1.0"))
  (ok (equal (cl-repository-ci-lib:check-publish-version "cffi" "0.24.1" nil) "0.24.1"))
  (ok (signals (cl-repository-ci-lib:check-publish-version "json-backend-jzon" "0.2.1" "0.2.0")
               'cl-repository-ci-lib:publish-version-mismatch))
  (ok (equal (handler-bind ((cl-repository-ci-lib:publish-version-mismatch #'continue))
               (cl-repository-ci-lib:check-publish-version "foo" "2.0" "1.0"))
             "2.0")))

(deftest own-provides-explicit-system-drops-same-version-siblings
  "cl-repository#109: json-protocol 0.2.0 rebuild — every sibling shared the
   version, so each matrix job mounted its index onto the others' tags."
  (let ((dir (make-temp-dir))
        (provides '("json-backend-yason" "json-backend-jzon" "json-protocol"
                    "json-backend-yason/x")))
    (unwind-protect
         (progn
           (write-asd dir "json-protocol.asd" :systems '("json-protocol" "json-protocol/tests"))
           (write-asd dir "json-backend-jzon.asd" :systems '("json-backend-jzon"))
           (write-asd dir "json-backend-yason.asd"
                      :systems '("json-backend-yason" "json-backend-yason/x"))
           (ok (= 3 (length (cl-repository-ci-lib:primary-asd-files dir))))
           (multiple-value-bind (kept dropped)
               (cl-repository-ci-lib:own-provides
                "json-backend-yason" provides
                :explicit-system "json-backend-yason" :source-dir dir)
             (ok (equal kept '("json-backend-yason" "json-backend-yason/x")))
             (ok (equal dropped '("json-backend-jzon" "json-protocol"))))
           (testing "declared :provides wins"
             (ok (equal (cl-repository-ci-lib:own-provides
                         "json-backend-yason" provides
                         :explicit-system "json-backend-yason"
                         :declared-provides '("json-backend-yason" "json-protocol")
                         :source-dir dir)
                        provides)))
           (testing "discovered system keeps provides"
             (ok (equal (cl-repository-ci-lib:own-provides
                         "json-backend-yason" provides :source-dir dir)
                        provides))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest own-provides-single-asd-keeps-provides
  (let ((dir (make-temp-dir)))
    (unwind-protect
         (progn
           (write-asd dir "foo.asd" :systems '("foo" "foo-extra" "foo/tests"))
           (ok (equal (cl-repository-ci-lib:own-provides
                       "foo" '("foo" "foo-extra") :explicit-system "foo" :source-dir dir)
                      '("foo" "foo-extra"))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest sibling-asd-files-are-the-unprovided-ones
  "cl-repository#117: cli-backend-clingon:0.2.0 shipped a stale cli-protocol.asd."
  (let ((dir (make-temp-dir)))
    (unwind-protect
         (progn
           (write-asd dir "cli-protocol.asd" :systems '("cli-protocol" "cli-protocol/tests"))
           (write-asd dir "cli-backend-clingon.asd" :systems '("cli-backend-clingon"))
           (write-asd dir "cli-backend-adopt.asd" :systems '("cli-backend-adopt"))
           (write-asd dir "cli-backend-clingon-tests.asd" :systems '("cli-backend-clingon-tests"))
           (ok (equal (sort (mapcar #'pathname-name
                                    (cl-repository-ci-lib:sibling-asd-files
                                     dir '("cli-backend-clingon")))
                            #'string<)
                      '("cli-backend-adopt" "cli-protocol")))
           (ok (null (cl-repository-ci-lib:sibling-asd-files
                      dir '("cli-protocol" "cli-backend-clingon" "cli-backend-adopt")))
               "declared provides keep their .asd files")
           (ok (null (cl-repository-ci-lib:sibling-asd-files dir '("renamed-package")))
               "no own .asd: nothing is a sibling"))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest ci-action-has-run-phase
  "cl-repository#103: phase run = cl-repo run -- <command> in working-directory."
  (let* ((root (uiop:pathname-directory-pathname
                (asdf:system-source-file "cl-repository-packager")))
         (run (uiop:read-file-string (merge-pathnames ".github/actions/ci/run.lisp" root)))
         (action (uiop:read-file-string (merge-pathnames ".github/actions/ci/action.yml" root))))
    (ok (search "((string= phase \"run\") (%run-run)" run))
    (ok (search "CL_REPO_RUN_ARGV_FILE" run))
    (ok (search "working-directory: ${{ inputs.working-directory }}" action))
    (ok (search "CL_REPO_RUN_COMMAND: ${{ inputs.command }}" action))))
