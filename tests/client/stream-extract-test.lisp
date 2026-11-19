(defpackage :cl-repository-client/tests/stream-extract-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/installer
                #:call-with-gunzip-stream
                #:extract-layer
                #:stream-gunzip-p))
(in-package :cl-repository-client/tests/stream-extract-test)

(defun read-all-octets (stream)
  (let ((chunks '())
        (total 0)
        (buf (make-array 64 :element-type '(unsigned-byte 8))))
    (loop for n = (read-sequence buf stream)
          until (zerop n)
          do (incf total n)
             (push (subseq buf 0 n) chunks))
    (let ((out (make-array total :element-type '(unsigned-byte 8)))
          (pos 0))
      (dolist (chunk (nreverse chunks) out)
        (replace out chunk :start1 pos)
        (incf pos (length chunk))))))

(defparameter *hello-gzip*
  #(31 139 8 0 79 54 222 106 2 255
    203 72 205 201 201 7 0
    134 166 16 54 5 0 0 0)
  "gzip member for the octets of \"hello\".")

(deftest stream-gunzip-p-off-abcl
  #-abcl (ok (stream-gunzip-p))
  #+abcl (ok (null (stream-gunzip-p))))

(deftest call-with-gunzip-stream-round-trips-hello
  (call-with-gunzip-stream
   *hello-gzip*
   (lambda (stream)
     (ok (equalp (read-all-octets stream) #(104 101 108 108 111))))))

(defun crc32 (octets)
  (let ((crc #xffffffff))
    (dotimes (i (length octets))
      (setf crc (logxor crc (aref octets i)))
      (dotimes (bit 8)
        (setf crc (logand #xffffffff
                          (if (logbitp 0 crc)
                              (logxor #xedb88320 (ash crc -1))
                              (ash crc -1))))))
    (logxor crc #xffffffff)))

(defun le-bytes (value width)
  (let ((out (make-array width :element-type '(unsigned-byte 8))))
    (dotimes (i width out)
      (setf (aref out i) (logand #xff (ash value (* -8 i)))))))

(defun gzip-stored (payload)
  "Gzip PAYLOAD as a single stored deflate block (no Huffman tables)."
  (let ((n (length payload)))
    (concatenate '(simple-array (unsigned-byte 8) (*))
                 #(31 139 8 0 0 0 0 0 0 255)
                 (le-bytes 1 1)
                 (le-bytes n 2)
                 (le-bytes (logxor #xffff (logand n #xffff)) 2)
                 payload
                 (le-bytes (crc32 payload) 4)
                 (le-bytes n 4))))

(defun ascii-octets (string)
  (map '(simple-array (unsigned-byte 8) (*)) #'char-code string))

(defun make-tar-bytes (name content)
  (let* ((header (make-array 512 :element-type '(unsigned-byte 8) :initial-element 0))
         (pad (mod (- 512 (mod (length content) 512)) 512)))
    (replace header (ascii-octets name))
    (replace header (ascii-octets (format nil "~11,'0o " (length content))) :start1 124)
    (setf (aref header 156) (char-code #\0))
    (concatenate '(simple-array (unsigned-byte 8) (*))
                 header
                 content
                 (make-array pad :element-type '(unsigned-byte 8) :initial-element 0)
                 (make-array 1024 :element-type '(unsigned-byte 8) :initial-element 0))))

(deftest extract-layer-from-stored-gzip
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "cl-repo-stream-extract-~a-~a/"
                                       (get-universal-time) (random 1000000))
                               (uiop:temporary-directory))))
        (payload (ascii-octets "hi\n")))
    (ensure-directories-exist dir)
    (unwind-protect
         (progn
           (extract-layer (gzip-stored (make-tar-bytes "hello.txt" payload)) dir)
           (let ((path (merge-pathnames "hello.txt" dir)))
             (ok (uiop:file-exists-p path))
             (with-open-file (in path :element-type '(unsigned-byte 8))
               (let ((buf (make-array (length payload) :element-type '(unsigned-byte 8))))
                 (ok (= (length payload) (read-sequence buf in)))
                 (ok (equalp buf payload))))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(defun %scratch-dir (tag)
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "cl-repo-~a-~a-~a/" tag (get-universal-time) (random 1000000))
                               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    dir))

(defun %file-octets (path)
  (with-open-file (in path :element-type '(unsigned-byte 8))
    (read-all-octets in)))

(deftest re-extract-leaves-an-open-file-intact
  "A sync re-extracted cl-stack-brotli while this image had libbrotli mapped.
   Writing in place (same inode) rewrote the live code pages and corrupted the
   process. A replaced file must get a new inode; whoever holds the old one
   keeps reading the old bytes."
  (let* ((dir (%scratch-dir "reextract"))
         (old (ascii-octets "old library bytes"))
         (new (ascii-octets "new library bytes!")))
    (unwind-protect
         (progn
           (extract-layer (gzip-stored (make-tar-bytes "lib.so" old)) dir)
           (with-open-file (held (merge-pathnames "lib.so" dir) :element-type '(unsigned-byte 8))
             (extract-layer (gzip-stored (make-tar-bytes "lib.so" new)) dir)
             (ok (equalp (read-all-octets held) old))
             (ok (equalp (%file-octets (merge-pathnames "lib.so" dir)) new))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

#+sbcl
(deftest re-extract-of-identical-content-keeps-the-file
  "A forced reinstall of the same version must not touch unchanged files:
   no remapping, and no new mtimes that make ASDF recompile everything."
  (let* ((dir (%scratch-dir "identical"))
         (bytes (ascii-octets "unchanged"))
         (path (merge-pathnames "same.so" dir)))
    (unwind-protect
         (progn
           (extract-layer (gzip-stored (make-tar-bytes "same.so" bytes)) dir)
           (let ((inode (sb-posix:stat-ino (sb-posix:stat path))))
             (extract-layer (gzip-stored (make-tar-bytes "same.so" bytes)) dir)
             (ok (= inode (sb-posix:stat-ino (sb-posix:stat path))))
             (ok (equalp (%file-octets path) bytes))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest atomic-write-of-a-file-without-a-type
  "LICENSE / VERSION have no pathname type: the temp's type leaked into the
   rename target, so 0.27.4 never wrote them and left LICENSE.tmp-N behind."
  (let ((dir (uiop:ensure-directory-pathname
              (format nil "~a/cl-repo-atomic-~36r/" (uiop:temporary-directory) (random (expt 36 6))))))
    (ensure-directories-exist dir)
    (unwind-protect
         (dolist (name '("LICENSE" "VERSION" "foo.lisp" "a.b.c"))
           (let ((path (merge-pathnames name dir)))
             (dolist (text '("one" "two"))
               (cl-repository-client/atomic-file:with-atomic-output-file (s path)
                 (write-string text s)))
             (ok (equal "two" (uiop:read-file-string path)) name)))
      (ok (equal '("LICENSE" "VERSION" "a.b.c" "foo.lisp")
                 (sort (mapcar #'file-namestring (uiop:directory-files dir)) #'string<))
          "no temp files left")
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(defun %file-names (dir)
  (sort (mapcar #'file-namestring (uiop:directory-files dir)) #'string<))

(deftest atomic-write-that-fails-leaves-no-temp
  "cl-repository#102: a write that does not complete must delete its temp and
   leave the target as it was."
  (let ((dir (%scratch-dir "atomic-fail")))
    (unwind-protect
         (dolist (name '("LICENSE" "foo.lisp"))
           (let ((path (merge-pathnames name dir)))
             (cl-repository-client/atomic-file:with-atomic-output-file (s path)
               (write-string "old" s))
             (ok (signals (cl-repository-client/atomic-file:with-atomic-output-file (s path)
                            (write-string "partial" s)
                            (error "disk full")))
                 name)
             (ok (equal "old" (uiop:read-file-string path)) name)))
      (ok (equal '("LICENSE" "foo.lisp") (%file-names dir)) "no temp files left")
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest temp-file-names-left-by-a-writer
  (let ((now 4003170000))
    (flet ((stale-p (name)
             (cl-repository-client/atomic-file:temp-file-name-p name :now now)))
      ;; 0.27.4-0.27.5: <file>.tmp-<time>-<n>
      (ok (stale-p "LICENSE.tmp-4003163167-377900"))
      (ok (stale-p ".gitignore.tmp-4003165824-328016"))
      (ok (stale-p "README.md.tmp-4003163167-1"))
      ;; current: .<name>.tmp-<time>-<n>[.<type>]
      (ok (stale-p ".LICENSE.tmp-4003163167-2"))
      (ok (stale-p ".foo.tmp-4003163167-2.lisp"))
      ;; a concurrent writer's temp is young: kept
      (ng (stale-p (format nil ".LICENSE.tmp-~d-3" now)))
      (ng (stale-p (format nil ".foo.tmp-~d-3.lisp" (- now 10))))
      ;; ordinary files
      (dolist (name '("LICENSE" "foo.lisp" ".gitignore" "a.tmp" "x.tmp-1" "x.tmp-a-1"
                      "tmp-4003163167-1" "notes.tmp-4003163167-1x"))
        (ng (stale-p name) name)))))

(deftest install-manifest-removes-stale-temps
  "cl-repository#102: 17 LICENSE.tmp-* sat in rove/0.10.3, and the file
   manifest recorded them as part of the system. Re-installing removes them."
  (let* ((dir (%scratch-dir "stale-temp"))
         (young (format nil ".LICENSE.tmp-~d-7" (get-universal-time))))
    (unwind-protect
         (progn
           (ensure-directories-exist (merge-pathnames "src/" dir))
           (dolist (name (list "LICENSE" "LICENSE.tmp-4003163167-377900"
                               ".gitignore.tmp-4003165824-328016" "src/main.lisp"
                               "src/.main.tmp-4003163167-9.lisp" young))
             (with-open-file (out (merge-pathnames name dir) :direction :output
                                                             :if-exists :supersede)
               (write-string "x" out)))
           (let* ((*standard-output* (make-broadcast-stream))
                  (entries (cl-repository-client/integrity:record-file-manifest dir)))
             (ok (equal (list young "LICENSE")
                        (remove ".cl-repo-manifest.sexp" (%file-names dir) :test #'string=))
                 "old temps deleted, a concurrent writer's young one kept")
             (ok (equal '("main.lisp") (%file-names (merge-pathnames "src/" dir))))
             (ng (find "LICENSE.tmp-4003163167-377900" entries :key #'car :test #'string=))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))
