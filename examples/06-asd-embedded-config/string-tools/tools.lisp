(in-package :string-tools)

(defun words (string)
  "Split a camelCase or PascalCase string into a list of lowercase words."
  (let ((result nil)
        (current (make-string-output-stream)))
    (loop for char across string
          do (cond
               ((upper-case-p char)
                (let ((word (get-output-stream-string current)))
                  (when (plusp (length word))
                    (push word result)))
                (write-char (char-downcase char) current))
               (t (write-char char current))))
    (let ((last (get-output-stream-string current)))
      (when (plusp (length last))
        (push last result)))
    (nreverse result)))

(defun kebab-case (string)
  "Convert camelCase/PascalCase to kebab-case."
  (format nil "~{~a~^-~}" (words string)))

(defun snake-case (string)
  "Convert camelCase/PascalCase to snake_case."
  (format nil "~{~a~^_~}" (words string)))
