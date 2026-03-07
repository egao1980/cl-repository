(in-package :cl-repository/tests/integration)

(deftest ping-registry
  (testing "Registry responds to /v2/"
    (let ((reg (make-registry *registry-url*)))
      (ok (ping reg)))))

(deftest push-and-pull-blob
  (testing "Push a blob and pull it back"
    (let* ((reg (make-registry *registry-url*))
           (repo (format nil "~a/blob-test" *test-namespace*))
           (data (babel:string-to-octets "hello OCI world" :encoding :utf-8))
           (digest (format-digest (compute-digest data))))
      (push-blob-monolithic reg repo data digest)
      (ok (blob-exists-p reg repo digest))
      (let ((pulled (pull-blob reg repo digest)))
        (ok (equalp data pulled))))))

(deftest push-and-pull-manifest
  (testing "Push a minimal manifest and pull it back"
    (let* ((reg (make-registry *registry-url*))
           (repo (format nil "~a/manifest-test" *test-namespace*))
           (config-data (babel:string-to-octets "{}" :encoding :utf-8))
           (config-digest (format-digest (compute-digest config-data)))
           (layer-data (babel:string-to-octets "fake-layer-data" :encoding :utf-8))
           (layer-digest (format-digest (compute-digest layer-data))))
      ;; Push blobs first
      (push-blob-monolithic reg repo config-data config-digest)
      (push-blob-monolithic reg repo layer-data layer-digest)
      ;; Build a minimal manifest JSON
      (multiple-value-bind (cfg-octets cfg-digest cfg-size)
          (build-config-blob "manifest-test" :version "0.1.0")
        ;; Push config blob
        (push-blob-monolithic reg repo cfg-octets cfg-digest)
        ;; Build manifest with no actual layers (just config)
        (let* ((bm (build-manifest-for-layers cfg-octets cfg-digest cfg-size nil))
               (tag "test-v1"))
          (push-manifest reg repo tag (built-manifest-json bm))
          ;; Verify it exists
          (ok (manifest-exists-p reg repo tag))
          ;; Pull and verify structure
          (let ((m (pull-manifest reg repo tag)))
            (ok (typep m 'manifest))
            (ok (= (manifest-schema-version m) 2))))))))

(deftest tag-discovery
  (testing "Tags are discoverable after push"
    (let* ((reg (make-registry *registry-url*))
           (repo (format nil "~a/tag-test" *test-namespace*)))
      ;; Push a manifest with a known tag
      (multiple-value-bind (cfg-octets cfg-digest cfg-size)
          (build-config-blob "tag-test" :version "1.0.0")
        (push-blob-monolithic reg repo cfg-octets cfg-digest)
        (let ((bm (build-manifest-for-layers cfg-octets cfg-digest cfg-size nil)))
          (push-manifest reg repo "v1.0.0" (built-manifest-json bm))
          (push-manifest reg repo "latest" (built-manifest-json bm))))
      ;; List tags
      (let ((tags (list-tags reg repo)))
        (ok (listp tags))
        (ok (member "v1.0.0" tags :test #'string=))
        (ok (member "latest" tags :test #'string=))))))
