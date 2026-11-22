(defpackage :cl-repository-client/tests/installer-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/installer #:system-install-path #:role-subdirectory
                #:drop-sibling-asds #:provides-link-target #:claim-system-directory
                #:drop-stale-provides-links)
  (:import-from :cl-oci/config #:make-cl-system-config)
  (:import-from :flexi-streams))
(in-package :cl-repository-client/tests/installer-test)

(deftest install-path-construction
  (let ((path (system-install-path "alexandria" "1.4")))
    (ok (search "alexandria" (namestring path)))
    (ok (search "1.4" (namestring path)))))

(deftest install-path-rejects-traversal
  (ok (signals (system-install-path "../evil" "1.0")))
  (ok (signals (system-install-path "alexandria" "../../etc")))
  (ok (signals (system-install-path "a/b" "1.0")))
  (ok (signals (system-install-path ".." "1.0")))
  (ok (signals (system-install-path "" "1.0"))))

;;; --- tar extraction safety ---

(defun make-tar-header (name size &key (type (char-code #\0)))
  "Build a minimal 512-byte tar header for tests (checksum not needed by parser)."
  (let ((header (make-array 512 :element-type '(unsigned-byte 8) :initial-element 0))
        (name-bytes (babel:string-to-octets name :encoding :utf-8))
        (size-bytes (babel:string-to-octets (format nil "~11,'0o " size) :encoding :ascii)))
    (replace header name-bytes :start1 0)
    (replace header size-bytes :start1 124)
    (setf (aref header 156) type)
    header))

(defun make-tar-bytes (entries)
  "Build raw tar bytes from ENTRIES, a list of (name . content-string)."
  (flexi-streams:with-output-to-sequence (out)
    (dolist (entry entries)
      (let* ((content (babel:string-to-octets (cdr entry) :encoding :utf-8))
             (size (length content)))
        (write-sequence (make-tar-header (car entry) size) out)
        (write-sequence content out)
        (let ((pad (mod (- 512 (mod size 512)) 512)))
          (write-sequence (make-array pad :element-type '(unsigned-byte 8)
                                          :initial-element 0)
                          out))))
    ;; End-of-archive: two zero blocks
    (write-sequence (make-array 1024 :element-type '(unsigned-byte 8) :initial-element 0)
                    out)))

(defmacro with-temp-extract-dir ((dir) &body body)
  `(let ((,dir (uiop:ensure-directory-pathname
                (merge-pathnames (format nil "cl-repo-tar-test-~a-~a/"
                                         (get-universal-time) (random 1000000))
                                 (uiop:temporary-directory)))))
     (ensure-directories-exist ,dir)
     (unwind-protect (progn ,@body)
       (uiop:delete-directory-tree ,dir :validate t :if-does-not-exist :ignore))))

(defun extract-tar-bytes (bytes dir)
  (flexi-streams:with-input-from-sequence (in bytes)
    (cl-repository-client/installer::extract-tar-stream in dir)))

(deftest extract-tar-normal-entries
  (with-temp-extract-dir (dir)
    (extract-tar-bytes (make-tar-bytes '(("hello.lisp" . "(defun hi ())")
                                         ("sub/file.txt" . "content")))
                       dir)
    (ok (uiop:file-exists-p (merge-pathnames "hello.lisp" dir)))
    (ok (uiop:file-exists-p (merge-pathnames "sub/file.txt" dir)))))

(deftest extract-tar-rejects-parent-traversal
  (with-temp-extract-dir (dir)
    (ok (signals (extract-tar-bytes
                  (make-tar-bytes '(("../escape.txt" . "pwned")))
                  dir)))
    (ok (not (uiop:file-exists-p (merge-pathnames "../escape.txt" dir))))))

(deftest extract-tar-rejects-absolute-path
  (with-temp-extract-dir (dir)
    (ok (signals (extract-tar-bytes
                  (make-tar-bytes '(("/tmp/cl-repo-absolute-escape" . "pwned")))
                  dir)))))

(deftest extract-tar-rejects-nested-dotdot
  (with-temp-extract-dir (dir)
    (ok (signals (extract-tar-bytes
                  (make-tar-bytes '(("safe/../../escape.txt" . "pwned")))
                  dir)))))

(deftest role-subdirectory-mapping
  (ok (null (cl-repository-client/installer::role-subdirectory "source")))
  (ok (string= (cl-repository-client/installer::role-subdirectory "native-library") "native"))
  (ok (string= (cl-repository-client/installer::role-subdirectory "cffi-grovel-output") "grovel-cache"))
  (ok (string= (cl-repository-client/installer::role-subdirectory "headers") "headers"))
  (ok (string= (cl-repository-client/installer::role-subdirectory "documentation") "docs")))

(defun read-init-file (path)
  "Read PATH as a string."
  (with-open-file (s path :direction :input)
    (let ((buf (make-string (file-length s))))
      (subseq buf 0 (read-sequence buf s)))))

(defun init-file-parses-p (path)
  "Verify the generated init file is a sequence of readable Lisp forms."
  (with-open-file (s path :direction :input)
    (let ((*read-eval* nil) (*package* (find-package :cl-user)))
      (handler-case
          (loop for form = (read s nil :eof) until (eq form :eof) finally (return t))
        (error () nil)))))

(deftest shared-library-pathname-detection
  (ok (cl-repository-client/installer::shared-library-pathname-p #p"/x/libssl.so"))
  (ok (cl-repository-client/installer::shared-library-pathname-p #p"/x/libssl.so.3"))
  (ok (cl-repository-client/installer::shared-library-pathname-p #p"/x/libssl.dylib"))
  (ok (cl-repository-client/installer::shared-library-pathname-p #p"/x/libssl-3-x64.dll"))
  (ng (cl-repository-client/installer::shared-library-pathname-p #p"/x/README.md"))
  (ng (cl-repository-client/installer::shared-library-pathname-p #p"/x/libssl.a")))

;;; --- sibling .asd files (#117) ---

(defun touch (dir name)
  (with-open-file (s (merge-pathnames name dir) :direction :output :if-exists :supersede)
    (write-line "(defsystem \"x\")" s)))

(defun asd-names (dir)
  (sort (mapcar #'pathname-name (directory (merge-pathnames "*.asd" dir))) #'string<))

(deftest drop-sibling-asds-keeps-the-package-systems
  (with-temp-extract-dir (dir)
    (dolist (f '("cli-protocol.asd" "cli-backend-clingon.asd" "cli-backend-adopt.asd"
                 "cli-backend-clingon-tests.asd" "README.md"))
      (touch dir f))
    (let ((deleted (drop-sibling-asds dir "cli-backend-clingon" '("cli-backend-clingon"))))
      (ok (equal '("cli-backend-adopt" "cli-protocol")
                 (sort (mapcar #'pathname-name deleted) #'string<)))
      (ok (equal '("cli-backend-clingon" "cli-backend-clingon-tests") (asd-names dir))
          "the own .asd and the test .asd stay")
      (ok (probe-file (merge-pathnames "README.md" dir))))))

(deftest drop-sibling-asds-honours-provides
  (with-temp-extract-dir (dir)
    (dolist (f '("capability-protocol.asd" "blackboard-protocol.asd")) (touch dir f))
    (ok (null (drop-sibling-asds dir "capability-protocol"
                                 '("capability-protocol" "blackboard-protocol"
                                   "capability-protocol/tests"))))
    (ok (equal '("blackboard-protocol" "capability-protocol") (asd-names dir)))))

(deftest drop-sibling-asds-without-provides-keeps-all
  (with-temp-extract-dir (dir)
    (dolist (f '("a.asd" "b.asd")) (touch dir f))
    (ok (null (drop-sibling-asds dir "a" nil)))
    (ok (equal '("a" "b") (asd-names dir)))))

(deftest drop-sibling-asds-keeps-a-renamed-package
  "A package published under another name than its .asd (cl-calc → cl-calc-e2e)."
  (with-temp-extract-dir (dir)
    (touch dir "cl-calc.asd")
    (ok (null (drop-sibling-asds dir "cl-calc-e2e" '("cl-calc-e2e"))))
    (ok (equal '("cl-calc") (asd-names dir)))))

;;; --- stale provides links (#124, #128) ---

(defmacro with-temp-systems-root ((root) &body body)
  `(let* ((,root (uiop:ensure-directory-pathname
                  (format nil "~a/cl-repo-links-~36r/" (uiop:temporary-directory)
                          (random (expt 36 6)))))
          (cl-repository-client/installer::*systems-root* ,root))
     (ensure-directories-exist ,root)
     (unwind-protect (progn ,@body)
       ;; Links first: a tree walk must not follow them into their target.
       (dolist (d (uiop:subdirectories ,root))
         (let ((name (car (last (pathname-directory d)))))
           (when (provides-link-target name)
             (cl-repository-client/installer::remove-directory-link name))))
       (uiop:delete-directory-tree ,root :validate t :if-does-not-exist :ignore))))

(defun link (root name target)
  (cl-repository-client/installer::make-directory-link
   (merge-pathnames name root)
   (merge-pathnames (format nil "~a/" target) root)))

(defun installed (root name version &rest asds)
  (let ((dir (merge-pathnames (format nil "~a/~a/" name version) root)))
    (ensure-directories-exist dir)
    (dolist (a asds) (touch dir (format nil "~a.asd" a)))
    dir))

(deftest claim-system-directory-replaces-a-provides-link
  "json-backend-yason -> json-protocol/ (from a json-protocol that carried
   yason): installing json-backend-yason must not write into json-protocol/."
  (with-temp-systems-root (root)
    (let ((proto (installed root "json-protocol" "0.2.1" "json-protocol")))
      (link root "json-backend-yason" "json-protocol")
      (ok (provides-link-target "json-backend-yason"))
      (ok (claim-system-directory "json-backend-yason") "the link is reported")
      (ng (provides-link-target "json-backend-yason"))
      (let ((dir (system-install-path "json-backend-yason" "0.2.1")))
        (ensure-directories-exist dir)
        (touch dir "json-backend-yason.asd")
        (ok (null (drop-sibling-asds dir "json-backend-yason" '("json-backend-yason")))))
      (ok (equal '("json-protocol") (asd-names proto))
          "json-protocol's version directory is untouched")
      (ok (equal '("json-backend-yason")
                 (asd-names (system-install-path "json-backend-yason" "0.2.1"))))
      (ok (null (claim-system-directory "json-backend-yason"))
          "a real directory is left alone"))))

(deftest drop-stale-provides-links-removes-names-no-longer-provided
  "html-backend-plump 0.1.0 provided html-protocol; 0.1.1 does not."
  (with-temp-systems-root (root)
    (let ((plump (installed root "html-backend-plump" "0.1.1" "html-backend-plump")))
      (installed root "other" "1.0" "other")
      (link root "html-protocol" "html-backend-plump")
      (link root "html-backend-plump-extra" "html-backend-plump")
      (link root "unrelated" "other")
      (ok (equal '("html-protocol")
                 (drop-stale-provides-links "html-backend-plump"
                                            '("html-backend-plump"
                                              "html-backend-plump-extra"))))
      (ng (probe-file (merge-pathnames "html-protocol/" root)))
      (ok (provides-link-target "html-backend-plump-extra") "a name still provided keeps its link")
      (ok (provides-link-target "unrelated") "another package's link stays")
      (ok (equal '("html-backend-plump") (asd-names plump)) "the target is untouched")
      (ok (null (drop-stale-provides-links "html-backend-plump" nil))
          "unknown provides removes nothing"))))

(deftest drop-sibling-asds-never-deletes-through-a-link
  "html-protocol -> html-backend-plump/: the two packages must not delete each
   other's .asd in the shared directory."
  (with-temp-systems-root (root)
    (let ((shared (installed root "html-backend-plump" "0.1.1"
                             "html-backend-plump" "html-protocol")))
      (link root "html-protocol" "html-backend-plump")
      (ok (null (drop-sibling-asds (system-install-path "html-protocol" "0.1.1")
                                   "html-protocol" '("html-protocol"))))
      (ok (equal '("html-backend-plump" "html-protocol") (asd-names shared))))))

(deftest still-missing-message-names-an-install-without-its-asd
  (with-temp-systems-root (root)
    (installed root "json-protocol" "0.2.1" "json-backend-yason")
    (installed root "fine" "1.0" "fine")
    (let ((m (cl-repository-client/quickload::still-missing-message
              '("json-protocol" "nowhere" "fine")
              '(("fine" . "2.0")))))
      (ok (search "the install of json-protocol 0.2.1 did not produce json-protocol.asd" m) m)
      (ok (search "system nowhere is not in the registry" m) m)
      (ok (search "system fine 1.0 is installed" m) m)
      (ng (search "json-protocol is not in the registry" m) m))))
