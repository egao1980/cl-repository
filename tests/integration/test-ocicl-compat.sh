#!/usr/bin/env bash
# Integration test: publish a cl-repo package and install it with ocicl.
# Requires: docker, openssl, ocicl, roswell+qlot
set -euo pipefail

CERT_DIR="/tmp/cl-repo-test-certs"
CONTAINER_NAME="cl-repo-tls-registry"
PORT=5443
NAMESPACE="cl-repo-test"
SYSTEM_NAME="hello-test"
VERSION="0.1.0"
WORKDIR=""

cleanup() {
  echo "--- cleanup ---"
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  rm -rf "$CERT_DIR" /tmp/test-publish.lisp
  [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

# 1. Generate self-signed certificate
echo "==> Generating self-signed TLS certificate"
mkdir -p "$CERT_DIR"
openssl req -x509 -nodes -sha256 -newkey rsa:2048 \
  -keyout "$CERT_DIR/domain.key" -out "$CERT_DIR/domain.crt" \
  -days 1 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null

# 2. Start TLS registry
echo "==> Starting TLS registry on port $PORT"
docker run -d --rm \
  -p "$PORT:$PORT" \
  -v "$CERT_DIR:/certs:ro" \
  -e "REGISTRY_HTTP_ADDR=0.0.0.0:$PORT" \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/domain.crt \
  -e REGISTRY_HTTP_TLS_KEY=/certs/domain.key \
  --name "$CONTAINER_NAME" \
  registry:2

echo "==> Waiting for registry..."
for i in $(seq 1 30); do
  if curl -sk "https://localhost:$PORT/v2/" >/dev/null 2>&1; then
    echo "    Registry ready"
    break
  fi
  sleep 1
done

# 3. Build and publish test package
echo "==> Building and publishing $SYSTEM_NAME:$VERSION"
cat > /tmp/test-publish.lisp <<'LISP'
(asdf:load-system "cl-repository-packager")
(let* ((source-dir (uiop:ensure-directory-pathname
                    (merge-pathnames "cl-repo-ocicl-test/"
                                     (uiop:temporary-directory))))
       (reg (cl-oci-client/registry:make-registry
             "https://localhost:5443" :insecure-p t))
       (spec nil))
  ;; Create test source files
  (ensure-directories-exist (merge-pathnames "x" source-dir))
  (with-open-file (s (merge-pathnames "hello-test.asd" source-dir)
                     :direction :output :if-exists :supersede)
    (format s "(defsystem \"hello-test\"~%")
    (format s "  :version \"0.1.0\"~%")
    (format s "  :license \"MIT\"~%")
    (format s "  :components ((:file \"hello\")))~%"))
  (with-open-file (s (merge-pathnames "hello.lisp" source-dir)
                     :direction :output :if-exists :supersede)
    (format s "(defpackage :hello-test (:use :cl) (:export #:greet))~%")
    (format s "(in-package :hello-test)~%")
    (format s "(defun greet () \"Hello from OCI!\")~%"))
  ;; Build
  (setf spec (make-instance 'cl-repository-packager/build-matrix:package-spec
                            :name "hello-test"
                            :version "0.1.0"
                            :source-dir source-dir
                            :license "MIT"
                            :provides '("hello-test")))
  (let ((result (cl-repository-packager/build-matrix:build-package spec)))
    (cl-repository-packager/publisher:publish-package
     reg "cl-repo-test" "0.1.0" result spec))
  ;; Cleanup source
  (uiop:delete-directory-tree source-dir :validate t :if-does-not-exist :ignore)
  (format t "~&Published hello-test:0.1.0 OK~%")
  (uiop:quit 0))
LISP

qlot exec ros --disable-debugger -l /tmp/test-publish.lisp

# 4. Install with ocicl
echo "==> Installing with ocicl"
WORKDIR=$(mktemp -d)
cd "$WORKDIR"
ocicl setup "$WORKDIR" 2>/dev/null || true

echo "==> Running: ocicl -v -k -r localhost:$PORT/$NAMESPACE install $SYSTEM_NAME:$VERSION"
ocicl -v -k -r "localhost:$PORT/$NAMESPACE" install "$SYSTEM_NAME:$VERSION"

# 5. Verify
echo "==> Verifying installation"
EXPECTED_DIR="$WORKDIR/ocicl/$SYSTEM_NAME-$VERSION"

if [ ! -d "$EXPECTED_DIR" ]; then
  # ocicl might place it with a different name; check what's there
  echo "Expected dir $EXPECTED_DIR not found. Contents of ocicl/:"
  ls -la "$WORKDIR/ocicl/" 2>/dev/null || echo "  (ocicl/ does not exist)"
  # Try finding the .asd anywhere under ocicl/
  ASD_FOUND=$(find "$WORKDIR/ocicl/" -name "hello-test.asd" 2>/dev/null | head -1)
  if [ -n "$ASD_FOUND" ]; then
    echo "Found .asd at: $ASD_FOUND"
    EXPECTED_DIR=$(dirname "$ASD_FOUND")
    echo "Using directory: $EXPECTED_DIR"
  else
    echo "FAIL: hello-test.asd not found anywhere under ocicl/"
    exit 1
  fi
fi

if [ ! -f "$EXPECTED_DIR/hello-test.asd" ]; then
  echo "FAIL: hello-test.asd not found in $EXPECTED_DIR"
  ls -la "$EXPECTED_DIR/"
  exit 1
fi

if [ ! -f "$EXPECTED_DIR/hello.lisp" ]; then
  echo "FAIL: hello.lisp not found in $EXPECTED_DIR"
  ls -la "$EXPECTED_DIR/"
  exit 1
fi

echo "==> PASS: ocicl installed cl-repo package successfully"
echo "    Directory: $EXPECTED_DIR"
echo "    Contents:"
ls -la "$EXPECTED_DIR/"
