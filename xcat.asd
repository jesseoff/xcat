;;;; xcat.asd

(asdf:defsystem #:xcat
  :description "XCAT mass LAN big file distributor"
  :depends-on (:flexi-streams :bordeaux-threads :trivial-garbage :log4cl
               :usocket-server :cl-fad :cl-ppcre)
  :author "Jesse Off <jesseoff@me.com>"
  :license  "MIT"
  :version "0.0.1"
  :serial t
  :components ((:file "package")
               (:file "fifo")
               (:file "xcatd")))
