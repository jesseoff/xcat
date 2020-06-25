
(in-package #:xcat)

(defstruct fifo (data nil :type list) (tail nil :type list) (n 0 :type fixnum))

(defmacro fifo-get! (f)
  "Removes and returns object from fifo.  If fifo becomes empty, struct is destroyed, i.e. setf nil"
  (multiple-value-bind (vars forms var set access) (get-setf-expansion f)
    `(let* (,@(mapcar #'list vars forms)
            (,(car var) ,access))
       (declare (type (or null fifo) ,(car var)))
       (cond
         ((null ,(car var)) nil)
         ((= 1 (fifo-n ,(car var)))
          (prog1 (car (fifo-data ,(car var)))
            (setf ,(car var) nil)
            ,set))
         (t (progn
              (decf (fifo-n ,(car var)))
              (pop (fifo-data ,(car var)))))))))

(defmacro fifo-put! (f obj)
  "Adds obj to fifo, instantiating new fifo struct if necessary.  Returns new count of fifo"
  (let ((y (gensym)))
    (multiple-value-bind (vars forms var set access) (get-setf-expansion f)
      `(let* (,@(mapcar #'list vars forms)
              (,(car var) ,access)
              (,y (cons ,obj nil)))
         (declare (type (or null fifo) ,(car var)))
         (if (fifo-p ,(car var))
             (progn
               (setf (cdr (fifo-tail ,(car var))) ,y
                     (fifo-tail ,(car var)) ,y)
               (incf (fifo-n ,(car var))))
             (progn
               (setf ,(car var) (make-fifo :data ,y :tail ,y :n 1))
               ,set
               1))))))

(defun fifo-count (f)
  (declare (type (or null fifo) f))
  (if f (fifo-n f) 0))

(defun fifo-head (f)
  (declare (type (or null fifo) f))
  (if (fifo-p f) (car (fifo-data f)) nil))

(defun fifo-endp (f)
  (declare (type (or null fifo) f))
  (if (fifo-p f) nil t))
