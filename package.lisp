;;;; package.lisp

(defpackage #:xcat
  (:use #:cl #:usocket #:flexi-streams)
  (:export #:xcatd
           #:xcat
           #:*xcat-broadcast-ip*))
