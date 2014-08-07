; Copyright (c) 2014 Akamai Technologies, Inc. (MIT License)

(in-package :cl-http2-protocol)

; Implementation of header compression for HTTP 2.0 (HPACK) format adapted
; to efficiently represent HTTP headers in the context of HTTP 2.0.
;
; - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression

(defparameter *static-table*
  '((":authority"                  . "")
    (":method"                     . "GET")
    (":method"                     . "POST")
    (":path"                       . "/")
    (":path"                       . "/index.html")
    (":scheme"                     . "http")
    (":scheme"                     . "https")
    (":status"                     . "200")
    (":status"                     . "204")
    (":status"                     . "206")
    (":status"                     . "304")
    (":status"                     . "400")
    (":status"                     . "404")
    (":status"                     . "500")
    ("accept-charset"              . "")
    ("accept-encoding"             . "gzip, deflate")
    ("accept-language"             . "")
    ("accept-ranges"               . "")
    ("accept"                      . "")
    ("access-control-allow-origin" . "")
    ("age"                         . "")
    ("allow"                       . "")
    ("authorization"               . "")
    ("cache-control"               . "")
    ("content-disposition"         . "")
    ("content-encoding"            . "")
    ("content-language"            . "")
    ("content-length"              . "")
    ("content-location"            . "")
    ("content-range"               . "")
    ("content-type"                . "")
    ("cookie"                      . "")
    ("date"                        . "")
    ("etag"                        . "")
    ("expect"                      . "")
    ("expires"                     . "")
    ("from"                        . "")
    ("host"                        . "")
    ("if-match"                    . "")
    ("if-modified-since"           . "")
    ("if-none-match"               . "")
    ("if-range"                    . "")
    ("if-unmodified-since"         . "")
    ("last-modified"               . "")
    ("link"                        . "")
    ("location"                    . "")
    ("max-forwards"                . "")
    ("proxy-authenticate"          . "")
    ("proxy-authorization"         . "")
    ("range"                       . "")
    ("referer"                     . "")
    ("refresh"                     . "")
    ("retry-after"                 . "")
    ("server"                      . "")
    ("set-cookie"                  . "")
    ("strict-transport-security"   . "")
    ("transfer-encoding"           . "")
    ("user-agent"                  . "")
    ("vary"                        . "")
    ("via"                         . "")
    ("www-authenticate"            . ""))
  "Default working set as defined by the spec.")

; The set of components used to encode or decode a header set form an
; encoding context: an encoding context contains a header table and a
; reference set - there is one encoding context for each direction.

(defclass encoding-context (error-include)
  ((type :initarg :type)
   (table :reader table :initform nil
	  :documentation "Running set of headers used as a compression dictionary, in addition to *STATIC-TABLE*.")
   (settings-limit :accessor settings-limit :initarg :settings-limit :initform 4096)
   (limit :accessor limit :initarg :limit :initform 4096)
   (refset :reader refset :initform (make-array 128 :element-type t :adjustable t :fill-pointer 0)
	   :documentation "Headers carried over request-to-request and manipulated by compressed header frames."))
  (:documentation "Encoding context: a header table and reference set for one direction"))

(defmethod initialize-instance :after ((encoding-context encoding-context) &key)
  (with-slots (settings-limit limit) encoding-context
    (unless limit
      (setf limit settings-limit))))

(defmethod process ((encoding-context encoding-context) cmd)
  "Performs differential coding based on provided command type.
- http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-03#section-3.2"
  (with-slots (refset table settings-limit limit) encoding-context
    (let (emit evicted)

      (if (eq (getf cmd :type) :context)
	  (case (getf cmd :context-type)
	    (:reset
	     (setf evicted (map 'list #'car refset)
		   (fill-pointer refset) 0))
	    (:new-max-size
	     (when (> (getf cmd :value) settings-limit)
	       (raise 'http2-compression-error "Attempt to set table limit above SETTINGS_HEADER_TABLE_SIZE."))
	     (setf limit (getf cmd :value))
	     (size-check encoding-context nil)))
	  
	  (if (eq (getf cmd :type) :indexed)
	      ;; indexed representation
	      (let ((idx1 (getf cmd :name))) ; 1-based index but 0 is a special value
		(declare ((integer 0 *) idx1))
		(if (zerop idx1)
		    (setf (fill-pointer refset) 0)

		    (let* ((idx (1- idx1))
			   (cur (position idx refset :key #'car)))
		      (if cur
			  (vector-delete-at refset cur)
			  (let ((length-table (length table)))
			    (if (>= idx length-table)
				(progn
				  (setf emit (elt *static-table* (- idx length-table)))
				  (multiple-value-bind (ok-to-add this-evicted)
				      (size-check encoding-context (list :name (car emit) :value (cdr emit)))
				    (when ok-to-add
				      (push emit table)
				      (loop for r across refset do (incf (car r)))
				      (vector-push-extend (cons 0 emit) refset))
				    (when this-evicted
				      (setf evicted this-evicted))))
				(progn
				  (setf emit (elt table idx))
				  (vector-push-extend (cons idx emit) refset))))))))

	      ;; literal representation
	      (let ((cmd (copy-tree cmd)))
	    
		(when (integerp (getf cmd :name))
		  (ensuref (getf cmd :index) (getf cmd :name))
		  (let ((idx1 (getf cmd :index)))
		    (declare ((integer 0 *) idx1))
		    (let* ((idx (1- idx1))
			   (length-table (length table))
			   (entry (if (>= idx length-table)
				      (elt *static-table* (- idx length-table))
				      (elt table idx))))
		      (setf (getf cmd :name) (car entry))
		      (ensuref (getf cmd :value) (cdr entry)))))

		(setf emit (cons (getf cmd :name) (getf cmd :value)))
	      
		(when (eq (getf cmd :type) :incremental)
		  (multiple-value-bind (ok-to-add this-evicted)
		      (size-check encoding-context (list :name (car emit) :value (cdr emit)))
		    (when ok-to-add
		      (push emit table)
		      (loop for r across refset do (incf (car r)))
		      (vector-push-extend (cons 0 emit) refset))
		    (when this-evicted
		      (setf evicted this-evicted)))))))

      (values emit evicted))))

(defmethod add-cmd ((encoding-context encoding-context) header)
  "Emits best available command to encode provided header."
  (with-slots (table) encoding-context
    ; check if we have an exact match in header table
    (when-let (idx (or (position header table :test #'equal)
		       (awhen (position header *static-table* :test #'equal)
			 (+ it (length table)))))
      (when (not (activep encoding-context idx))
	(return-from add-cmd (list :name (1+ idx) :type :indexed))))

    ; check if we have a partial match on header name
    (when-let (idx (or (position (car header) table :key #'car :test #'equal)
		       (awhen (position (car header) *static-table* :key #'car :test #'equal)
			 (+ it (length table)))))
      ; default to incremental indexing
      ; TODO: implement literal without indexing strategy
      (return-from add-cmd (list :name (1+ idx) :value (cdr header) :type :incremental)))

    (list :name (car header) :value (cdr header) :type :incremental)))

(defmethod remove-cmd ((encoding-context encoding-context) idx)
  "Emits command to remove current index from working set."
  (list :name (1+ idx) :type :indexed))

(defmethod size-check ((encoding-context encoding-context) cmd)
  "Before doing such a modification, it has to be ensured that the header
table size will stay lower than or equal to the
SETTINGS_HEADER_TABLE_SIZE limit. To achieve this, repeatedly, the
first entry of the header table is removed, until enough space is
available for the modification.

A consequence of removing one or more entries at the beginning of the
header table is that the remaining entries are renumbered.  The first
entry of the header table is always associated to the index 1."
  (with-slots (table limit refset) encoding-context
    (flet ((entry-size (header)
	     (if (null header)  ; for limit resize commands
		 0
		 (+ (length (car header)) (length (cdr header)) 32))))
      (let ((cursize (loop for header in table sum (entry-size header)))
	    (cmdsize (entry-size (cons (getf cmd :name) (getf cmd :value))))
	    ok-to-add
	    evicted)

	;; The addition of a new entry with a size greater than the
	;; SETTINGS_HEADER_TABLE_SIZE limit causes all the entries from the
	;; header table to be dropped and the new entry not to be added to the
	;; header table.
	(if (> cmdsize limit)
	    ;; too big, dump table and refset by evicting all
	    (setf ok-to-add nil
		  evicted table
		  table nil
		  (fill-pointer refset) 0)
	    ;; could fit, evcit one or more entries from end of table
	    (progn
	      (setf ok-to-add t)
	      (while (> (+ cursize cmdsize) limit)
		(let* ((idx (1- (length table)))
		       (e (shift table)))
		  (decf cursize (entry-size e))
		  (push e evicted)
		  (loop
		     for i from 0
		     for r across refset
		     if (= (car r) idx)
		     do (vector-delete-at refset i))))))

	(values ok-to-add evicted)))))

(defmethod activep ((encoding-context encoding-context) idx)
  (with-slots (refset) encoding-context
    (not (null (find idx refset :key #'car :test #'equal)))))

(defparameter *headrep*
  '(:indexed      (:prefix 7 :pattern #x80)
    :noindex      (:prefix 4 :pattern #x00)
    :incremental  (:prefix 6 :pattern #x40)
    :neverindex   (:prefix 4 :pattern #x10)
    :context      (:prefix 5 :pattern #x20))
  "Header representation as defined by the spec.")

(defparameter *resetrep*
  '(:reset        (:prefix 7 :pattern #x80)
    :new-max-size (:prefix 7 :pattern #x00)))

(defparameter *contextrep*
  '(:reset        (:prefix 4 :pattern #x10)
    :new-max-size (:prefix 4 :pattern #x00)))

; Responsible for encoding header key-value pairs using HPACK algorithm.
; Compressor must be initialized with appropriate starting context based
; on local role: client or server.
(defclass compressor ()
  ((cc-type :initarg :type)
   (cc)))

(defmethod initialize-instance :after ((compressor compressor) &key)
  (with-slots (cc cc-type) compressor
    (setf cc (make-instance 'encoding-context :type cc-type))))

(defmethod @integer ((compressor compressor) i n)
  "Encodes provided value via integer representation.
 - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-03#section-4.1.1

  If I < 2^N - 1, encode I on N bits
  Else
      encode 2^N - 1 on N bits
      I = I - (2^N - 1)
      While I >= 128
           Encode (I % 128 + 128) on 8 bits
           I = I / 128
      encode (I) on 8 bits"
  (let ((limit (1- (expt 2 n))))
    (when (< i limit)
      (return-from @integer (pack "B" i :array (make-array 64 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))))
    
    (let ((bytes (make-array 64 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
      (when (not (zerop n))
	(vector-push-extend limit bytes))

      (decf i limit)
      (while (>= i 128)
	(vector-push-extend (+ (mod i 128) 128) bytes)
	(setf i (ash i -7)))
      
      (vector-push-extend i bytes)
      bytes)))

(defmethod @string ((compressor compressor) str)
  "Encodes provided value via string literal representation.
 - http://tools.ietf.org/html/draft-ietf-httpbis-header-compression-03#section-4.1.3

 * The string length, defined as the number of bytes needed to store
   its UTF-8 representation, is represented as an integer with a zero
   bits prefix. If the string length is strictly less than 128, it is
   represented as one byte.
 * The string value represented as a list of UTF-8 character"
  (let ((bytes (@integer compressor (length str) 7)))
    (loop for char across str do (vector-push-extend (char-code char) bytes))
    bytes))

(defmethod header ((compressor compressor) h &optional (buffer (make-instance 'buffer)))
  (macrolet ((<<integer (i n) `(buffer<< buffer (@integer compressor ,i ,n)))
	     (<<string (s) `(buffer<< buffer (@string compressor ,s)))
	     (+pattern (b p) (with-gensyms (b*) `(let ((,b* ,b)) (setf (aref ,b* 0) (logior (aref ,b* 0) ,p)) ,b*)))
	     (<<integer+ (i n p) `(buffer<< buffer (+pattern (@integer compressor ,i ,n) ,p))))

    (let ((rep (getf *headrep* (getf h :type))))
      (macrolet ((firstinteger (&rest cmd) `(<<integer+ ,@(cdar cmd) (getf rep :pattern))))

	(if (eq (getf h :type) :context)
	    (let ((crep (getf *contextrep* (getf h :context-type))))
	      (firstinteger (+pattern (<<integer (or (getf h :value) 0) (getf crep :prefix)) (getf crep :pattern))))

	    (if (eq (getf h :type) :indexed)
		(firstinteger (<<integer (getf h :name) (getf rep :prefix)))

		(progn
		  (if (integerp (getf h :name))
		      (firstinteger (<<integer (getf h :name) (getf rep :prefix)))
		      (progn
			(firstinteger (<<integer 0 (getf rep :prefix)))
			(<<string (getf h :name))))
	    
		  (if (integerp (getf h :value))
		      (<<integer (getf h :value) 0)
		      (<<string (getf h :value)))))))))

  buffer)

(defmethod split-cookies ((compressor compressor) headers)
  (if (find "cookie" headers :key #'car :test #'string=)
      (loop
	 with new-headers = nil
	 for header in headers
	 for (k . v) = header
	 if (string= k "cookie")
	 do (dolist (v* (split-if (lambda (c) (or (char= c #\;) (char= c #\Space) (char= c #\Null))) v))
	      (push (cons k v*) new-headers))
	 else
	 do (push header new-headers)
	 finally (return (nreverse new-headers)))
      headers))

(defmethod combine ((compress compressor) headers)
  ; this code is longer than necessary because it optimizes speed and memory for no/few duplicates
  ; in the case of no duplicates, there is no cons'ing and headers is simply returned with one pass
  ; as duplicates are found some structures grow, and a second pass is necessary to cons up the structure
  ; individual header cons's will be reused in the new structure if they are not dup's
  (loop
     with dups = nil   ; each entry is a list: the original index integer, followed by all values
     with dupidx = nil ; each entry is an index integer
     with l = (length headers)
     for i below l
     for current-start on headers
     for (current-k . current-v) = (car current-start)
     if (and (not (find i dupidx :test #'=))
	     (not (string= current-k "set-cookie")))
     do (loop
	   for j from (1+ i) below l
	   for (k . v) in (cdr current-start)
	   when (string= k current-k)
	   collect j into js and
	   collect v into vs
	   finally (when js
		     (push (cons i (cons current-v vs)) dups)
		     (nconc dupidx (cons i js))))
     finally (return (if dups
			 (loop
			    for i below l
			    for dup = (find i dups :key #'car :test #'=)
			    for header in headers
			    if dup
			    collect (cons (car header) (format nil #.(format nil "~~{~~A~~^~C~~}" #\Null) (cdr dup)))
			    else
			    unless (find i dupidx :test #'=)
			    collect header)
			 headers))))

(defmethod preprocess ((compressor compressor) headers)
  (split-cookies compressor (combine compressor headers)))

(defmethod encode ((compressor compressor) headers)
  "Encodes provided list of HTTP headers."
  (with-slots (cc) compressor
    (with-slots (refset) cc
      (let ((buffer (make-instance 'buffer))
	    commands)
    
	; Literal header names MUST be translated to lowercase before
	; encoding and transmission.
	; (setf headers (mapcar (lambda (h) (cons (string-downcase (car h)) (cdr h))) headers))

	(let ((starting-refset (copy-seq refset))
	      evicted)
	  ; Generate remove commands for missing headers
	  (loop
	     for (idx . header-pair) across starting-refset
	     if (not (find header-pair headers :test #'equal))
	     do (let ((cmd (remove-cmd cc idx)))
		  (push cmd commands)
		  (process cc cmd)))

	  ; Generate add commands for new headers
	  (loop
	     for header-pair in headers
	     if (not (find header-pair starting-refset :key #'cdr :test #'equal))
	     do (let ((cmd (add-cmd cc header-pair)))
		  (push cmd commands)
		  (multiple-value-bind (emit this-evicted)
		      (process cc cmd)
		    (declare (ignore emit))
		    (when this-evicted
		      (appendf evicted this-evicted)))))

	  (loop
	     repeat 10  ; sanity
	     while evicted
	     do (loop
		   with evicted2 = nil
		   for header-pair in evicted
		   if (find header-pair headers :test #'equal)
		   do (let ((cmd (add-cmd cc header-pair)))
			(push cmd commands)
			(multiple-value-bind (emit this-evicted)
			    (process cc cmd)
			  (declare (ignore emit))
			  (when this-evicted
			    (appendf evicted2 this-evicted))))
		   finally (setf evicted evicted2))))
	
	(dolist (cmd (nreverse commands) buffer)
	  (buffer<< buffer (header compressor cmd)))))))

(defclass decompressor ()
  ((cc-type :initarg :type)
   (cc)))

(defmethod initialize-instance :after ((decompressor decompressor) &key)
  (with-slots (cc cc-type) decompressor
    (setf cc (make-instance 'encoding-context :type cc-type))))

(defmethod @integer ((decompressor decompressor) buf n)
  "Decodes integer value from provided buffer."
  (let* ((limit (1- (expt 2 n)))
	 (i (if (not (zerop n))
		(logand (buffer-getbyte buf) limit)
		0))
	 (m 0))

    (when (= i limit)
      (while-let (byte (buffer-getbyte buf))
	(incf i (ash (logand byte 127) m))
	(incf m 7)
	(when (zerop (logand byte 128))
	  (return))))

    i))

(defmethod @string ((decompressor decompressor) buf)
  "Decodes string value from provided buffer."
  (let* ((peek (buffer-getbyte buf nil))
	 (huffman-p (logbitp 7 peek))
	 (length (@integer decompressor buf 7))
	 (bytes (buffer-read buf length)))
    (if huffman-p
	(huffman-decode-buffer-to-string bytes length)
	(handler-case
	    (buffer-string bytes)
	  (babel-encodings:character-decoding-error ()
	    (when *debug-mode*
	      (warn "UTF-8 failed: ~S" (buffer-data bytes)))
	    (buffer-ascii bytes))))))

(defmethod header ((decompressor decompressor) buf &optional header)
  "Decodes header command from provided buffer."
  (let ((peek (buffer-getbyte buf nil)))

    (let (type regular-p)
      (loop
	 for (tt desc) on *headrep* by #'cddr
	 for prefix = (getf desc :prefix)
	 for mask = (ash (ash peek (- prefix)) prefix)
	 if (= mask (getf desc :pattern))
	 do (progn
	      (setf (getf header :type) tt
		    regular-p (not (eq tt :context))
		    type desc)
	      (return)))

      (if regular-p
	  (progn
	    (setf (getf header :name) (@integer decompressor buf (getf type :prefix)))
	    (when (not (eq (getf header :type) :indexed))
	      (when (zerop (getf header :name))
		(setf (getf header :name) (@string decompressor buf)))
	      (setf (getf header :value) (@string decompressor buf))))

	  ;; else context update (:reset/:new-max-size):
	  (let ((peek-short (logand peek (1- (expt 2 (getf type :prefix)))))
		ctype)
	    (setf (getf header :type) :context)
	    (loop
	       for (ct cdesc) on *contextrep* by #'cddr
	       for prefix = (getf cdesc :prefix)
	       for mask = (ash (ash peek-short (- prefix)) prefix)
	       if (= mask (getf cdesc :pattern))
	       do (progn
		    (setf (getf header :context-type) ct
			  ctype cdesc)
		    (return)))
	    (setf (getf header :value) (@integer decompressor buf (getf ctype :prefix)))))

      header)))

(defmethod join-cookies ((decompressor decompressor) headers)
  (if (loop
	 for (k . v) on headers
	 count (string= (car k) "cookie") into c
	 if (= 2 c) do (return t)
	 finally (return nil))
      (loop
	 with new-headers = nil
	 with cookie-values = nil
	 for header in headers
	 for (k . v) = header
	 if (string= k "cookie")
	 do (push v cookie-values)
	 else
	 do (push header new-headers)
	 finally (progn
		   (push (cons "cookie" (format nil "~{~A~^; ~}" cookie-values)) new-headers)
		   (return (nreverse new-headers))))
      headers))

(defmethod postprocess ((decompressor decompressor) headers)
  (join-cookies decompressor headers))

(defmethod decode ((decompressor decompressor) buf)
  "Decodes and processes header commands within provided buffer.

Once all the representations contained in a header block have been
processed, the headers that are in common with the previous header
set are emitted, during the reference set emission.

For the reference set emission, each header contained in the
reference set that has not been emitted during the processing of the
header block is emitted."
  (with-slots (cc) decompressor
    (let (set)
      (while (not (buffer-empty-p buf))
	(push (process cc (header decompressor buf)) set))
      (loop
	 for (i . header) across (refset cc)
	 if (not (find header set :test #'equal))
	 do (push header set))

      (delete-if #'null (nreverse set)))))
