(defpackage :cl-repository-packager/publisher
  (:use :cl)
  (:import-from :cl-oci/runtime #:*quiet* #:*dry-run* #:msg)
  (:import-from :cl-oci-client/registry #:registry #:make-registry)
  (:import-from :cl-oci-client/push
                #:push-blob-check-and-push #:push-manifest #:mount-blob)
  (:import-from :cl-oci-client/pull #:pull-manifest)
  (:import-from :cl-oci-client/conditions #:registry-error)
  (:import-from :cl-oci/media-types
                #:+oci-image-manifest-v1+ #:+oci-image-index-v1+
                #:+oci-empty-config+ #:+cl-namespace-root-v1+
                #:+cl-system-name-anchor-v1+ #:+cl-system-name-config-v1+
                #:+cl-system-artifact-type+)
  (:import-from :cl-oci/annotations
                #:+ann-version+ #:+ann-title+ #:+ann-description+
                #:+cl-system-name+ #:+cl-alias-for+ #:+cl-provides+
                #:+cl-depends-on+ #:+cl-depends-on-versioned+)
  (:import-from :cl-oci/descriptor #:make-descriptor #:descriptor-digest)
  (:import-from :cl-oci/digest #:parse-digest #:format-digest #:compute-digest)
  (:import-from :cl-oci/manifest #:manifest)
  (:import-from :cl-repository-packager/build-matrix
                #:build-result #:build-result-index-json #:build-result-index-digest
                #:build-result-blobs #:build-result-manifests
                #:package-spec #:package-spec-name #:package-spec-version
                #:package-spec-provides #:package-spec-depends-on
                #:package-spec-description)
  (:import-from :cl-repository-packager/manifest-builder
                #:built-manifest #:built-manifest-json #:built-manifest-digest
                #:build-anchor-manifest)
  (:import-from :babel #:string-to-octets)
  (:import-from :yason)
  (:export #:publish-package
           #:publish-full-package))
(in-package :cl-repository-packager/publisher)

(defun publish-package (registry namespace tag build-result spec)
  "Publish a build result to an OCI registry with multi-system support.
   Pushes full package to primary repo, mounts blobs to secondary repos for
   each provided system name, creates system-name anchors and referrers.
   SPEC is a package-spec for metadata. NAMESPACE is the registry namespace."
  (let* ((provides (or (package-spec-provides spec)
                       (list (package-spec-name spec))))
         (canonical (first provides))
         (primary-repo (format nil "~a/~a" namespace canonical))
         (reg (etypecase registry
                (registry registry)
                (string (make-registry registry)))))
    (when *dry-run*
      (msg "~&[dry-run] Would publish ~a:~a (~d blobs, ~d manifests, provides: ~{~a~^, ~})~%"
           primary-repo tag
           (length (build-result-blobs build-result))
           (length (build-result-manifests build-result))
           provides)
      (return-from publish-package (build-result-index-digest build-result)))
    ;; 1. Push all blobs to primary repo
    (msg "~&Publishing ~a:~a...~%" primary-repo tag)
    (dolist (blob-pair (build-result-blobs build-result))
      (let ((digest (car blob-pair))
            (data (cdr blob-pair)))
        (msg "~&  Pushing blob ~a (~d bytes)..." digest (length data))
        (multiple-value-bind (loc status) (push-blob-check-and-push reg primary-repo data digest)
          (declare (ignore loc))
          (msg (if (eq status :exists) " already exists~%" " done~%")))))
    ;; 2. Push each platform manifest to primary repo
    (dolist (bm (build-result-manifests build-result))
      (let ((digest (built-manifest-digest bm)))
        (msg "~&  Pushing manifest ~a..." digest)
        (push-manifest reg primary-repo digest (built-manifest-json bm)
                       :content-type +oci-image-manifest-v1+)
        (msg " done~%")))
    ;; 3. Push image index as the tag
    (msg "~&  Pushing index as ~a:~a..." primary-repo tag)
    (push-manifest reg primary-repo tag (build-result-index-json build-result)
                   :content-type +oci-image-index-v1+)
    (msg " done~%")
    (push-manifest reg primary-repo (build-result-index-digest build-result)
                   (build-result-index-json build-result)
                   :content-type +oci-image-index-v1+)
    (msg "~&  Published primary ~a:~a~%" primary-repo tag)
    ;; 4. Mount blobs + push manifests to secondary repos
    (dolist (secondary (rest provides))
      (let ((sec-repo (format nil "~a/~a" namespace secondary)))
        (msg "~&  Mounting to ~a..." sec-repo)
        (dolist (blob-pair (build-result-blobs build-result))
          (mount-blob reg sec-repo (car blob-pair) primary-repo))
        (dolist (bm (build-result-manifests build-result))
          (push-manifest reg sec-repo (built-manifest-digest bm) (built-manifest-json bm)
                         :content-type +oci-image-manifest-v1+))
        (push-manifest reg sec-repo tag (build-result-index-json build-result)
                       :content-type +oci-image-index-v1+)
        (push-manifest reg sec-repo (build-result-index-digest build-result)
                       (build-result-index-json build-result)
                       :content-type +oci-image-index-v1+)
        (msg " done~%")))
    ;; 5. Create/update system-name anchors + referrers
    (let ((root-digest (ensure-root-anchor reg namespace)))
      (dolist (system-name provides)
        (let* ((sys-repo (format nil "~a/~a" namespace system-name))
               (anchor-digest (ensure-system-name-anchor reg sys-repo system-name canonical
                                                         (or (package-spec-version spec) tag))))
          ;; Push provider referrer into system-name repo
          (push-provider-referrer reg sys-repo anchor-digest spec tag)
          ;; Push catalog referrer into ns-catalog repo
          (push-catalog-referrer reg namespace root-digest system-name
                                 (or (package-spec-version spec) tag)))))
    (msg "~&Published ~a:~a (digest: ~a, provides: ~{~a~^, ~})~%"
         primary-repo tag (build-result-index-digest build-result) provides)
    (build-result-index-digest build-result)))

(defun publish-full-package (registry-url namespace tag build-result spec)
  "High-level publish entry point. REGISTRY-URL is a string like \"http://localhost:5050\"."
  (publish-package registry-url namespace tag build-result spec))

;;; --- Root anchor ---

(defun ensure-root-anchor (registry namespace)
  "Ensure ns-catalog:latest anchor exists. Returns its digest string."
  (let ((root-repo (format nil "~a/ns-catalog" namespace)))
    (handler-case
        (let ((obj (pull-manifest registry root-repo "latest")))
          (declare (ignore obj))
          ;; Already exists -- HEAD to get digest
          (head-manifest-digest registry root-repo "latest"))
      (registry-error ()
        ;; Create it
        (msg "~&  Creating ~a:latest root anchor...~%" root-repo)
        (multiple-value-bind (bm config-octets config-digest)
            (build-anchor-manifest +cl-namespace-root-v1+)
          (push-blob-check-and-push registry root-repo config-octets config-digest)
          (push-manifest registry root-repo "latest" (built-manifest-json bm)
                         :content-type +oci-image-manifest-v1+)
          (push-manifest registry root-repo (built-manifest-digest bm) (built-manifest-json bm)
                         :content-type +oci-image-manifest-v1+)
          (built-manifest-digest bm))))))

;;; --- System-name anchor ---

(defun ensure-system-name-anchor (registry repo system-name canonical-name version)
  "Create/update system-name anchor at REPO:latest. Returns anchor digest."
  (let* ((config-ht (make-hash-table :test 'equal))
         (_ (progn
              (setf (gethash "system-name" config-ht) system-name)
              (setf (gethash "alias-for" config-ht) canonical-name)
              (setf (gethash "version" config-ht) version)))
         (config-json (with-output-to-string (s) (yason:encode config-ht s)))
         (config-octets (babel:string-to-octets config-json :encoding :utf-8))
         (ann (make-hash-table :test 'equal)))
    (declare (ignore _))
    (setf (gethash +cl-system-name+ ann) system-name)
    (setf (gethash +cl-alias-for+ ann) canonical-name)
    (setf (gethash +ann-version+ ann) version)
    (multiple-value-bind (bm cfg-octets cfg-digest)
        (build-anchor-manifest +cl-system-name-anchor-v1+
                               :annotations ann
                               :config-data config-octets)
      (declare (ignore cfg-octets))
      (push-blob-check-and-push registry repo config-octets cfg-digest)
      (push-manifest registry repo "latest" (built-manifest-json bm)
                     :content-type +oci-image-manifest-v1+)
      (push-manifest registry repo (built-manifest-digest bm) (built-manifest-json bm)
                     :content-type +oci-image-manifest-v1+)
      (built-manifest-digest bm))))

;;; --- Referrers ---

(defun push-provider-referrer (registry repo anchor-digest spec tag)
  "Push a provider referrer into REPO with subject = anchor-digest."
  (let ((ann (make-hash-table :test 'equal))
        (subject-desc (make-descriptor :media-type +oci-image-manifest-v1+
                                       :digest (parse-digest anchor-digest)
                                       :size 0)))
    (setf (gethash +cl-system-name+ ann) (package-spec-name spec))
    (setf (gethash +ann-version+ ann) (or (package-spec-version spec) tag))
    (when (package-spec-provides spec)
      (setf (gethash +cl-provides+ ann)
            (format nil "~{~a~^,~}" (package-spec-provides spec))))
    (when (package-spec-depends-on spec)
      (setf (gethash +cl-depends-on+ ann)
            (format nil "~{~a~^,~}" (mapcar #'dep-name-string (package-spec-depends-on spec)))))
    (when (package-spec-description spec)
      (setf (gethash +ann-description+ ann) (package-spec-description spec)))
    (multiple-value-bind (bm config-octets config-digest)
        (build-anchor-manifest +cl-system-artifact-type+
                               :annotations ann
                               :subject subject-desc)
      (push-blob-check-and-push registry repo config-octets config-digest)
      (push-manifest registry repo (built-manifest-digest bm) (built-manifest-json bm)
                     :content-type +oci-image-manifest-v1+))))

(defun push-catalog-referrer (registry namespace root-digest system-name version)
  "Push a catalog referrer into ns-catalog repo."
  (let* ((root-repo (format nil "~a/ns-catalog" namespace))
         (ann (make-hash-table :test 'equal))
         (subject-desc (make-descriptor :media-type +oci-image-manifest-v1+
                                        :digest (parse-digest root-digest)
                                        :size 0)))
    (setf (gethash +cl-system-name+ ann) system-name)
    (setf (gethash +ann-version+ ann) version)
    (multiple-value-bind (bm config-octets config-digest)
        (build-anchor-manifest +cl-system-name-anchor-v1+
                               :annotations ann
                               :subject subject-desc)
      (push-blob-check-and-push registry root-repo config-octets config-digest)
      (push-manifest registry root-repo (built-manifest-digest bm) (built-manifest-json bm)
                     :content-type +oci-image-manifest-v1+))))

;;; --- Helpers ---

(defun head-manifest-digest (registry repository reference)
  "HEAD a manifest and return its digest string."
  (handler-case
      (multiple-value-bind (body status headers)
          (cl-oci-client/registry:registry-request registry :head
                            (format nil "/v2/~a/manifests/~a" repository reference)
                            :accept +oci-image-manifest-v1+)
        (declare (ignore body status))
        (gethash "docker-content-digest" headers))
    (registry-error () nil)))

(defun dep-name-string (dep)
  "Extract dependency name as string from either a string or (name . version) cons."
  (etypecase dep
    (string dep)
    (cons (car dep))
    (symbol (string-downcase (symbol-name dep)))))
