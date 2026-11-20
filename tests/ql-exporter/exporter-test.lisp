(defpackage :cl-repository-ql-exporter/tests/exporter-test
  (:use :cl :rove)
  (:import-from :cl-repository-ql-exporter/exporter #:export-summary))
(in-package :cl-repository-ql-exporter/tests/exporter-test)

(deftest export-summary-counts-local-installs-apart
  "cl-repository#108: a local-only install was reported as pushed."
  (ok (string= (export-summary 0 1 2381 0 2382)
               "Export complete: 0 pushed, 1 installed locally (unpublished), 2381 skipped, 0 failed (of 2382 total)"))
  (ok (string= (export-summary 3 0 1 1 5)
               "Export complete: 3 pushed, 1 skipped, 1 failed (of 5 total)")))
