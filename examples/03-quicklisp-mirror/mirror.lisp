#!/usr/bin/env -S ros -Q --
;;; Mirror selected Quicklisp libraries to a local OCI registry.
;;; Requires: OCI registry at localhost:5050.

(asdf:load-system "cl-repository-ql-exporter")

(format t "~%=== Mirroring Quicklisp libraries to OCI ===~%~%")

(cl-repository-ql-exporter/exporter:export-dist
  "http://beta.quicklisp.org/dist/quicklisp.txt"
  "http://localhost:5050"
  :namespace "cl-systems"
  :filter "alexandria,split-sequence,cl-ppcre,babel,trivial-features,bordeaux-threads,usocket,flexi-streams"
  :incremental t)

(format t "~%=== Mirror complete ===~%")
(format t "Verify: curl -s http://localhost:5050/v2/_catalog | jq .~%")
