(defpackage :cl-repository-client/source-policy
  (:use :cl)
  (:import-from :cl-repository-client/config #:config-value)
  (:export #:*source-policy*
           #:*source-rules*
           #:*default-source*
           #:source-for
           #:system-denied-p
           #:oci-allowed-p
           #:ql-allowed-p
           #:registry-allowed-p
           #:ql-allowed-by-rules-p
           #:apply-source-config
           #:call-with-policy-overrides))
(in-package :cl-repository-client/source-policy)

(defvar *source-policy* (make-hash-table :test 'equal)
  "System-name -> source policy keyword.
   :oci  — only OCI registries
   :ql   — only Quicklisp
   :any  — OCI first, QL fallback (default)
   :deny — refuse from all sources")

(defvar *source-rules* nil
  "Ordered list of source rules. Each rule is one of:
   (:deny NAME)                     — block system from ALL sources
   (:deny NAME :from REGISTRY-URL)  — block system from specific registry
   (:allow NAME :from REGISTRY-URL) — ONLY allow system from this registry (whitelist)
   (:allow NAME :from :ql)          — ONLY allow system from Quicklisp")

(defvar *default-source* :any
  "Default source policy for systems not in *source-policy* or *source-rules*.")

;;; Utilities

(defun copy-hash-table (ht)
  (let ((new (make-hash-table :test (hash-table-test ht)
                              :size (hash-table-count ht))))
    (maphash (lambda (k v) (setf (gethash k new) v)) ht)
    new))

;;; Rule querying

(defun rule-action (rule)
  (first rule))

(defun rule-name (rule)
  (second rule))

(defun rule-from (rule)
  (getf (cddr rule) :from))

(defun rules-for (name action)
  "Return all rules matching NAME with given ACTION (:deny or :allow)."
  (remove-if-not (lambda (rule)
                   (and (eq (rule-action rule) action)
                        (string-equal (rule-name rule) name)))
                 *source-rules*))

(defun registry-host (url)
  "Extract the host[:port] authority from a registry URL string, lowercased.
   \"https://ghcr.io/v2\" -> \"ghcr.io\", \"localhost:5050/x\" -> \"localhost:5050\"."
  (let* ((no-scheme (let ((pos (search "://" url)))
                      (if pos (subseq url (+ pos 3)) url)))
         (end (or (position #\/ no-scheme) (length no-scheme))))
    (string-downcase (subseq no-scheme 0 end))))

(defun registry-matches-p (registry-url rule-from)
  "Check if REGISTRY-URL matches a rule's :from value.
   String rules match on the URL host (exact host[:port], or bare host
   matching any port) -- substring matching would let \"evil-ghcr.io.x\"
   satisfy a \"ghcr.io\" rule."
  (cond
    ((null rule-from) t)
    ((eq rule-from :ql) nil)
    ((stringp rule-from)
     (let ((host (registry-host registry-url))
           (rule-host (registry-host rule-from)))
       (or (string= host rule-host)
           ;; Rule without a port matches the same host on any port.
           (let ((colon (position #\: host)))
             (and colon
                  (not (find #\: rule-host))
                  (string= host rule-host :end1 colon))))))
    (t nil)))

;;; Public API

(defun source-for (system-name)
  "Return effective source policy for SYSTEM-NAME.
   Checks *source-rules*, then *source-policy*, then *default-source*."
  (let ((name (string-downcase system-name)))
    ;; Blanket :deny rule?
    (when (some (lambda (r) (and (eq (rule-action r) :deny)
                                 (string-equal (rule-name r) name)
                                 (null (rule-from r))))
                *source-rules*)
      (return-from source-for :deny))
    ;; Hash-table policy
    (let ((policy (gethash name *source-policy*)))
      (or policy *default-source*))))

(defun system-denied-p (system-name)
  "T if SYSTEM-NAME has a blanket :deny (no :from) in rules or :deny in policy."
  (eq (source-for system-name) :deny))

(defun oci-allowed-p (system-name)
  "T if OCI registries may be searched for SYSTEM-NAME."
  (member (source-for system-name) '(:oci :any)))

(defun ql-allowed-p (system-name)
  "T if Quicklisp may be used for SYSTEM-NAME."
  (and (member (source-for system-name) '(:ql :any))
       (ql-allowed-by-rules-p system-name)))

(defun registry-allowed-p (system-name registry-url)
  "T if SYSTEM-NAME may be fetched from REGISTRY-URL given current rules.
   When :allow rules exist for the system, only those registries are permitted.
   When :deny rules with :from exist, those registries are excluded."
  (let* ((name (string-downcase system-name))
         (allow-rules (rules-for name :allow))
         (deny-rules (remove-if-not (lambda (r) (rule-from r))
                                    (rules-for name :deny))))
    (cond
      ;; Whitelist mode: only explicitly allowed registries
      ((some (lambda (r) (not (eq (rule-from r) :ql))) allow-rules)
       (some (lambda (r) (registry-matches-p registry-url (rule-from r)))
             (remove-if (lambda (r) (eq (rule-from r) :ql)) allow-rules)))
      ;; Blacklist mode: exclude denied registries
      (deny-rules
       (not (some (lambda (r) (registry-matches-p registry-url (rule-from r)))
                  deny-rules)))
      ;; No registry-specific rules — defer to source-for
      (t (oci-allowed-p system-name)))))

(defun ql-allowed-by-rules-p (system-name)
  "T if Quicklisp is a valid source for SYSTEM-NAME given *source-rules*.
   Blocked when :allow rules exist but none allow :ql."
  (let* ((name (string-downcase system-name))
         (allow-rules (rules-for name :allow)))
    (if allow-rules
        (some (lambda (r) (eq (rule-from r) :ql)) allow-rules)
        t)))

;;; Loading from config

(defun apply-source-config (config)
  "Apply source-related keys from a config plist to runtime variables."
  (let ((default (config-value config :default-source)))
    (when default
      (setf *default-source* default)))
  (let ((sources (config-value config :sources)))
    (dolist (entry sources)
      (when (and (listp entry) (>= (length entry) 2))
        (setf (gethash (string-downcase (first entry)) *source-policy*)
              (second entry)))))
  (let ((rules (config-value config :rules)))
    (when rules
      (setf *source-rules* (append rules *source-rules*)))))

;;; Scoped overrides for load-system keyword args

(defun call-with-policy-overrides (sources deny allow default-source thunk)
  "Call THUNK with temporary source policy overrides.
   Restores original state on exit."
  (let ((saved-policy (copy-hash-table *source-policy*))
        (saved-rules (copy-list *source-rules*))
        (saved-default *default-source*))
    (unwind-protect
         (progn
           (when default-source
             (setf *default-source* default-source))
           (dolist (s sources)
             (when (and (listp s) (>= (length s) 2))
               (setf (gethash (string-downcase (first s)) *source-policy*)
                     (second s))))
           (dolist (d deny)
             (etypecase d
               (string (push (list :deny d) *source-rules*))
               (cons (push d *source-rules*))))
           (dolist (a allow)
             (when (consp a)
               (push a *source-rules*)))
           (funcall thunk))
      (setf *source-policy* saved-policy
            *source-rules* saved-rules
            *default-source* saved-default))))
