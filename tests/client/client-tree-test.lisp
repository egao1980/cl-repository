(defpackage :cl-repository-client/tests/client-tree-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/client-tree
                #:release-directory-name
                #:client-tree-copies
                #:install-client-tree-search
                #:*client-tree-copies*)
  (:import-from :cl-repository-client/asdf-integration
                #:refresh-own-copies
                #:registry-search
                #:own-copies-form
                #:*own-copies*
                #:*locked-versions*))
(in-package :cl-repository-client/tests/client-tree-test)

;;; cl-repository#207: ~/.cl-repository-client holds NAME-VERSION/
;;; directories, and upgrades stage additively, so a dependency can be there
;;; in several versions. Registered as one (:tree DEST), ASDF took the first
;;; .asd in path order: the client ran http-backend-async 0.2.28 although
;;; 0.2.32 was there.

(deftest-parametrize release-directory-names-split
    ((leaf name version)
     ("http-backend-async-0.2.32" "http-backend-async" "0.2.32")
     ("cl-base64-3.1" "cl-base64" "3.1")
     ("cl-oci-0.27.42" "cl-oci" "0.27.42")
     ("alexandria-20240503-8514d8e" "alexandria" "20240503-8514d8e")
     ("cl-stack-ssl-3.5.9.4" "cl-stack-ssl" "3.5.9.4")
     ("x2d-lib-2d-1.0" "x2d-lib-2d" "1.0")
     ("no-version" nil nil)
     ("cl+ssl-e9de2ca650137bc92d1ac32224165354b3bd820d" nil nil))
  (ok (equal (list name version)
             (multiple-value-bind (n v) (release-directory-name leaf) (list n v)))
      leaf))

(defun %tmp ()
  (uiop:ensure-directory-pathname
   (format nil "~a/cl-repo-207-~36r/" (uiop:temporary-directory)
           (random (expt 36 6) (make-random-state t)))))

(defun %write-asd (dir name version)
  (ensure-directories-exist dir)
  (with-open-file (o (merge-pathnames (format nil "~a.asd" name) dir)
                     :direction :output :if-exists :supersede)
    (format o "(defsystem ~s :version ~s)~%(defsystem ~s :version ~s)~%"
            name version (format nil "~a/tests" name) version)))

(defun %registry (&rest dirs)
  (asdf:initialize-source-registry
   `(:source-registry ,@(mapcar (lambda (d) (list :tree (namestring d))) dirs)
                      :ignore-inherited-configuration)))

(defun %true (p) (and p (uiop:truename* p)))

(deftest a-numbered-name-splits-where-its-asd-is
  (let* ((tmp (%tmp))
         (dir (merge-pathnames "cl-repo-207-a-0.2.32/" tmp)))
    (unwind-protect
        (progn
          (ok (equal '("cl-repo" "207-a-0.2.32")
                     (multiple-value-list (release-directory-name "cl-repo-207-a-0.2.32")))
              "without a directory, the first split")
          (%write-asd dir "cl-repo-207-a" "0.2.32")
          (ok (equal '("cl-repo-207-a" "0.2.32")
                     (multiple-value-list (release-directory-name "cl-repo-207-a-0.2.32" dir)))
              "the directory's NAME.asd decides"))
      (uiop:delete-directory-tree tmp :validate t :if-does-not-exist :ignore))))

(defmacro with-client-tree ((dest &rest vars) &body body)
  "BODY with DEST a fresh client tree and the registry, the own-copies state
   and ASDF's search functions restored afterwards."
  `(let* ((,dest (%tmp))
          (saved asdf/source-registry:*source-registry-parameter*)
          (cl-repository-client/installer::*systems-root* (merge-pathnames "no-systems/" ,dest))
          (*locked-versions* '())
          (*own-copies* '())
          (*client-tree-copies* '())
          (asdf:*system-definition-search-functions*
            (copy-list asdf:*system-definition-search-functions*))
          ,@vars)
     (unwind-protect (progn ,@body)
       (dolist (name '("cl-repo-207-a" "cl-repo-207-c" "cl-repo-207-cli"))
         (asdf:clear-system name))
       (if saved (asdf:initialize-source-registry saved) (asdf:clear-source-registry))
       (uiop:delete-directory-tree ,dest :validate t :if-does-not-exist :ignore))))

(deftest issue-207-the-newest-release-in-the-client-tree-wins
  (with-client-tree (dest)
    (let ((newest-a (merge-pathnames "cl-repo-207-a-0.2.32/" dest))
          (fresh-c (merge-pathnames "cl-repo-207-c-0.2.0/" dest)))
      (%write-asd (merge-pathnames "cl-repo-207-a-0.2.28/" dest) "cl-repo-207-a" "0.2.28")
      (%write-asd newest-a "cl-repo-207-a" "0.2.32")
      ;; Another package's bundled stale copy of c, met before c's own.
      (%write-asd (merge-pathnames "cl-repo-207-b-1.0/" dest) "cl-repo-207-b" "1.0")
      (%write-asd (merge-pathnames "cl-repo-207-b-1.0/" dest) "cl-repo-207-c" "0.1.0")
      (%write-asd fresh-c "cl-repo-207-c" "0.2.0")
      (%registry dest)
      (ok (uiop:subpathp (%true (asdf/source-registry:sysdef-source-registry-search "cl-repo-207-a"))
                         (%true (merge-pathnames "cl-repo-207-a-0.2.28/" dest)))
          "precondition: the plain :tree resolves the oldest release")
      (let ((copies (client-tree-copies dest)))
        (ok (equal '("cl-repo-207-a" "cl-repo-207-c") (mapcar #'car copies))
            "the shadowed systems are mapped, in name order")
        (ok (equal (%true (merge-pathnames "cl-repo-207-a.asd" newest-a))
                   (%true (cdr (assoc "cl-repo-207-a" copies :test #'string=)))))
        (ok (equal (%true (merge-pathnames "cl-repo-207-c.asd" fresh-c))
                   (%true (cdr (assoc "cl-repo-207-c" copies :test #'string=))))
            "a bundled stale copy gives way to the own release"))
      (testing "the launcher's search function"
        (install-client-tree-search dest)
        (asdf:clear-system "cl-repo-207-a")
        (ok (equal "0.2.32" (asdf:component-version (asdf:find-system "cl-repo-207-a"))))
        (ok (equal "0.2.32" (asdf:component-version (asdf:find-system "cl-repo-207-a/tests")))
            "a secondary system follows its primary"))
      (testing "the client: refresh-own-copies maps the client tree too"
        (refresh-own-copies (merge-pathnames "no-systems/" dest) '() dest)
        (ok (null *client-tree-copies*) "the launcher's mapping is superseded")
        (ok (not (member 'cl-repository-client/client-tree::client-tree-search
                         asdf:*system-definition-search-functions*)))
        (ok (equal (%true (merge-pathnames "cl-repo-207-a.asd" newest-a))
                   (%true (registry-search "cl-repo-207-a/tests"))))
        (let* ((form (read-from-string (own-copies-form)))
               (asdf:*system-definition-search-functions* '()))
          (eval form)
          (ok (equal (%true (merge-pathnames "cl-repo-207-a.asd" newest-a))
                     (%true (funcall (first asdf:*system-definition-search-functions*)
                                     "cl-repo-207-a")))
              "a fresh image gets the same mapping"))))))

(deftest issue-207-the-running-client-and-a-checkout-are-left-alone
  (with-client-tree (dest (project (%tmp)))
    (let ((client (merge-pathnames "cl-repo-207-cli-0.1.0/" dest)))
      (unwind-protect
          (progn
            (%write-asd client "cl-repo-207-cli" "0.1.0")
            (%write-asd (merge-pathnames "cl-repo-207-cli-0.2.0/" dest) "cl-repo-207-cli" "0.2.0")
            (%write-asd (merge-pathnames "cl-repo-207-a-0.2.28/" dest) "cl-repo-207-a" "0.2.28")
            (%write-asd (merge-pathnames "cl-repo-207-a-0.2.32/" dest) "cl-repo-207-a" "0.2.32")
            (%write-asd project "cl-repo-207-a" "0.3.0")
            ;; As cl-repo.ros registers it: the client's own directory first.
            (%registry client dest)
            (ok (equal '("cl-repo-207-a") (mapcar #'car (client-tree-copies dest :keep (list client))))
                "a system the running client's directory provides keeps that copy")
            (%registry project client dest)
            (ok (null (client-tree-copies dest :keep (list client)))
                "a project checkout still shadows the client tree"))
        (uiop:delete-directory-tree project :validate t :if-does-not-exist :ignore)))))
