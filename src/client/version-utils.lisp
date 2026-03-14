(defpackage :cl-repository-client/version-utils
  (:use :cl)
  (:export #:version<
           #:select-preferred-version))
(in-package :cl-repository-client/version-utils)

(defun split-version-segments (value)
  "Split VALUE into alphanumeric segments."
  (let ((segments nil)
        (start nil))
    (labels ((emit (end)
               (when start
                 (push (subseq value start end) segments)
                 (setf start nil)))
             (alnum-p (ch)
               (or (alpha-char-p ch) (digit-char-p ch))))
      (loop for idx from 0 below (length value)
            for ch = (char value idx)
            do (if (alnum-p ch)
                   (unless start (setf start idx))
                   (emit idx)))
      (emit (length value)))
    (nreverse segments)))

(defun segment-key (segment)
  "Build sortable key for SEGMENT.
Numeric segments sort after alpha segments and by integer value."
  (if (every #'digit-char-p segment)
      (list 1 (parse-integer segment))
      (list 0 (string-downcase segment))))

(defun compare-segments (left right)
  "Return -1, 0, 1 for LEFT vs RIGHT segment list."
  (let ((la (length left))
        (lb (length right)))
    (loop for a in left
          for b in right
          do (let ((ka (segment-key a))
                   (kb (segment-key b)))
               (unless (equal ka kb)
                 (return (if (or (< (first ka) (first kb))
                                 (and (= (first ka) (first kb))
                                      (if (= (first ka) 1)
                                          (< (second ka) (second kb))
                                          (string< (second ka) (second kb)))))
                             -1
                             1)))))
    (cond
      ((< la lb) -1)
      ((> la lb) 1)
      (t 0))))

(defun version< (left right)
  "Return T when LEFT should be ordered before RIGHT."
  (let ((cmp (compare-segments (split-version-segments left)
                               (split-version-segments right))))
    (< cmp 0)))

(defun select-preferred-version (versions)
  "Choose the best/latest version from VERSIONS."
  (when versions
    (car (last (sort (copy-list versions) #'version<)))))
