#!/usr/bin/env -S ros -Q --
;;; Basic cl-repo usage demo.
;;; Requires: OCI registry at localhost:5050 with pre-exported libraries.
;;; See README.md for setup instructions.

(asdf:load-system "cl-repository-client")

;;; --- Configure ---

(cl-repo:add-registry "http://localhost:5050" :namespace "cl-systems")

(format t "~%Registries: ~s~%~%" cl-repo:*registries*)

;;; --- Load systems ---

(format t "--- Loading alexandria ---~%")
(cl-repo:load-system "alexandria")
(format t "  (alexandria:flatten '(1 (2 3))) => ~s~%~%"
        (alexandria:flatten '(1 (2 3))))

(format t "--- Loading multiple systems ---~%")
(cl-repo:load-system '("split-sequence" "cl-ppcre"))
(format t "  (split-sequence:split-sequence #\\Space \"a b c\") => ~s~%"
        (multiple-value-list (split-sequence:split-sequence #\Space "a b c")))
(format t "  (cl-ppcre:scan \"\\\\d+\" \"abc42\") => ~s~%~%"
        (multiple-value-list (cl-ppcre:scan "\\d+" "abc42")))

;;; --- List installed ---

(format t "--- Installed systems ---~%")
(cl-repo:cmd-list)

(format t "~%Done.~%")
