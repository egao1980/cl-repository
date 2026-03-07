(defpackage :cl-repository-packager/publisher
  (:use :cl)
  (:import-from :cl-oci/runtime #:*quiet* #:*dry-run* #:msg)
  (:import-from :cl-oci-client/registry #:registry #:make-registry)
  (:import-from :cl-oci-client/push
                #:push-blob-check-and-push #:push-manifest)
  (:import-from :cl-oci/media-types #:+oci-image-manifest-v1+ #:+oci-image-index-v1+)
  (:import-from :cl-repository-packager/build-matrix
                #:build-result #:build-result-index-json #:build-result-index-digest
                #:build-result-blobs #:build-result-manifests)
  (:import-from :cl-repository-packager/manifest-builder
                #:built-manifest #:built-manifest-json #:built-manifest-digest)
  (:export #:publish-package))
(in-package :cl-repository-packager/publisher)

(defun publish-package (registry repository tag build-result)
  "Publish a build result to an OCI registry.
   Respects *dry-run* (skips actual push) and *quiet* (suppresses output)."
  (when *dry-run*
    (msg "~&[dry-run] Would publish ~a:~a (~d blobs, ~d manifests)~%"
         repository tag
         (length (build-result-blobs build-result))
         (length (build-result-manifests build-result)))
    (return-from publish-package (build-result-index-digest build-result)))
  (let ((reg (etypecase registry
               (registry registry)
               (string (make-registry registry)))))
    ;; 1. Push all blobs (with dedup check)
    (dolist (blob-pair (build-result-blobs build-result))
      (let ((digest (car blob-pair))
            (data (cdr blob-pair)))
        (msg "~&  Pushing blob ~a (~d bytes)..." digest (length data))
        (multiple-value-bind (loc status) (push-blob-check-and-push reg repository data digest)
          (declare (ignore loc))
          (msg (if (eq status :exists) " already exists~%" " done~%")))))
    ;; 2. Push each manifest
    (dolist (bm (build-result-manifests build-result))
      (let ((digest (built-manifest-digest bm)))
        (msg "~&  Pushing manifest ~a..." digest)
        (push-manifest reg repository digest (built-manifest-json bm)
                       :content-type +oci-image-manifest-v1+)
        (msg " done~%")))
    ;; 3. Push image index as the tag
    (msg "~&  Pushing index as ~a:~a..." repository tag)
    (push-manifest reg repository tag (build-result-index-json build-result)
                   :content-type +oci-image-index-v1+)
    (msg " done~%")
    ;; Also push by digest
    (push-manifest reg repository (build-result-index-digest build-result)
                   (build-result-index-json build-result)
                   :content-type +oci-image-index-v1+)
    (msg "~&Published ~a:~a (digest: ~a)~%"
         repository tag (build-result-index-digest build-result))
    (build-result-index-digest build-result)))
