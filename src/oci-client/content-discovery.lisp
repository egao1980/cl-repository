(defpackage :cl-oci-client/content-discovery
  (:use :cl)
  (:import-from :babel #:octets-to-string)
  (:import-from :cl-oci-client/registry #:registry #:registry-request)
  (:import-from :cl-oci-client/conditions #:registry-error)
  (:import-from :cl-oci/media-types #:+oci-image-index-v1+)
  (:import-from :cl-oci/serialization #:from-json)
  (:import-from :yason)
  (:export #:list-tags
           #:list-tags-paginated
           #:list-referrers))
(in-package :cl-oci-client/content-discovery)

(defun list-tags (registry repository &key (n nil) (last nil))
  "List tags for a repository. Returns (values tag-list link-header)."
  (let ((path (format nil "/v2/~a/tags/list~@[?n=~a~]~@[&last=~a~]"
                      repository n last)))
    (multiple-value-bind (body status headers)
        (registry-request registry :get path)
      (declare (ignore status))
      (let* ((json-str (etypecase body
                         (string body)
                         ((vector (unsigned-byte 8))
                          (babel:octets-to-string body :encoding :utf-8))))
             (json (yason:parse json-str)))
        (values (coerce (gethash "tags" json) 'list)
                (gethash "name" json)
                (gethash "link" headers))))))

(defun list-tags-paginated (registry repository &key (page-size 100))
  "List all tags, handling pagination. Returns a list of all tags."
  (let ((all-tags nil)
        (last nil))
    (loop
      (multiple-value-bind (tags name link)
          (list-tags registry repository :n page-size :last last)
        (declare (ignore name))
        (setf all-tags (nconc all-tags tags))
        (if (and link (plusp (length tags)))
            (setf last (car (last tags)))
            (return all-tags))))))

(defun list-referrers (registry repository digest &key artifact-type)
  "List referrers for a manifest digest. Returns an image-index object."
  (let ((path (format nil "/v2/~a/referrers/~a~@[?artifactType=~a~]"
                      repository digest artifact-type)))
    (handler-case
        (multiple-value-bind (body status headers)
            (registry-request registry :get path
                              :accept +oci-image-index-v1+)
          (declare (ignore status headers))
          (let ((json-str (etypecase body
                            (string body)
                            ((vector (unsigned-byte 8))
                             (babel:octets-to-string body :encoding :utf-8)))))
            (from-json 'image-index json-str)))
      (registry-error (e)
        (if (eql (cl-oci-client/conditions:registry-error-status e) 404)
            nil
            (error e))))))
