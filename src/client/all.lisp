(uiop:define-package :cl-repository-client/all
  (:nicknames :cl-repository-client :cl-repo)
  (:use-reexport
   :cl-repository-client/platform-resolver
   :cl-repository-client/installer
   :cl-repository-client/lockfile
   :cl-repository-client/asdf-integration
   :cl-repository-client/quickload
   :cl-repository-client/commands))
