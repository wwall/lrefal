;;;; Refal parser and internal data representation
;;;; (c) paul7, 2010

(defpackage :net.paul7.refal.parser
  (:nicknames :rparse)
  (:use :common-lisp 
	:net.paul7.utility
	:net.paul7.refal.internal)
  (:export string->scope 
	   string->pattern
	   string->statement
	   string->function
	   string->program
	   data->pattern
	   interpolate))

(in-package :net.paul7.refal.parser)

;;; Refal parser

(defclass refal-source ()
  ((data
    :accessor data
    :initarg :data
    :initform nil)
   (src-pos
    :accessor src-pos
    :initform 0)
   (saved-pos
    :accessor saved-pos
    :initform nil)
   (size 
    :accessor size
    :initform 0)))

(defmethod initialize-instance :after ((src refal-source) &key)
  (with-accessors ((data data) 
		   (size size)) src
    (setf size (length data))))

(defun make-source (string)
  (make-instance 'refal-source 
		 :data (convert-sequence string 'list)))

(defun read-source (src)
  (with-accessors ((data data) 
		   (src-pos src-pos) 
		   (size size)) src
    (if (< src-pos size)
	(elt data (post-incf src-pos)))))

(defun save-pos (src)
  (with-accessors ((saved-pos saved-pos)
		   (src-pos src-pos)) src
    (push src-pos saved-pos)))

(defun load-pos (src)
  (with-accessors ((saved-pos saved-pos)) src
    (if saved-pos
	(pop saved-pos)
	(error "stack underflow"))))

(defun try-token (src)
  (save-pos src))

(defun accept-token (src)
    (load-pos src))

(defun reject-token (src)
  (with-accessors ((src-pos src-pos)) src
    (setf src-pos (load-pos src))))

(defmacro deftoken (name (src &rest args) &body body)
  (with-gensyms (result)
    `(defun ,name (,src ,@args)
       (try-token ,src)
       (let ((,result (progn
			,@body)))
	 (if ,result
	     (accept-token ,src)
	     (reject-token ,src))
	 ,result))))

(deftoken refal-char (src)
  (read-source src))

(deftoken exactly (src char)
  (let ((next (refal-char src)))
    (if (and next (char-equal char next))
	char)))

(deftoken one-of (src chars)
  (if chars
      (or (exactly src (first chars))
	  (one-of src (rest chars)))))

(deftoken refal-space (src)
  (one-of src '(#\Space #\Tab #\Newline)))

(deftoken refal-delimiter (src)
  (or (refal-space src) 
      (one-of src '(#\) #\( #\< #\> #\{ #\} ))))

(deftoken refal-word-char (src)
  (if (not (or (refal-delimiter src)
	       (refal-separator src)
	       (refal-statement-terminator src)))
      (refal-char src)))

(deftoken refal-open-parenthesis (src)
  (exactly src #\( ))

(deftoken refal-close-parenthesis (src)
  (exactly src #\) ))

(deftoken refal-open-funcall (src)
  (exactly src #\< ))

(deftoken refal-close-funcall (src)
  (exactly src #\> ))

(deftoken refal-open-block (src)
  (exactly src #\{ ))

(deftoken refal-close-block (src)
  (exactly src #\} ))

(deftoken refal-separator (src)
  (exactly src #\= ))

(deftoken refal-statement-terminator (src)
  (exactly src #\; ))

(deftoken refal-end-of-stream (src)
  (not (read-source src)))

(deftoken refal-bad (src)
  (not (characterp (read-source src))))

(defmacro deftoken-collect (name (src &rest args)
				&body cond)
  (with-gensyms (result each)
    `(deftoken ,name (,src ,@args)
       (let ((,result nil)
	     (,each nil))
	 (do ()
	     ((or (refal-end-of-stream ,src)
		  (not (setf ,each (progn ,@cond))))
	      (nreverse ,result))
	   (push ,each ,result))))))

(deftoken-collect refal-word (src) 
  (refal-word-char src))

(deftoken-collect refal-skip-spaces (src)
  (refal-space src))

(deftoken refal-digit (src)
  (digit-char-p (refal-char src)))

(deftoken-collect refal-digits (src)
  (refal-digit src))

(defun digits->integer (digits &optional (accum 0))
  (if digits
      (digits->integer (cdr digits) (+ (* 10 accum) (car digits)))
      accum))

(deftoken refal-integer (src)
  (let ((digits (refal-digits src)))
    (if digits
	(digits->integer digits))))

(deftoken refal-empty (src)
  (refal-skip-spaces src)
  (refal-end-of-stream src))

(deftoken refal-expression-char (src)
  (not (or (refal-close-parenthesis src)
	   (refal-close-funcall src)
	   (refal-close-block src)
	   (refal-separator src)
	   (refal-statement-terminator src))))

(deftoken refal-statement-char (src)
  (not (or (refal-close-parenthesis src)
	   (refal-close-funcall src)
	   (refal-close-block src)
	   (refal-statement-terminator src))))

(deftoken refal-check-end (src &key (allowed (constantly nil)))
  (cond 
    ((refal-end-of-stream src)
     t)
    ((refal-bad src)
     (error "bad source"))
    ((funcall allowed src)
     nil)
    (t t)))

(defmacro deftoken-sequence (name (src &rest args) 
			     constructor allowed
			     &body body)
  (with-gensyms (result token)
    `(deftoken ,name (,src ,@args)
       (let ((,result nil))
	 (do ()
	     ((progn
		(refal-skip-spaces src)
		(refal-check-end ,src :allowed ,allowed))
	      (funcall ,constructor (nreverse ,result)))
	   (let ((,token (progn 
			   ,@body)))
	     (if ,token
		 (push ,token ,result)
		 (return nil))))))))

(defmacro defblock (name 
		    (src &rest args) 
		    (open 
		     body 
		     close) 
		    &optional (bad `(error "expected closing token")))
  (with-gensyms (subexpr)
    `(deftoken ,name (,src ,@args)
       (refal-skip-spaces src)
       (and (,open ,src)
	    (let ((,subexpr (,body ,src ,@args)))
	      (if ,subexpr 
		  (if (,close ,src)
		      ,subexpr
		      ,bad)))))))

(defblock refal-subexpr 
    (src) 
  (refal-open-parenthesis 
   refal-expr
   refal-close-parenthesis)
  (error "expected )"))
  
(deftoken-sequence refal-expr (src) 
    #'data->scope #'refal-expression-char
  (or (refal-subexpr src)
      (refal-integer src)
      (refal-char src)))

(deftoken refal-literal (src)
  (let ((word (or (refal-integer src) 
		  (refal-word src))))
    (if word
	(make-instance 'refal-e-var :value word))))

(deftoken refal-id (src)
  (let ((id (refal-word src)))
    (if id
	(convert-sequence id 'string))))

(deftoken refal-var (src dict)
  (let ((type (one-of src '(#\e #\t #\s))))
    (if (and type (exactly src #\.))
	(let ((id (refal-id src)))
	  (let ((old-var (gethash id dict)))
	    (cond
	      ((not old-var) 
	       (setf (gethash id dict)
		     (make-var type id)))
	      ((eq (var-type old-var) 
		   (make-uniform-type type)) old-var)
	      (t (error "type mismatch"))))))))

(deftoken refal-fun-and-args (src dict)
  (let ((id (refal-id src)))
    (if id
	(let ((arg (refal-pattern src dict)))
	  (if arg
	      (make-instance 'refal-funcall 
			     :function-name id
			     :function-argument arg))))))

(defblock refal-funcall 
    (src dict)
  (refal-open-funcall
   refal-fun-and-args
   refal-close-funcall)
  (error "expected >"))
  
(defblock refal-subpattern (src dict)
  (refal-open-parenthesis 
   refal-pattern
   refal-close-parenthesis)
  (error "expected )"))

(deftoken-sequence refal-pattern 
    (src &optional (dict (make-hash-table :test #'equalp))) 
    #'data->pattern #'refal-expression-char
  (or (refal-subpattern src dict)
      (refal-funcall src dict)
      (refal-var src dict)
      (refal-literal src)))

(deftoken refal-statement 
    (src &optional (dict (make-hash-table :test #'equalp)))
  (let ((left-pattern (refal-pattern src dict)))
    (if (refal-separator src)
	(let ((right-pattern (refal-pattern src dict)))
	  (if (refal-statement-terminator src)
	      (list :left left-pattern :right right-pattern :dict dict))))))

(deftoken refal-function-header (src)
  (refal-id src))

(deftoken-sequence refal-funbody (src) 
    #'identity #'refal-statement-char 
  (refal-statement src))

(defblock refal-block (src)
  (refal-open-block
   refal-funbody
   refal-close-block)
  (error "expected }"))

(deftoken refal-function (src)
  (refal-skip-spaces src)
  (let ((fname (refal-function-header src)))
    (if fname
	(let ((fbody (refal-block src)))
	  (if fbody
	      (list :fname fname
		    :statements fbody)
	      (error (format nil "syntax error in function ~a" fname)))))))

(deftoken-collect refal-program (src)
  (refal-function src))

;; make refal-scope compatible atom list of the string
(defun string->scope (string)
  (let* ((src (make-source string))
	 (expr (refal-expr src)))
    (if (refal-empty src)
	expr
	(error (format nil "unexpected ~a" (refal-char src))))))

;; make scope corresponding to the string
(defun data->scope (data)
  (make-instance 'refal-scope :data data))

(defun string->pattern (string 
			&optional (dict (make-hash-table :test #'equalp)))
  (let ((src (make-source string)))
    (values 
     (refal-pattern src dict)
     dict)))

(defun string->statement (string)
  (let ((src (make-source string)))
    (refal-statement src)))

(defun string->function (string)
  (let ((src (make-source string)))
    (refal-function src)))

(defun string->program (string)
  (let ((src (make-source string)))
    (refal-program src)))

(defun data->pattern (data)
  (make-instance 'refal-pattern :data data))

(defgeneric interpolate (object))

(defmethod interpolate ((var refal-var))
  (if (bound var)
      (value var)
      (error (format nil "~a is unbound" var))))
  
(defmethod interpolate ((pattern refal-pattern))
  (data->scope (mapcan (compose #'copy-list #'mklist #'interpolate)
		       (data pattern))))
