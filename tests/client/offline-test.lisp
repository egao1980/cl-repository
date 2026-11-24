(defpackage :cl-repository-client/tests/offline-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/quickload
                #:outdated-installs #:ensure-system-installed #:*registries*)
  (:import-from :cl-repository-client/constraint-builder
                #:system-lookup-error #:system-lookup-error-failures)
  (:import-from :cl-repository-client/sync-lock
                #:install-lockfile-entries #:lockfile-entry-unavailable
                #:lockfile-entry-unavailable-system)
  (:import-from :cl-repository-client/lockfile #:lockfile-entry)
  (:import-from :cl-repository-client/project
                #:client-release-version #:cmd-client-version)
  (:import-from :cl-oci-client/conditions #:registry-unreachable))
(in-package :cl-repository-client/tests/offline-test)

(defclass offline-backend (http-protocol:http-backend)
  ((requests :initform '() :accessor offline-requests))
  (:default-initargs :name "offline")
  (:documentation
   "An http-protocol backend for cl-repository#179: https://down.test refuses
    every connection, as a closed port or a dead proxy does; https://up.test
    lists the tags 1.0 and 2.0 for every repository and answers 404 to
    anything else. Each request's URL is recorded."))

(defun respond (status body)
  (let ((headers (make-hash-table :test #'equal)))
    (setf (gethash "content-type" headers) "application/json")
    (make-instance 'http-protocol:http-response
                   :status status :headers headers
                   :body (babel:string-to-octets body :encoding :utf-8))))

(defmethod http-protocol:send ((backend offline-backend) client request &key)
  (declare (ignore client))
  (let ((url (http-protocol:http-request-url request)))
    (push url (offline-requests backend))
    (cond ((search "://down.test" url)
           (error 'http-protocol:http-connection-error :message "connection refused"))
          ((search "/tags/list" url)
           (respond 200 "{\"name\":\"ns/x\",\"tags\":[\"1.0\",\"2.0\"]}"))
          (t (respond 404 "{\"errors\":[{\"code\":\"NAME_UNKNOWN\"}]}")))))

(defun requests-to (backend host)
  (count-if (lambda (url) (search host url)) (offline-requests backend)))

(defun package-names (n)
  (loop for i from 1 to n collect (format nil "cl-repo-off-~d" i)))

(defun call-offline (packages registries fn)
  "Call FN with PACKAGES (names) installed at 1.0 in a fresh install tree,
   the only tree on the source registry; *REGISTRIES* the URLs REGISTRIES
   (namespace ns); and an OFFLINE-BACKEND that no host has answered yet.
   Retries are those of a sync: *TRANSPORT-RETRY* keeps its backoff of 1, 2
   and 4 s. FN gets the backend."
  (let* ((root (uiop:ensure-directory-pathname
                (format nil "~a/cl-repo-offline-~36r/" (uiop:temporary-directory)
                        (random (expt 36 8) (make-random-state t)))))
         (systems (merge-pathnames "systems/" root))
         (saved asdf:*source-registry-parameter*)
         (old-store (uiop:getenv "CL_REPO_CONFIG_CACHE"))
         (backend (make-instance 'offline-backend)))
    (ensure-directories-exist systems)
    (dolist (name packages)
      (let ((file (merge-pathnames (format nil "~a/1.0/~a.asd" name name) systems)))
        (ensure-directories-exist file)
        (with-open-file (o file :direction :output :if-exists :supersede)
          (format o "(defsystem ~s :version \"1.0\")~%" name))))
    (unwind-protect
         (let ((cl-repository-client/installer::*systems-root* systems)
               (*registries* (mapcar (lambda (url) (list url :namespace "ns")) registries))
               (cl-repository-client/asdf-integration:*locked-versions* nil)
               (cl-repository-client/constraint-builder:*resolution-cache* nil)
               (cl-oci-client/pull:*pull-cache* nil)
               (http-protocol:*http-backend* backend)
               (cl-oci-client/http::*http-backend-kind* :dexador)
               (cl-oci-client/http::*http-clients* '())
               (cl-oci-client/http:*host-outcomes* (make-hash-table :test 'equal)))
           (setf (uiop:getenv "CL_REPO_CONFIG_CACHE") "off")
           (asdf:initialize-source-registry
            `(:source-registry (:tree ,(namestring systems)) :ignore-inherited-configuration))
           (funcall fn backend))
      (dolist (name packages)
        (asdf:clear-system name))
      (setf (uiop:getenv "CL_REPO_CONFIG_CACHE") (or old-store ""))
      (if saved (asdf:initialize-source-registry saved) (asdf:clear-source-registry))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(defun capturing-log (fn)
  "(values what FN returns, its cl-repo log, the seconds it took)."
  (let ((start (get-internal-real-time))
        (result nil))
    (let ((log (with-output-to-string (s)
                 (let ((cl-oci/runtime:*quiet* nil)
                       (*standard-output* s))
                   (setf result (funcall fn))))))
      (values result log
              (/ (- (get-internal-real-time) start) internal-time-units-per-second 1.0)))))

(defun occurrences (needle haystack)
  (loop for start = 0 then (+ pos (length needle))
        for pos = (search needle haystack :start2 start)
        while pos
        count t))

(deftest issue-179-a-refusing-registry-costs-one-request
  "cl-repository#179: OUTDATED-INSTALLS, which a sync without a lock runs over
   the installed closure, against a registry that refuses every connection.
   Each package's tag listing was retried with backoff: about 7 s a package,
   77 s for ten. One request now shows that the registry is unreachable, for
   one package as for ten, with no wait, and the installed versions stay."
  (dolist (n '(1 10))
    (call-offline
     (package-names n) '("https://down.test")
     (lambda (backend)
       (multiple-value-bind (outdated log seconds)
           (capturing-log (lambda () (outdated-installs (package-names n))))
         (ok (null outdated) (format nil "~d package~:p: the installed versions stay" n))
         (ok (= 1 (requests-to backend "down.test"))
             (format nil "~d package~:p: one request (~d)" n (requests-to backend "down.test")))
         (ok (< seconds 2) (format nil "~d package~:p: no retry wait (~,1f s)" n seconds))
         (ok (search "keeping installed versions" log) log)
         (ok (search "Registry https://down.test is unreachable" log) log))))))

(deftest issue-179-a-dead-registry-beside-a-live-one-is-asked-once
  "cl-repository#179: a dead registry before a live one (cl-repo sync
   --registry http://127.0.0.1:9). Every package paid the dead one's retries,
   then got its versions from the live one: 424 s for dexador's closure. The
   dead one now gets one request and one log line, and the live one answers
   for every package."
  (let ((names (package-names 10)))
    (call-offline
     names '("https://down.test" "https://up.test")
     (lambda (backend)
       (multiple-value-bind (outdated log seconds)
           (capturing-log (lambda () (outdated-installs names)))
         (ok (= 10 (length outdated)) (format nil "all ten are outdated: ~s" outdated))
         (ok (every (lambda (entry) (equal "2.0" (cdr entry))) outdated) "at 2.0")
         (ok (= 1 (requests-to backend "down.test"))
             (format nil "the dead registry: one request (~d)" (requests-to backend "down.test")))
         (ok (= 10 (requests-to backend "up.test"))
             (format nil "the live one: a tag listing a package (~d)" (requests-to backend "up.test")))
         (ok (= 1 (occurrences "lookup in https://down.test failed" log))
             (format nil "one log line for the dead registry:~%~a" log))
         (ok (< seconds 2) (format nil "no retry wait (~,1f s)" seconds)))))))

(deftest issue-179-a-package-to-install-fails-at-once-when-the-registry-is-down
  "cl-repository#179: a package that is not installed, and a registry that
   refuses connections. SYSTEM-LOOKUP-ERROR names the package and says the
   registry is unreachable, after one request and no wait."
  (call-offline
   '() '("https://down.test")
   (lambda (backend)
     (multiple-value-bind (e log seconds)
         (capturing-log (lambda ()
                          (handler-case (progn (ensure-system-installed "cl-repo-off-missing") nil)
                            (system-lookup-error (c) c))))
       (declare (ignore log))
       (ok e "SYSTEM-LOOKUP-ERROR")
       (when e
         (let ((report (princ-to-string e)))
           (ok (typep (cdr (first (system-lookup-error-failures e))) 'registry-unreachable))
           (ok (search "could not look up or pull cl-repo-off-missing" report) report)
           (ok (search "Registry https://down.test is unreachable" report) report)
           (ok (search "connection refused" report) report)))
       (ok (= 1 (requests-to backend "down.test")))
       (ok (< seconds 2) (format nil "no retry wait (~,1f s)" seconds))))))

(deftest issue-179-a-locked-entry-that-cannot-be-fetched-is-named
  "cl-repository#179: a cl-repo.lock entry that is not installed, and its
   registry refuses connections. LOCKFILE-ENTRY-UNAVAILABLE names the entry
   and the unreachable registry, after one request."
  (call-offline
   '() '("https://down.test")
   (lambda (backend)
     (let ((entry (make-instance 'lockfile-entry
                                 :system "cl-repo-off-locked" :version "1.2"
                                 :index-digest "sha256:00" :registry "https://down.test")))
       (multiple-value-bind (e log seconds)
           (capturing-log (lambda ()
                            (handler-case (progn (install-lockfile-entries (list entry)) nil)
                              (lockfile-entry-unavailable (c) c))))
         (declare (ignore log))
         (ok e "LOCKFILE-ENTRY-UNAVAILABLE")
         (when e
           (let ((report (princ-to-string e)))
             (ok (equal "cl-repo-off-locked" (lockfile-entry-unavailable-system e)))
             (ok (search "cl-repo-off-locked 1.2 (cl-repo.lock) is not installed" report) report)
             (ok (search "Registry https://down.test is unreachable" report) report)))
         (ok (= 1 (requests-to backend "down.test")))
         (ok (< seconds 2) (format nil "no retry wait (~,1f s)" seconds)))))))

(deftest issue-189-the-release-version-comes-from-the-client-directory
  "cl-repository#189: cl-repo --version prints the release the client tree
   was extracted from (setup-client.sh puts release V in cl-oci-V/), and the
   tree. Another directory, such as a checkout, has no release version."
  (ok (equal "0.27.38" (client-release-version #p"/home/u/.cl-repository-client/cl-oci-0.27.38/")))
  (ok (equal "1.2.3" (client-release-version #p"/opt/cl-repository-client-1.2.3/")))
  (ok (null (client-release-version #p"/home/u/src/cl-repository/")))
  (ok (null (client-release-version #p"/home/u/x/cl-oci-client-0.2.0/")))
  (ok (null (client-release-version nil)))
  (let ((old (uiop:getenv "CL_REPOSITORY_CLIENT_DIR")))
    (unwind-protect
         (progn
           (setf (uiop:getenv "CL_REPOSITORY_CLIENT_DIR") "/tmp/cl-repo-189/cl-oci-9.8.7/")
           (let ((out (with-output-to-string (s) (cmd-client-version s))))
             (ok (search "cl-repo 9.8.7 (" out) out)
             (ok (search "cl-oci-9.8.7" out) out)))
      (setf (uiop:getenv "CL_REPOSITORY_CLIENT_DIR") (or old "")))))
