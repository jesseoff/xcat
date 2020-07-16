;;;; xcatd.lisp

(in-package :xcat)

(defvar *xcatd-directory*)
(defvar *xcatd-remotes* nil)
(defvar *xcatd-lock* (bt:make-lock))
(defconstant +xcatd-xfr-timeout-sec+ 16) ;1Mbyte/sec min transfer rate
(defconstant +xcatd-max-xfrs+ 10)
(defvar *xcatd-chunks* (tg:make-weak-hash-table :test #'equal :weakness :value))

(defmacro log-errors (&body body)
  `(handler-case (progn ,@body)
     (error (e) (log:info "~a" e) e)))

(defmacro return-errors (&body body)
  `(handler-case (progn ,@body)
     (error (e) e)))

(defmacro log-but-retry-errors-after-delay (&body body)
  `(loop for i = (return-errors ,@body)
         if (typep i 'error) do
           (log:info "~a, but retrying..." i)
           (sleep 1/10)
         else return i))

(defconstant +max-array-size+ #+:32-bit #x800000 #+:64-bit #x1000000)
(defun make-bufs (nbytes)
  "Makes list of arrays for when nbytes is greater than +max-array-size+"
  (if (> nbytes +max-array-size+)
      (nconc (make-bufs +max-array-size+)
             (make-bufs (- nbytes +max-array-size+)))
      (list (make-array nbytes :element-type '(unsigned-byte 8)))))

(defun read-into (bufs stream)
  "read-sequence into a list of bufs, returning multiple values of filled bufs and total size"
  (loop for buf of-type (simple-array (unsigned-byte 8) (*)) in bufs
        for bufsz = (length buf)
        for readlen = (read-sequence buf stream)
        while (plusp readlen)
        sum readlen into sz
        if (/= readlen bufsz)
          collect (adjust-array buf readlen) into obufs
        else
          collect buf into obufs
        finally (return (values obufs sz))))

(defun sum-bufs (bufs)
  (declare (optimize (speed 3) (safety 0)))
  (loop for buf in bufs
        sum (the fixnum (loop
              for b fixnum across (the (simple-array (unsigned-byte 8) (*)) buf)
              sum b fixnum)) fixnum))

(defun bufs-length (bufs)
  (loop for buf of-type (simple-array (unsigned-byte 8) (*)) in bufs sum (length buf)))

;;req strings are of the form "<file-name>@<chunk number>"
(defun file-read-chunk (xcat-req-string)
  "Reads 16Mbyte chunk. Stores result in a weak hash table for cacheing. Returns a list of octet
vectors-- first is the reply header w/checksum, next are the file buf(s)."
  (let* ((val (gethash xcat-req-string *xcatd-chunks*)))
    (when val
      (log:debug "chunk ~a retreived from cache" xcat-req-string)
      (return-from file-read-chunk val))
    (let* ((msg (cl-ppcre:split "@" xcat-req-string))
           (chunk (parse-integer (second msg) :junk-allowed t))
           (fn-parts (cl-ppcre:all-matches-as-strings "[^/]+" (car msg)))
           (fn-dir (if (cdr fn-parts) (cons :relative (butlast fn-parts)) nil))
           (fn (make-pathname :directory fn-dir :name (car (last fn-parts))))
           (filebufs (make-bufs #x1000000))
           (sum 0) (len 0))
      (declare (type (integer 0 #xff000000) sum) (type (integer 0 #x1000000) len))
      (with-open-file (s (merge-pathnames fn *xcatd-directory*) :element-type '(unsigned-byte 8))
        (file-position s (* #x1000000 chunk))
        (multiple-value-bind (obufs sz) (read-into filebufs s)
          (setf len sz filebufs obufs sum (sum-bufs obufs))))
      (setf (gethash xcat-req-string *xcatd-chunks*)
            (cons (string-to-octets (format nil "~a@~a@~8,'0x~8,'0x" (car msg) chunk sum len)
                                    :external-format :utf-8)
                  filebufs)))))

(defun xcatd-broadcast-handler (buf)
  (bt:with-lock-held (*xcatd-lock*)
    (loop
      for r in *xcatd-remotes*
      for n from 0
      when (or (>= n +xcatd-max-xfrs+) (ip= r *remote-host*))
        do (log:debug "ignoring broadcast from ~a (~a/~a connections active)"
                      *remote-host* (length *xcatd-remotes*) +xcatd-max-xfrs+)
           (return-from xcatd-broadcast-handler nil)))
  (log-errors
   (let* ((t0 (get-internal-real-time))
          (chunk (octets-to-string buf :external-format :utf-8))
          (resp (file-read-chunk chunk))
          (remote *remote-host*))
     (log:debug "chunk ~a filled ~a bytes in ~f sec" chunk (bufs-length resp)
                (/ (- (get-internal-real-time) t0) internal-time-units-per-second))
     (bt:make-thread
       (lambda ()
         (bt:with-lock-held (*xcatd-lock*)
           (push remote *xcatd-remotes*)
           (log:debug "connecting to ~a (~a/~a) for ~a" remote (length *xcatd-remotes*)
                      +xcatd-max-xfrs+ chunk))
         (log-errors
          (setf t0 (get-internal-real-time))
          (bt:with-timeout (+xcatd-xfr-timeout-sec+)
            (with-client-socket (sk s remote 19023 :element-type '(unsigned-byte 8))
              (loop for buf in resp do (write-sequence buf s))
              (finish-output s)
              (log:debug "chunk ~a fully sent to ~a in ~f sec" chunk remote
                         (/ (- (get-internal-real-time) t0) internal-time-units-per-second)))))
         (bt:with-lock-held (*xcatd-lock*)
           (log:debug "connection to ~a for ~a closed (~a/~a) ~f sec" remote chunk
                      (length *xcatd-remotes*) +xcatd-max-xfrs+
                      (/ (- (get-internal-real-time) t0) internal-time-units-per-second))
           (setf *xcatd-remotes* (delete remote *xcatd-remotes*
                                         :test (lambda (x y) (ip= x y)))))))))
  nil)

(defun xcatd (&key root background)
  (if background
      (bt:make-thread (lambda () (xcatd :root root)))
      (let ((*xcatd-directory* (if root
                                   (uiop/pathname:ensure-directory-pathname root)
                                   (user-homedir-pathname))))
        (socket-server nil 19023 #'xcatd-broadcast-handler nil :protocol :datagram))))

(defvar *xcat-prefetcher-thread* nil)
(defvar *xcat-helpout-thread* nil)
(defvar *xcat-helpout-xfr-thread* nil)
;; This holds on to strong refs of prev chunks so they don't get GC'ed in our weak hash table
(defvar *xcat-prev-chunks* nil)
(defvar *xcat-chunks* (tg:make-weak-hash-table :test #'equal :weakness :value))
(defvar *xcat-lock* (bt:make-lock))
(defparameter *xcat-broadcast-ip* "255.255.255.255")

(defun net-read-chunk (xcat-req-string)
  "Broadcasts requests for files via XCAT. Returns cons of two octet vectors-- car is the resp
header, cdr is the verified datablock(s)."
  (let ((buf (string-to-octets xcat-req-string :external-format :utf-8))
        (resp (make-array (+ 17 (length xcat-req-string))
                          :element-type '(unsigned-byte 8)
                          :initial-element 0))
        (nbytes-idx (+ 9 (length xcat-req-string)))
        insk instream udp-broadcast-sk tcp-listen-sk (readlen 0) (t0 (get-internal-real-time)))
    (declare (type fixnum readlen nbytes-idx))
    (log-but-retry-errors-after-delay
      (unwind-protect
           (progn
             (setf udp-broadcast-sk (socket-connect nil nil :protocol :datagram)
                   (socket-option udp-broadcast-sk :broadcast) t
                   tcp-listen-sk (socket-listen *wildcard-host* 19023 :reuse-address t :backlog 1
                                                :element-type '(unsigned-byte 8)))
             (loop
               do (socket-send udp-broadcast-sk buf (length buf) :host *xcat-broadcast-ip* :port 19023)
                  (loop while (wait-for-input tcp-listen-sk :timeout 1/10 :ready-only t)
                        do (log-errors
                             (bt:with-timeout (3)
                               (setf insk (socket-accept tcp-listen-sk)
                                     instream (socket-stream insk)
                                     readlen (read-sequence resp instream))))
                        while (or (/= (length resp) readlen)
                                  (/= 64 (aref resp (length buf))) ;64 is utf-8 #\@ char
                                  (mismatch buf (subseq resp 0 (length buf))))
                        do (socket-close insk)
                           (setf insk nil)
                           (fill resp 0))
               until insk)
             (log:debug "incoming connection after ~f sec"
                        (/ (- (get-internal-real-time) t0) internal-time-units-per-second))
             (socket-close udp-broadcast-sk)
             (socket-close tcp-listen-sk)
             (setf udp-broadcast-sk nil tcp-listen-sk nil)
             (let* ((sum
                      (parse-integer (octets-to-string (subseq resp (1+ (length buf)) nbytes-idx)
                                                       :external-format :utf-8) :radix 16))
                    (nbytes
                      (parse-integer
                       (octets-to-string (subseq resp nbytes-idx) :external-format :utf-8)
                       :radix 16))
                    (bufs (make-bufs nbytes)))
               (bt:with-timeout (+xcatd-xfr-timeout-sec+)
                 (multiple-value-bind (obufs sz) (read-into bufs instream)
                   (setf readlen sz bufs obufs)))
               (socket-close insk)
               (setf insk nil)
               (unless (= readlen nbytes) (log:info readlen nbytes) (error "chunk early EOF"))
               (unless (zerop (- sum (sum-bufs bufs))) (error "bad checksum"))
               (log:debug "got chunk ~a, took ~f sec" xcat-req-string
                          (/ (- (get-internal-real-time) t0) internal-time-units-per-second))
               (cons resp bufs)))
        (when insk (socket-close insk))
        (when udp-broadcast-sk (socket-close udp-broadcast-sk))
        (when tcp-listen-sk (socket-close tcp-listen-sk))))))

;; This works by keeping references to chunks in the *xcat-prev-chunks* FIFO, thereby disallowing
;; their GC from the weak hashtable *xcat-chunks*.
(defun ensure-cached (chunk &optional (megabytes 100))
  (fifo-put! *xcat-prev-chunks* chunk)
  (when (> (fifo-count *xcat-prev-chunks*) (floor megabytes 16)) (fifo-get! *xcat-prev-chunks*)))

(defun xcat-req (xcat-req-string)
  "Requests XCAT chunk, possibly from a prefetch or from the chunk cache hash table."
  (bt:with-lock-held (*xcat-lock*)
    (let ((hit (gethash xcat-req-string *xcat-chunks*)))
      (when hit (return-from xcat-req hit))))
  (when *xcat-prefetcher-thread*
    (bt:join-thread *xcat-prefetcher-thread*)
    (setf *xcat-prefetcher-thread* nil)
    (return-from xcat-req (xcat-req xcat-req-string)))
   (let ((chunk (net-read-chunk xcat-req-string)))
    (bt:with-lock-held (*xcat-lock*)
      (ensure-cached chunk)
      (setf (gethash xcat-req-string *xcat-chunks*) chunk))
    chunk))

(defun xcat-prefetch (xcat-req-string)
  "Starts a nonblocking background request for the xcat-req-string chunk."
  (bt:with-lock-held (*xcat-lock*)
    (when (gethash xcat-req-string *xcat-chunks*) (return-from xcat-prefetch nil)))
  (when *xcat-prefetcher-thread* (error "XCAT prefetch already running"))
  (setf *xcat-prefetcher-thread*
        (bt:make-thread
         (lambda ()
           (let ((chunk (net-read-chunk xcat-req-string)))
             (bt:with-lock-held (*xcat-lock*)
               (ensure-cached chunk)
               (setf (gethash xcat-req-string *xcat-chunks*) chunk)))))))

(defun xcat-broadcast-handler (buf)
  (when (or (null *xcat-helpout-xfr-thread*)
            (not (bt:thread-alive-p *xcat-helpout-xfr-thread*)))
    (bt:with-lock-held (*xcat-lock*)
      (let ((chunk (gethash (octets-to-string buf :external-format :utf-8) *xcat-chunks*))
            (remote *remote-host*))
        (when chunk
          (setf *xcat-helpout-xfr-thread*
                (bt:make-thread
                 (lambda ()
                   (log:info "Helpout: ~a" (octets-to-string (car chunk) :external-format :utf-8))
                   (log-errors
                     (bt:with-timeout (+xcatd-xfr-timeout-sec+)
                       (with-client-socket (sk s remote 19023 :element-type '(unsigned-byte 8))
                         (write-sequence (car chunk) s)
                         (write-sequence (cdr chunk) s)
                         (finish-output s)))))))))))
  nil)

(defgeneric xcat (path output))

(defmethod xcat (path (out-function function))
  (unless *xcat-helpout-thread*
    (setf *xcat-helpout-thread*
          (socket-server nil 19023 #'xcat-broadcast-handler nil
                         :protocol :datagram :in-new-thread t)))
  (loop
    for n from 0
    for chunk = (xcat-req (format nil "~a@~d" path n))
    for bufs = (cdr chunk)
    for bufsz = (bufs-length bufs)
    unless (/= #x1000000 bufsz) do
      (xcat-prefetch (format nil "~a@~d" path (1+ n)))
    if (plusp bufsz) do
      (mapc out-function bufs)
    until (/= #x1000000 bufsz)))

(defmethod xcat (path (out-stream stream))
  (xcat path (lambda (buf)
               (declare (type (simple-array (unsigned-byte 8) (*))))
               (write-sequence buf out-stream)))
  (finish-output out-stream))

(defmethod xcat (path (out-file pathname))
  (with-open-file (s out-file :direction :output :if-does-not-exist :create
                              :element-type '(unsigned-byte 8) :if-exists :overwrite)
    (xcat path s)
    (finish-output s)))
