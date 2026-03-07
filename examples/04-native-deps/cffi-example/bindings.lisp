(in-package :cffi-example)

(define-foreign-library libfoo
  (:darwin "libfoo.dylib")
  (:unix "libfoo.so")
  (t (:default "libfoo")))

(use-foreign-library libfoo)

(defcfun ("foo_version" foo-version) :string
  "Return the version string of libfoo.")

(defcfun ("foo_add" foo-add) :int
  "Add two integers via libfoo."
  (a :int)
  (b :int))
