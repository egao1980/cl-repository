(defpackage :cl-repository-client/tests/project-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/project
                #:discover-project-system
                #:read-ci-env
                #:plan-sync-systems))
(in-package :cl-repository-client/tests/project-test)

(defvar *env-spec*
  '("HTTP_ASYNC_EVENT_BACKEND"
    :default "libuv"
    :systems (("libuv" "event-backend-libuv")
              ("libev" "event-backend-libev"))
    :install t))

(defun make-temp-dir (&optional leaf)
  (let ((dir (merge-pathnames
              (format nil "cl-repo-project-~a-~a/~@[~a/~]"
                      (get-universal-time)
                      (random 1000000000 (make-random-state t))
                      leaf)
              (uiop:temporary-directory))))
    (ensure-directories-exist dir)
    dir))

(defun write-text (path text)
  (with-open-file (out path :direction :output :if-exists :supersede :if-does-not-exist :create)
    (write-string text out)
    path))

(defun set-env (name value)
  "Set NAME to VALUE. NIL unsets it; UIOP's SETF of GETENV does not accept NIL here."
  (if value
      (setf (uiop:getenv name) value)
      #+sbcl
      (progn
        (require :sb-posix)
        (sb-posix:unsetenv name))
      #-sbcl
      (setf (uiop:getenv name) "")))

(defun call-with-env (pairs thunk)
  (let ((saved (mapcar (lambda (pair) (cons (first pair) (uiop:getenv (first pair)))) pairs)))
    (unwind-protect
         (progn
           (dolist (pair pairs)
             (set-env (first pair) (second pair)))
           (funcall thunk))
      (dolist (pair saved)
        (set-env (car pair) (cdr pair))))))

(defmacro with-env (pairs &body body)
  `(call-with-env ,pairs (lambda () ,@body)))

(deftest plan-vanilla-depends-on
  (let ((dir (make-temp-dir)))
    (unwind-protect
         (progn
          (write-text (merge-pathnames "vanilla-app.asd" dir)
                      "(defsystem \"vanilla-app\"
                         :depends-on (\"alexandria\" (:version \"http-protocol\" \"0.3.9\"))
                         :components nil)")
           (let ((plan (plan-sync-systems dir)))
             (ok (equal "vanilla-app" (getf plan :system)))
             (ok (equal '("alexandria" ("http-protocol" . "0.3.9"))
                        (getf plan :depends-on)))
             (ok (null (getf plan :install)))
             (ok (null (getf plan :qlot)))))
      (uiop:delete-directory-tree dir :validate t))))

(deftest plan-depends-on-version-forms
  (let ((dir (make-temp-dir)))
    (unwind-protect
         (progn
          (write-text (merge-pathnames "shaped.asd" dir)
                      "(defsystem \"shaped\"
                         :depends-on (\"a\" (:version \"b\" \"1.2\") (\"c\" :version \"2\"))
                         :components nil)")
           (ok (equal '("a" ("b" . "1.2") ("c" . "2"))
                      (getf (plan-sync-systems dir) :depends-on))))
      (uiop:delete-directory-tree dir :validate t))))

(deftest plan-ci-env-default-install
  (let ((dir (make-temp-dir)))
    (unwind-protect
         (with-env '(("HTTP_ASYNC_EVENT_BACKEND" nil))
           (write-text (merge-pathnames "env-app.asd" dir)
                       "(defsystem \"env-app\"
                          :properties (:cl-repo (:ci (:env ((\"HTTP_ASYNC_EVENT_BACKEND\"
                                                             :default \"libuv\"
                                                             :systems ((\"libuv\" \"event-backend-libuv\")
                                                                       (\"libev\" \"event-backend-libev\"))
                                                             :install t)))))
                          :components nil)")
           (let ((plan (plan-sync-systems dir)))
             (ok (equal "env-app" (getf plan :system)))
             (ok (equal '("event-backend-libuv") (getf plan :install)))
             (ok (null (getf plan :load-before-test)))))
      (uiop:delete-directory-tree dir :validate t))))

(deftest read-ci-env-selects-value-and-load-flag
  (with-env '(("HTTP_ASYNC_EVENT_BACKEND" "libev"))
    (multiple-value-bind (install load)
        (read-ci-env (list :env (list (append *env-spec* (list :load-before-test t)))))
      (ok (equal '("event-backend-libev") install))
      (ok (equal '("event-backend-libev") load)))))

(deftest read-ci-env-unknown-value
  (with-env '(("HTTP_ASYNC_EVENT_BACKEND" "libevent"))
    (ok (handler-case
            (progn
              (read-ci-env (list :env (list *env-spec*)))
              nil)
          (simple-error (condition)
            (let ((text (princ-to-string condition)))
              (and (search "libevent" text)
                   (search "HTTP_ASYNC_EVENT_BACKEND" text)
                   t)))))))

(deftest plan-qlot-from-qlfile
  (let ((dir (make-temp-dir)))
    (unwind-protect
         (progn
           (write-text (merge-pathnames "qlot-app.asd" dir)
                       "(defsystem \"qlot-app\" :depends-on (\"alexandria\") :components nil)")
           (write-text (merge-pathnames "qlfile" dir)
                       "ql alexandria
github egao1980/foo v1
")
           (let ((qlot (getf (plan-sync-systems dir) :qlot)))
             (ok (= 2 (length qlot)))
             (ok (equal '(:kind :ql :name "alexandria" :ref nil) (first qlot)))
             (ok (equal '(:kind :github :name "egao1980/foo" :ref "v1") (second qlot)))))
      (uiop:delete-directory-tree dir :validate t))))

(deftest plan-qlot-lock-wins-and-parses-lines
  (let ((dir (make-temp-dir)))
    (unwind-protect
         (progn
           (write-text (merge-pathnames "qlot-app.asd" dir)
                       "(defsystem \"qlot-app\" :components nil)")
           (write-text (merge-pathnames "qlfile" dir) "ql alexandria")
           (write-text (merge-pathnames "qlfile.lock" dir)
                       "# comment

git https://example.test/foo.git abc
http hunchentoot https://example.test/h.tgz
local ../vendor/bar
dist ultralisp http://dist.ultralisp.org/
bare-system
")
           (ok (equal '((:kind :git :name "https://example.test/foo.git" :ref "abc")
                        (:kind :http :name "hunchentoot" :ref "https://example.test/h.tgz")
                        (:kind :local :name "../vendor/bar" :ref nil)
                        (:kind :dist :name "ultralisp" :ref "http://dist.ultralisp.org/")
                        (:kind :bare :name "bare-system" :ref nil))
                      (getf (plan-sync-systems dir) :qlot))))
      (uiop:delete-directory-tree dir :validate t))))

(deftest discover-directory-name-and-ambiguous
  (let ((dir (make-temp-dir "chosen")))
    (unwind-protect
         (progn
           (write-text (merge-pathnames "chosen.asd" dir)
                       "(defsystem \"chosen\" :components nil)
(defsystem \"chosen/tests\" :components nil)
(defsystem \"chosen-tests\" :components nil)")
           (write-text (merge-pathnames "other.asd" dir)
                       "(defsystem \"other\" :components nil)")
           (ok (equal "chosen" (discover-project-system dir)))
           (ok (equal "chosen" (getf (plan-sync-systems dir) :system))))
      (uiop:delete-directory-tree dir :validate t)))
  (let ((dir (make-temp-dir "holder")))
    (unwind-protect
         (progn
           (write-text (merge-pathnames "alpha.asd" dir) "(defsystem \"alpha\" :components nil)")
           (write-text (merge-pathnames "beta.asd" dir) "(defsystem \"beta\" :components nil)")
           (ok (handler-case
                   (progn (discover-project-system dir) nil)
                 (simple-error (condition)
                   (let ((text (princ-to-string condition)))
                     (and (search "alpha" text) (search "beta" text) t))))))
      (uiop:delete-directory-tree dir :validate t))))
