(defpackage :cl-repository/tests/integration
  (:use :cl :rove)
  (:import-from :cl-oci-client/registry #:make-registry #:ping)
  (:import-from :cl-oci-client/push #:push-blob-monolithic #:push-manifest)
  (:import-from :cl-oci-client/pull #:pull-manifest #:pull-blob #:manifest-exists-p #:blob-exists-p)
  (:import-from :cl-oci-client/content-discovery #:list-tags)
  (:import-from :cl-oci/digest #:compute-digest #:format-digest)
  (:import-from :cl-oci/serialization #:to-json-string #:from-json)
  (:import-from :cl-oci/media-types #:+oci-image-manifest-v1+ #:+oci-image-index-v1+
                #:+oci-image-layer-tar-gzip+ #:+oci-image-config-v1+)
  (:import-from :cl-oci/manifest #:manifest #:manifest-config #:manifest-layers #:manifest-schema-version)
  (:import-from :cl-oci/image-index #:image-index #:image-index-manifests)
  (:import-from :cl-oci/descriptor #:descriptor-media-type #:descriptor-digest #:descriptor-size)
  (:import-from :cl-oci/digest #:digest-hex)
  (:import-from :cl-repository-packager/layer-builder
                #:build-layer-from-directory #:layer-result #:layer-result-data
                #:layer-result-digest #:layer-result-size #:layer-result-role)
  (:import-from :cl-repository-packager/manifest-builder
                #:build-config-blob #:build-manifest-for-layers #:build-image-index
                #:built-manifest #:built-manifest-json #:built-manifest-digest
                #:built-manifest-descriptor)
  (:import-from :cl-repository-packager/build-matrix
                #:package-spec #:package-spec-name #:package-spec-version #:package-spec-overlays
                #:build-package #:build-result
                #:build-result-index-json #:build-result-index-digest
                #:build-result-blobs #:build-result-manifests
                #:build-overlay #:overlay-result)
  (:import-from :cl-repository-packager/asdf-plugin #:auto-package-spec)
  (:import-from :cl-repository-packager/publisher #:publish-package #:publish-overlay
                #:fetch-source-layer-info)
  (:import-from :cl-repository-client/installer #:install-system #:install-result-path)
  (:import-from :cl-oci/config #:+role-source+)
  (:import-from :babel #:string-to-octets))
(in-package :cl-repository/tests/integration)

(defparameter *registry-url* "http://localhost:5050")
(defparameter *test-namespace* "cl-repo-test")
