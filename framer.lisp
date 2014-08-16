; Copyright (c) 2014 Akamai Technologies, Inc. (MIT License)

(in-package :cl-http2-protocol)

(defparameter *payload-size-bug-offset* 0
  "Leave 0 for dealing with correct implementations.")

(defparameter *max-payload-size* (- (1- (expt 2 14)) *payload-size-bug-offset*)
  "Maximum frame payload size (16383 bytes).")

(defparameter *common-header-size* 8)

(defparameter *max-frame-size* (+ *max-payload-size* *common-header-size*)
  "Maximum frame size.")

(defparameter *max-stream-id* #x7FFFFFFF
  "Maximum stream ID (2^31)")

(defparameter *max-windowinc* #x7FFFFFFF
  "Maximum window increment value (2^31)")

(defparameter *frame-types* '(:data          #x0
			      :headers       #x1
			      :priority      #x2
			      :rst-stream    #x3
			      :settings      #x4
			      :push-promise  #x5
			      :ping          #x6
			      :goaway        #x7
			      :window-update #x8
			      :continuation  #x9
			      :extensible    (#x10 . #xef)
			      :experimental  (#xf0 . #xff))
  "HTTP 2.0 frame type mapping as defined by the spec")

(defparameter *frame-flags* '(:data          (:end-stream          0
					      :end-segment         1
					      :padded              4)
			      :headers       (:end-stream          0
					      :end-segment         1
					      :end-headers         2
					      :padded              4
					      :priority            5)
			      :priority      (:priority-group      5
					      :priority-dependency 6)
			      :rst-stream    ()
			      :settings      (:ack                 0)
			      :push-promise  (:end-headers         2
					      :padded              4)
			      :ping          (:ack                 0)
			      :goaway        ()
			      :window-update ()
			      :continuation  (:end-headers         2))
  "Per frame flags as defined by the spec. (Integers are bit positions from 0, not values.)")

(defparameter *defined-settings* '(:settings-header-table-size      1
				   :settings-enable-push            2
				   :settings-max-concurrent-streams 3
				   :settings-initial-window-size    4)
  "Default settings as defined by the spec")

(defparameter *defined-errors* '(:no-error            0
				 :protocol-error      1
				 :internal-error      2
				 :flow-control-error  3
				 :settings-timeout    4
				 :stream-closed       5
				 :frame-size-error    6
				 :refused-stream      7
				 :cancel              8
				 :compression-error   9
				 :connect-error       10
				 :enhance-your-calm   11
				 :inadequate-security 12)
  "Default error types as defined by the spec")

(define-symbol-macro *uint32-msb-reserved* #x7FFFFFFF)
(define-symbol-macro *uint32-2msb-reserved* #x3FFFFFFF)
(define-symbol-macro *byte-msb-reserved* #x7F)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *headerpack* "nBBN")
  (defparameter *uint8* "B")
  (defparameter *uint16* "n")
  (defparameter *uint32* "N"))

(defclass framer () ()
  (:documentation "Performs encoding, decoding, and validation of binary HTTP 2.0 frames."))

(defmethod common-header ((framer framer) frame)
  "Generates common 8-byte frame header."

  (when (not (getf *frame-types* (getf frame :type)))
    (raise :http2-compression-error "Invalid frame type (~A)" (getf frame :type)))

  (when (> (getf frame :length) *max-payload-size*)
    (raise :http2-compression-error "Frame payload size is too large: ~D" (getf frame :length)))

  (when (> (getf frame :stream) *max-stream-id*)
    (raise :http2-compression-error "Stream ID (~A) is too large" (getf frame :stream)))

  (when (and (eq (getf frame :type) :window-update)
	     (> (getf frame :increment) *max-windowinc*))
    (raise :http2-compression-error "Window increment (~D) is too large" (getf frame :increment)))

  (let ((frame-type (getf frame :type)))
    (let ((frame-length
	   (getf frame :length))
	  (frame-type-code
	   (let ((type-code (getf *frame-types* frame-type)))
	     (if (numberp type-code)
		 type-code
		 (let ((stated (getf frame :type-code)))
		   (if stated
		       (if (<= (car type-code) stated (cdr type-code))
			   stated
			   (raise :http2-compression-error "Invalid type code (~A) for frame type (~A)"
				  (getf frame :type-code) (getf frame :type)))
		       (car type-code))))))
	  (frame-flags-combined
	   (let ((flags (getf *frame-flags* frame-type)))
	     (reduce (lambda (acc f)
		       (let ((position (getf flags f)))
			 (when (null position)
			   (raise :http2-compression-error "Invalid frame flag (~A) for ~A" f (getf frame :type)))
			 (setf (logbitp position acc) 1)
			 acc))
		     (getf frame :flags)
		     :initial-value 0)))
	  (frame-stream-id
	   (getf frame :stream)))

      (pack *headerpack* (list frame-length frame-type-code frame-flags-combined frame-stream-id)))))

(defmethod read-common-header ((framer framer) (buf buffer))
  "Decodes common 8-byte header."
  (let (frame)
    (destructuring-bind (flength type flags stream)
	(unpack *headerpack* (buffer-data (buffer-slice buf 0 *common-header-size*)))
      (setf (getf frame :length) (logand flength *uint32-2msb-reserved*))

      (setf (getf frame :type)
	    (loop
	       for (ft pos) on *frame-types* by #'cddr
	       do (etypecase pos
		    (number (when (= type pos)
			      (return ft)))
		    (cons   (when (<= (car pos) type (cdr pos))
			      (setf (getf frame :type-code) type)
			      (return ft))))))
      (setf (getf frame :flags)
	    (loop
	       for (name pos) on (getf *frame-flags* (getf frame :type)) by #'cddr
	       if (logbitp pos flags) collect name))

      (setf (getf frame :stream) (logand stream *uint32-msb-reserved*)))
    frame))

(defmethod generate ((framer framer) frame)
  "Generates encoded HTTP 2.0 frame."
  (let ((bytes (make-instance 'buffer :data (make-data-vector *common-header-size*)))
	(length 0))

    (ensuref (getf frame :flags) nil)
    (ensuref (getf frame :stream) 0)
    
    (case (getf frame :type)
      (:data
       (buffer<< bytes (getf frame :payload))
       (incf length (buffer-size (getf frame :payload))))

      (:headers
       (let ((exclusive-dependency (getf frame :exclusive-dependency))
	     (stream-dependency (getf frame :stream-dependency))
	     (weight (getf frame :weight)))
	 (when (or exclusive-dependency
		   (and stream-dependency (/= stream-dependency 0))
		   (and weight (/= weight 16)))
	   (when (not (member :priority (getf frame :flags)))
	     (appendf (getf frame :flags) (list :priority))))

	 (when (member :priority (getf frame :flags))
	   (buffer<< bytes (pack "NB" (list (logior (if exclusive-dependency #x80000000 0)
						    (or stream-dependency 0))
					    (1- weight))))
	   (incf length 5)))

       (buffer<< bytes (getf frame :payload))
       (incf length (buffer-size (getf frame :payload))))

      (:priority
       (buffer<< bytes (pack "NB" (list (logior (if (getf frame :exclusive-dependency) #x80000000 0)
						(or (getf frame :stream-dependency) 0))
					(1- (getf frame :weight)))))
       (incf length 5))

      (:rst-stream
       (buffer<< bytes (pack-error (getf frame :error)))
       (incf length 4))
      
      (:settings
       (when (/= (getf frame :stream) 0)
	 (raise :http2-compression-error "Invalid stream ID (~A)" (getf frame :stream)))

       (doplist (k v (getf frame :payload))
	 (when (not (integerp k))
	   (setf k (getf *defined-settings* k))
	   
	   (when (null k)
	     (raise :http2-compression-error "Unknown settings ID for ~A" k)))

	 (if (not (eq k :extensible))
	     (progn
	       (buffer<< bytes (pack "nN" (list k v)))
	       (incf length 6))
	     (progn
	       (dolist (e v)
		 (buffer<< bytes (pack "nN" (list (car e) (cdr e))))
		 (incf length 6))))))

      (:push-promise
       (buffer<< bytes (pack *uint32* (logand (getf frame :promise-stream) *uint32-msb-reserved*)))
       (buffer<< bytes (buffer-data (getf frame :payload)))
       (incf length (+ 4 (buffer-size (getf frame :payload)))))

      (:ping
       (when (/= (buffer-size (getf frame :payload)) 8)
	 (raise :http2-compression-error "Invalid payload size (~D != 8 bytes)"
		(buffer-size (getf frame :payload))))

       (buffer<< bytes (getf frame :payload))
       (incf length 8))

      (:goaway
       (buffer<< bytes (pack *uint32* (logand (getf frame :last-stream) *uint32-msb-reserved*)))
       (buffer<< bytes (pack-error (getf frame :error)))
       (incf length 8))

      (:window-update
       (buffer<< bytes (pack *uint32* (getf frame :increment)))
       (incf length 4))

      ((:continuation :extensible :experimental)
       (buffer<< bytes (getf frame :payload))
       (incf length (buffer-size (getf frame :payload)))))

    (setf (getf frame :length) length)
    (buffer-overwrite bytes (common-header framer frame))))

(defmethod parse ((framer framer) (buf buffer))
  "Decodes complete HTTP 2.0 frame from provided buffer. If the buffer
does not contain enough data, no further work is performed."
  (when (< (buffer-size buf) 8)
    (return-from parse nil))
  (let ((frame (read-common-header framer buf)))
    (when (< (buffer-size buf) (+ 8 (getf frame :length)))
      (return-from parse nil))

    (buffer-read buf 8)

    ; (format t "http2 frame header: ~S~%http2 frame payload: ~A~%" frame (subseq (buffer-data buf) 0 (getf frame :length)))
    ; (format t "(parse ~S):~%  frame header: ~S~%" framer frame)

    (let ((payload (buffer-read buf (getf frame :length))))

      (case (getf frame :type)
	(:data
	 (let ((flags (getf frame :flags))
	       (size (getf frame :length))
	       (pad 0))
	   (when (member :padded flags)
	     (incf pad (buffer-readbyte payload))
	     (decf size))
	   (when (> pad size)
	     (raise :http2-protocol-error "Padding (~D) exceeds remaining length (~D)" pad size))
	   (decf size pad)
	   (setf (getf frame :payload) (buffer-read payload size))))

	(:headers
	 (let ((flags (getf frame :flags))
	       (size (getf frame :length))
	       (pad 0))
	   (when (member :padded flags)
	     (incf pad (buffer-readbyte payload))
	     (decf size))
	   (if (member :priority flags)
	       (progn
		 (setf (getf frame :exclusive-dependency) (logbitp 7 (buffer-readbyte payload nil)))
		 (let ((dependency (logand (buffer-read-uint32 payload) *uint32-msb-reserved*)))
		   (when (= dependency (getf frame :stream))
		     (raise :http2-protocol-error "Stream cannot depend on itself (~D)" (getf frame :stream)))
		   (setf (getf frame :stream-dependency) dependency))
		 (setf (getf frame :weight) (1+ (buffer-readbyte payload)))
		 (decf size 5))
	       (setf (getf frame :exclusive-dependency) nil
		     (getf frame :stream-dependency) 0
		     (getf frame :weight) 16))
	   (when (> pad size)
	     (raise :http2-protocol-error "Padding (~D) exceeds remaining length (~D)" pad size))
	   (decf size pad)
	   (setf (getf frame :payload) (buffer-read payload size))))

	(:priority
	 (setf (getf frame :exclusive-dependency) (logbitp 7 (buffer-readbyte payload nil)))
	 (let ((dependency (logand (buffer-read-uint32 payload) *uint32-msb-reserved*)))
	   (when (= dependency (getf frame :stream))
	     (raise :http2-protocol-error "Stream cannot depend on itself (~D)" (getf frame :stream)))
	   (setf (getf frame :stream-dependency) dependency))
	 (setf (getf frame :weight) (1+ (buffer-readbyte payload))))

	(:rst-stream
	 (setf (getf frame :error) (unpack-error (buffer-read-uint32 payload))))

	(:settings
	 (loop
	    with settings = '()
	    repeat (/ (getf frame :length) 6)
	    for id  = (buffer-read-uint16 payload)
	    for val = (buffer-read-uint32 payload)
	    do (aif (doplist (k v *defined-settings*) (if (= id v) (return k)))
		    (setf (getf settings it) val)
		    (push (cons id val) (getf settings :extensible)))
	    finally (setf (getf frame :payload) settings)))

	(:push-promise
	 (let ((flags (getf frame :flags))
	       (size (getf frame :length))
	       (pad 0))
	   (when (member :padded flags)
	     (incf pad (buffer-readbyte payload))
	     (decf size))
	   (when (> pad size)
	     (raise :http2-protocol-error "Padding (~D) exceeds remaining length (~D)" pad size))
	   (decf size pad)
	   (setf (getf frame :promise-stream) (logand (buffer-read-uint32 payload) *uint32-msb-reserved*))
	   (decf size 4)
	   (setf (getf frame :payload) (buffer-read payload size))))

	(:ping
	 (setf (getf frame :payload) (buffer-read payload (getf frame :length))))

	(:goaway
	 (setf (getf frame :last-stream) (logand (buffer-read-uint32 payload) *uint32-msb-reserved*))
	 (setf (getf frame :error) (unpack-error (buffer-read-uint32 payload)))

	 (let ((size (- (getf frame :length) 8)))
	   (when (plusp size)
	     (setf (getf frame :payload) (buffer-read payload size)))))

	(:window-update
	 (setf (getf frame :increment) (logand (buffer-read-uint32 payload) *uint32-msb-reserved*)))

	((:continuation :extensible :experimental)
	 (setf (getf frame :payload) (buffer-read payload (getf frame :length))))))

    frame))

(defun pack-error (e)
  (when (not (integerp e))
    (if-let (d (getf *defined-errors* e))
      (setf e d)
      (raise :http2-compression-error "Unknown error ID for ~A" e))

  (pack *uint32* e)))

(defun unpack-error (e)
  (or (loop for (name v) on *defined-errors* by #'cddr if (= v e) return name) e))
