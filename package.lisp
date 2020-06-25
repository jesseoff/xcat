;;;; package.lisp

(defpackage #:xcat
  (:use #:cl #:usocket #:split-sequence #:flexi-streams)
  (:export #:xcatd))
