;;;; xcat.asd

(asdf:defsystem #:xcat
  :description "XCAT mass LAN big file distributor"
  :depends-on (:flexi-streams :bordeaux-threads :local-time-duration :trivial-garbage :log4cl
               :split-sequence :usocket-server :cl-fad :trivial-backtrace)
  :author "Jesse Off <jesseoff@me.com>"
  :license  "MIT"
  :version "0.0.1"
  :serial t
  :components ((:file "package")
               (:file "fifo")
               (:file "xcatd")))
