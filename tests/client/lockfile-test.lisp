(defpackage :cl-repository-client/tests/lockfile-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/lockfile
                #:lockfile-entry #:lockfile-entry-system #:lockfile-entry-version
                #:read-lockfile #:write-lockfile))
(in-package :cl-repository-client/tests/lockfile-test)

(deftest lockfile-round-trip
  (let ((entries (list (make-instance 'lockfile-entry
                                      :system "alexandria"
                                      :version "1.4"
                                      :index-digest "sha256:aaa"
                                      :registry "ghcr.io/cl-systems")
                       (make-instance 'lockfile-entry
                                      :system "cffi"
                                      :version "0.24.1"
                                      :index-digest "sha256:bbb"
                                      :source-digest "sha256:ccc"
                                      :registry "ghcr.io/cl-systems")))
        (tmp-path (merge-pathnames "cl-repo-test.lock" (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (write-lockfile entries tmp-path)
           (let ((loaded (read-lockfile tmp-path)))
             (ok (= (length loaded) 2))
             (ok (string= (lockfile-entry-system (first loaded)) "alexandria"))
             (ok (string= (lockfile-entry-version (second loaded)) "0.24.1"))))
      (when (probe-file tmp-path) (delete-file tmp-path)))))
