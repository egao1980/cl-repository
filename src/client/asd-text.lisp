(defpackage :cl-repository-client/asd-text
  (:use :cl)
  (:export #:asd-edit-error
           #:defsystem-spans
           #:find-defsystem-span
           #:plist-value-span
           #:splice
           #:print-value-at
           #:line-column))
(in-package :cl-repository-client/asd-text)

;;; Text-level .asd edits. The reader tells what a form holds; these scans
;;; tell where it is, so a command can replace one value and leave comments,
;;; reader conditionals and layout byte for byte. Strings, character literals,
;;; ; comments and #| |# are skipped, so a keyword inside a docstring is never
;;; taken for a real one.

(define-condition asd-edit-error (error)
  ((message :initarg :message :reader asd-edit-error-message))
  (:report (lambda (c s) (write-string (asd-edit-error-message c) s))))

(defun %fail (fmt &rest args)
  (error 'asd-edit-error :message (apply #'format nil fmt args)))

(defun %skip (text i)
  "Index after whitespace and comments from I."
  (loop
    (cond ((>= i (length text)) (return i))
          ((member (char text i) '(#\Space #\Tab #\Newline #\Return #\Page)) (incf i))
          ((char= (char text i) #\;)
           (setf i (or (position #\Newline text :start i) (length text))))
          ((and (char= (char text i) #\#) (< (1+ i) (length text)) (char= (char text (1+ i)) #\|))
           (setf i (+ 2 (or (search "|#" text :start2 (+ i 2)) (%fail "unclosed #| in .asd")))))
          (t (return i)))))

(defun %string-end (text i)
  "I at #\\\" → index after the closing quote."
  (loop for j from (1+ i) below (length text)
        do (case (char text j)
             (#\\ (incf j))
             (#\" (return-from %string-end (1+ j))))
        finally (%fail "unclosed string in .asd")))

(defun %token-end (text i)
  (or (position-if (lambda (c) (member c '(#\Space #\Tab #\Newline #\Return #\( #\) #\" #\;)))
                   text :start i)
      (length text)))

(defun %form-end (text i)
  "I at #\\( → index after the matching #\\)."
  (let ((depth 0))
    (loop
      (setf i (%skip text i))
      (when (>= i (length text)) (%fail "unbalanced parentheses in .asd"))
      (let ((c (char text i)))
        (cond ((char= c #\() (incf depth) (incf i))
              ((char= c #\)) (decf depth) (incf i) (when (zerop depth) (return i)))
              ((char= c #\") (setf i (%string-end text i)))
              ((and (char= c #\#) (< (+ i 2) (length text)) (char= (char text (1+ i)) #\\))
               (setf i (%token-end text (+ i 3))))
              (t (setf i (max (1+ i) (%token-end text i)))))))))

(defun %element-end (text i)
  "End of the element starting at I: a list, string, character, token, with
any ' ` #' , ,@ prefixes."
  (loop while (and (< i (length text))
                   (or (member (char text i) '(#\' #\` #\,))
                       (and (char= (char text i) #\#) (< (1+ i) (length text))
                            (member (char text (1+ i)) '(#\' #\+ #\-)))
                       (char= (char text i) #\@)))
        do (cond ((and (char= (char text i) #\#) (member (char text (1+ i)) '(#\+ #\-)))
                  ;; #+feature form: the feature expression, then the form
                  (setf i (%skip text (%element-end text (+ i 2)))))
                 ((char= (char text i) #\#) (incf i 2))
                 (t (incf i))))
  (cond ((>= i (length text)) i)
        ((char= (char text i) #\() (%form-end text i))
        ((char= (char text i) #\") (%string-end text i))
        ((and (char= (char text i) #\#) (< (+ i 2) (length text)) (char= (char text (1+ i)) #\\))
         (%token-end text (+ i 3)))
        (t (%token-end text i))))

(defun %name-token (token)
  (string-downcase (string-trim "\"" (subseq token (1+ (or (position #\: token :from-end t) -1))))))

(defun defsystem-spans (text)
  "→ list of (start end name-end) for every top-level defsystem form in TEXT."
  (let ((i 0) (spans '()))
    (loop
      (setf i (%skip text i))
      (when (>= i (length text)) (return (nreverse spans)))
      (if (char/= (char text i) #\()
          (setf i (max (1+ i) (%element-end text i)))
          (let* ((end (%form-end text i))
                 (head-start (%skip text (1+ i)))
                 (head-end (%token-end text head-start))
                 (head (string-downcase (subseq text head-start head-end))))
            (when (member head '("defsystem" "asdf:defsystem" "asdf/defsystem:defsystem")
                          :test #'string=)
              (push (list i end (%element-end text (%skip text head-end))) spans))
            (setf i end))))))

(defun find-defsystem-span (text name)
  "→ (values start end name-end) of the top-level (defsystem NAME ...) form
in TEXT, or NIL."
  (let ((i 0))
    (loop
      (setf i (%skip text i))
      (when (>= i (length text)) (return nil))
      (if (char/= (char text i) #\()
          (setf i (max (1+ i) (%element-end text i)))
          (let* ((end (%form-end text i))
                 (head-start (%skip text (1+ i)))
                 (head-end (%token-end text head-start))
                 (head (string-downcase (subseq text head-start head-end))))
            (when (member head '("defsystem" "asdf:defsystem" "asdf/defsystem:defsystem")
                          :test #'string=)
              (let* ((n-start (%skip text head-end))
                     (n-end (%element-end text n-start)))
                (when (string= (%name-token (subseq text n-start n-end)) name)
                  (return (values i end n-end)))))
            (setf i end))))))

(defun plist-value-span (text start end key &key (skip 0))
  "In the list at START..END, after SKIP leading elements, the value of the
keyword KEY (a string like \":version\"). → (values value-start value-end
key-start), or NIL."
  (let ((i (%skip text (1+ start))))
    (dotimes (n skip) (setf i (%skip text (%element-end text i))))
    (loop while (< i (1- end))
          do (let* ((k-end (%element-end text i))
                    (k (string-downcase (subseq text i k-end)))
                    (v-start (%skip text k-end))
                    (v-end (if (>= v-start (1- end)) v-start (%element-end text v-start))))
               (when (string= k (string-downcase key))
                 (return-from plist-value-span (values v-start v-end i)))
               (setf i (%skip text v-end))))
    nil))

(defun splice (text start end replacement)
  (concatenate 'string (subseq text 0 start) replacement (subseq text end)))

(defun line-column (text i)
  "Column of index I in TEXT."
  (- i (1+ (or (position #\Newline text :end i :from-end t) -1))))

(defun print-value-at (value column)
  "VALUE printed readably for an .asd (lower case, ASDF-USER), continuation
lines indented to COLUMN so the result sits where the old value was."
  (let ((printed (let ((*package* (or (find-package :asdf-user) *package*))
                       (*print-case* :downcase)
                       (*print-pretty* t)
                       (*print-right-margin* (max 60 (- 100 column)))
                       (*print-readably* nil))
                   (prin1-to-string value)))
        (pad (make-string column :initial-element #\Space)))
    (with-output-to-string (out)
      (loop for c across printed
            do (write-char c out)
               (when (char= c #\Newline) (write-string pad out))))))
