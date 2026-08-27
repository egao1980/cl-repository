(defpackage :cl-oci/tests/system-names-test
  (:use :cl :rove)
  (:import-from :cl-oci/system-names
                #:oci-package-name
                #:asdf-primary-system-name
                #:slash-system-name-p
                #:provided-oci-repositories))
(in-package :cl-oci/tests/system-names-test)

(deftest asdf-primary-system-name-strips-slash
  (ok (string= "ai-agent-protocol" (asdf-primary-system-name "ai-agent-protocol/mcp")))
  (ok (string= "ai-agent-protocol" (asdf-primary-system-name "AI-Agent-Protocol/AG-UI")))
  (ok (string= "alexandria" (asdf-primary-system-name "alexandria"))))

(deftest oci-package-name-slash-and-plus
  (ok (string= "ai-agent-protocol" (oci-package-name "ai-agent-protocol/mcp")))
  (ok (string= "cl-plus-ssl" (oci-package-name "cl+ssl")))
  (ok (string= "foo-plus-bar" (oci-package-name "foo+bar/baz")))
  (ok (string= "alexandria" (oci-package-name "Alexandria"))))

(deftest slash-system-name-p-detects-secondaries
  (ok (slash-system-name-p "ai-agent-protocol/mcp"))
  (ok (not (slash-system-name-p "ai-agent-protocol")))
  (ok (not (slash-system-name-p "cffi-toolchain"))))

(deftest provided-oci-repositories-skips-slash-secondaries
  (ok (equal (provided-oci-repositories "egao1980/cl-systems"
                                        '("ai-agent-protocol"
                                          "ai-agent-protocol/mcp"
                                          "ai-agent-protocol/ag-ui"))
             '("egao1980/cl-systems/ai-agent-protocol")))
  (ok (equal (provided-oci-repositories "ns" '("cffi" "cffi-toolchain"))
             '("ns/cffi" "ns/cffi-toolchain")))
  (ok (equal (provided-oci-repositories "ns" '("cl+ssl"))
             '("ns/cl-plus-ssl"))))
