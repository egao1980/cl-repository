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
