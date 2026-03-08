(defpackage :cl-repository-client/tests/lockfile-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/lockfile
                #:lockfile-entry #:lockfile-entry-system #:lockfile-entry-version
                #:lockfile-entry-index-digest #:lockfile-entry-source-digest
                #:lockfile-entry-overlay-digest #:lockfile-entry-registry
                #:read-lockfile #:write-lockfile #:add-lockfile-entry)
  (:import-from :cl-repository-client/installer
                #:install-result #:make-install-result
                #:install-result-path #:install-result-name #:install-result-version
                #:install-result-index-digest #:install-result-source-digest
                #:install-result-overlay-digest #:install-result-registry-url))
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

(deftest lockfile-add-entry
  (let ((tmp-path (merge-pathnames "cl-repo-add-test.lock" (uiop:temporary-directory))))
    (unwind-protect
         (progn
           ;; Start fresh
           (when (probe-file tmp-path) (delete-file tmp-path))
           ;; Add first entry
           (add-lockfile-entry
            (make-instance 'lockfile-entry
                           :system "alexandria"
                           :version "1.4"
                           :index-digest "sha256:aaa"
                           :registry "ghcr.io")
            tmp-path)
           (let ((loaded (read-lockfile tmp-path)))
             (ok (= (length loaded) 1))
             (ok (string= (lockfile-entry-system (first loaded)) "alexandria")))
           ;; Add second entry
           (add-lockfile-entry
            (make-instance 'lockfile-entry
                           :system "cl-ppcre"
                           :version "2.1.1"
                           :index-digest "sha256:bbb"
                           :registry "ghcr.io")
            tmp-path)
           (let ((loaded (read-lockfile tmp-path)))
             (ok (= (length loaded) 2)))
           ;; Update existing entry (same system, new version)
           (add-lockfile-entry
            (make-instance 'lockfile-entry
                           :system "alexandria"
                           :version "1.5"
                           :index-digest "sha256:ccc"
                           :registry "ghcr.io")
            tmp-path)
           (let ((loaded (read-lockfile tmp-path)))
             (ok (= (length loaded) 2) "Count stays 2 after update")
             (let ((alex (find "alexandria" loaded
                               :key #'lockfile-entry-system :test #'string=)))
               (ok (string= (lockfile-entry-version alex) "1.5"))
               (ok (string= (lockfile-entry-index-digest alex) "sha256:ccc")))))
      (when (probe-file tmp-path) (delete-file tmp-path)))))

(deftest lockfile-read-missing
  (testing "Reading a non-existent lockfile returns NIL"
    (ok (null (read-lockfile (merge-pathnames "does-not-exist.lock" (uiop:temporary-directory)))))))

(deftest lockfile-preserves-optional-digests
  (testing "Source and overlay digests round-trip correctly"
    (let ((tmp-path (merge-pathnames "cl-repo-digest-test.lock" (uiop:temporary-directory))))
      (unwind-protect
           (progn
             (write-lockfile
              (list (make-instance 'lockfile-entry
                                   :system "cffi"
                                   :version "0.24.1"
                                   :index-digest "sha256:idx"
                                   :source-digest "sha256:src"
                                   :overlay-digest "sha256:ovl"
                                   :registry "ghcr.io"))
              tmp-path)
             (let* ((loaded (read-lockfile tmp-path))
                    (entry (first loaded)))
               (ok (string= (lockfile-entry-source-digest entry) "sha256:src"))
               (ok (string= (lockfile-entry-overlay-digest entry) "sha256:ovl"))))
        (when (probe-file tmp-path) (delete-file tmp-path))))))

(deftest install-result-struct
  (testing "install-result carries all digest fields"
    (let ((r (make-install-result :path #p"/tmp/test/"
                                  :name "alexandria"
                                  :version "1.4"
                                  :index-digest "sha256:idx"
                                  :source-digest "sha256:src"
                                  :overlay-digest "sha256:ovl"
                                  :registry-url "ghcr.io")))
      (ok (string= (install-result-name r) "alexandria"))
      (ok (string= (install-result-version r) "1.4"))
      (ok (string= (install-result-index-digest r) "sha256:idx"))
      (ok (string= (install-result-source-digest r) "sha256:src"))
      (ok (string= (install-result-overlay-digest r) "sha256:ovl"))
      (ok (string= (install-result-registry-url r) "ghcr.io"))
      (ok (install-result-path r)))))
