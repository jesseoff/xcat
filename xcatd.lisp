;;;; xcatd.lisp

(in-package :xcat)

(defvar *xcatd-directory*)
(defvar *xcatd-xfrs* nil)
(defvar *xcatd-nxfrs* 0)
(declaim (type fixnum *xcatd-nxfrs*))
(defvar *xcatd-nxfrs-lock* (bt:make-lock))
(defconstant +xcatd-xfr-timeout-sec+ 16) ;1Mbyte/sec min transfer rate
(defconstant +xcatd-max-xfrs+ 10)

(defmacro log-errors (&rest body)
  `(handler-case (progn ,@body)
     (error (e) (log:info "~a" e))))

(defun do-xcatd-timeouts ()
  "Interrupt any 16Mbyte transfer that hasn't completed in +xcatd-xfr-timeout-sec+ seconds"
  (loop until (fifo-endp *xcatd-xfrs*)
        with now = (local-time:now)
        for (pid . ts) = (fifo-head *xcatd-xfrs*)
        until (>= +xcatd-xfr-timeout-sec+ (ltd:duration-as (ltd:timestamp-difference now ts) :sec))
        when (bt:thread-alive-p pid) do
          (bt:interrupt-thread pid (lambda () (error "xcat send client timeout")))
          (bt:join-thread pid)
        do (fifo-get! *xcatd-xfrs*)))

(defvar *xcatd-chunks* (tg:make-weak-hash-table :test #'equal :weakness :value))
(defun get-chunk (xcat-req-string)
  "Reads 16Mbyte chunk from a given fn pathname.  Stores result in a weak hash table.  Returns a
cons of two octet vectors-- first is the reply header w/checksum, second is the file chunk."
  (let* ((val (gethash xcat-req-string *xcatd-chunks*)))
    (when val (return-from get-chunk val))
    (let* ((msg (split-sequence #\@ xcat-req-string))
           (chunk (parse-integer (second msg) :junk-allowed t))
           (fn-parts (split-sequence #\/ (car msg)))
           (fn-dir (if (cdr fn-parts) (cons :relative (butlast fn-parts)) nil))
           (fn (make-pathname :directory fn-dir :name (car (last fn-parts))))
           (filebuf (make-array #x1000000 :element-type '(unsigned-byte 8)))
           (sum 0) (len 0))
      (declare (type (integer 0 #xff000000) sum) (type (integer 0 #x1000000) len)
               (type (simple-array (unsigned-byte 8) (#x1000000)) filebuf))
      (with-open-file (s (merge-pathnames fn *xcatd-directory*) :element-type '(unsigned-byte 8))
        (file-position s (* #x1000000 chunk))
        (setf len (read-sequence filebuf s) sum (reduce #'+ filebuf)))
      (setf (gethash xcat-req-string *xcatd-chunks*)
            (cons (string-to-octets (format nil "~a@~d@~8,'0x~8,'0x" (car msg) chunk sum len)
                                    :external-format :utf-8)
                  (adjust-array filebuf len))))))

(defun xcatd-broadcast-handler (buf)
  (do-xcatd-timeouts)
  (when (bt:with-lock-held (*xcatd-nxfrs-lock*) (> +xcatd-max-xfrs+ *xcatd-nxfrs*))
    (log-errors
     (let* ((resp (get-chunk (octets-to-string buf :external-format :utf-8)))
            (header (car resp))
            (filebuf (cdr resp))
            (remote *remote-host*)
            (now (local-time:now)) thr)
       (declare (type (simple-array (unsigned-byte 8) (*)) header filebuf))
       (setf thr (bt:make-thread
                  (lambda ()
                    (bt:with-lock-held (*xcatd-nxfrs-lock*) (incf *xcatd-nxfrs*))
                    (log-errors (with-client-socket (sk s remote 19023 :element-type '(unsigned-byte 8))
                                  (write-sequence header s)
                                  (write-sequence filebuf s)))
                    (bt:with-lock-held (*xcatd-nxfrs-lock*) (decf *xcatd-nxfrs*)))))
       (fifo-put! *xcatd-xfrs* (cons thr now)))))
    nil)

(defun xcatd (&optional root)
  (setf *xcatd-directory* (if root (cl-fad:pathname-as-directory root) (user-homedir-pathname)))
  (usocket:socket-server nil 19023 #'xcatd-broadcast-handler nil :protocol :datagram))

;; (defun broadcast (msg)
;;   (let ((buf (flexi-streams:string-to-octets msg :external-format :utf-8))
;;         (sk (usocket:socket-connect "255.255.255.255" 19023 :protocol :datagram)))
;;     (setf (usocket:socket-option sk :broadcast) t)
;;     (usocket:socket-send sk buf (length buf))
;;     (usocket:socket-close sk)))

