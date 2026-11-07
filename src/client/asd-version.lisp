(defpackage :cl-repository-client/asd-version
  (:use :cl)
  (:import-from :cl-oci/runtime #:msg)
  (:import-from :cl-repository-client/project #:discover-project-system)
  (:import-from :cl-repository-client/asd-text
                #:find-defsystem-span #:plist-value-span #:splice)
  (:export #:cmd-version
           #:bump-version
           #:read-asd-version
           #:write-asd-version
           #:version-error))
(in-package :cl-repository-client/asd-version)

;;; `cl-repo version [<new> | --bump major|minor|patch|revision]`: read or
;;; rewrite a system's :version in its .asd. Only the version string changes;
;;; comments, layout and every other form stay byte for byte, so publish
;;; workflows need no sed or sync script.

(define-condition version-error (error)
  ((message :initarg :message :reader version-error-message))
  (:report (lambda (c s) (write-string (version-error-message c) s))))

(defun %fail (fmt &rest args)
  (error 'version-error :message (apply #'format nil fmt args)))

(defun %parts (version)
  "\"1.2.3\" → (1 2 3). Signals VERSION-ERROR unless VERSION is ASDF's
dot-separated non-negative integers."
  (let ((parts (uiop:split-string version :separator ".")))
    (unless (and parts
                 (every (lambda (p) (and (plusp (length p)) (every #'digit-char-p p))) parts))
      (%fail "~S is not a version (dot-separated non-negative integers)" version))
    (mapcar #'parse-integer parts)))

(defun %join (parts) (format nil "~{~D~^.~}" parts))

(defun bump-version (version part)
  "VERSION with PART incremented (:major :minor :patch :revision); lower parts
reset. :revision is the 4th part, the package revision on an upstream release
(3.5.9 → 3.5.9.1 → 3.5.9.2)."
  (let* ((parts (%parts version))
         (index (ecase part (:major 0) (:minor 1) (:patch 2) (:revision 3)))
         (padded (append parts (make-list (max 0 (- (1+ index) (length parts))) :initial-element 0))))
    (incf (nth index padded))
    (%join (append (subseq padded 0 (1+ index))
                   ;; keep the shape: 1.2.3 bumps to 1.3.0, not 1.3
                   (make-list (max 0 (- (min (length parts) 3) (1+ index))) :initial-element 0)))))

(defun %asd-path (directory system)
  (let* ((dir (uiop:ensure-directory-pathname directory))
         (name (or system (discover-project-system dir)
                   (%fail "no .asd in ~A" (namestring dir))))
         (primary (asdf:primary-system-name name))
         (path (merge-pathnames (format nil "~A.asd" primary) dir)))
    (unless (probe-file path) (%fail "no ~A.asd in ~A" primary (namestring dir)))
    (values path (string-downcase name))))

(defun read-asd-version (directory &key system)
  "→ (values version path system-name). VERSION is NIL when the defsystem has
no :version; a non-literal :version (e.g. (:read-file-form ...)) signals."
  (multiple-value-bind (path name) (%asd-path directory system)
    (let ((text (uiop:read-file-string path)))
      (multiple-value-bind (start end) (find-defsystem-span text name)
        (unless start (%fail "no (defsystem ~S ...) in ~A" name (namestring path)))
        (multiple-value-bind (v-start v-end) (plist-value-span text start end ":version" :skip 2)
          (values (when v-start
                    (let ((v (subseq text v-start v-end)))
                      (unless (char= (char v 0) #\")
                        (%fail "~A: :version is ~A, not a literal string; edit it by hand" name v))
                      (subseq v 1 (1- (length v)))))
                  path name))))))

(defun write-asd-version (directory new &key system)
  "Set SYSTEM's :version to NEW in its .asd, changing nothing else. Inserts
:version after the name when there is none. → (values old new path)."
  (%parts new)
  (multiple-value-bind (old path name) (read-asd-version directory :system system)
    (let ((text (uiop:read-file-string path)))
      (multiple-value-bind (start end name-end) (find-defsystem-span text name)
        (multiple-value-bind (v-start v-end) (plist-value-span text start end ":version" :skip 2)
          (let ((updated (if v-start
                             (splice text v-start v-end (format nil "~S" new))
                             (splice text name-end name-end (format nil "~%  :version ~S" new)))))
            (with-open-file (out path :direction :output :if-exists :supersede
                                      :external-format :utf-8)
              (write-string updated out))
            (values old new path)))))))

(defun cmd-version (directory &key set bump system)
  "Print the project's version; with SET or BUMP (\"major\" \"minor\" \"patch\"
\"revision\"), rewrite it first. → the version now in the .asd."
  (when (and set bump) (%fail "give a version or --bump, not both"))
  (if (or set bump)
      (multiple-value-bind (old) (read-asd-version directory :system system)
        (let ((new (or set
                       (bump-version (or old (%fail "no :version to bump; give one"))
                                     (or (find bump '(:major :minor :patch :revision) :test #'string-equal)
                                         (%fail "--bump takes major, minor, patch or revision, not ~A" bump))))))
          (multiple-value-bind (old new path) (write-asd-version directory new :system system)
            (msg "~&~A: ~A → ~A~%" (file-namestring path) (or old "(none)") new)
            new)))
      (let ((v (read-asd-version directory :system system)))
        (format t "~A~%" (or v ""))
        v)))
