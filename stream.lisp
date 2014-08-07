; Copyright (c) 2014 Akamai Technologies, Inc. (MIT License)

(in-package :cl-http2-protocol)

; A single HTTP 2.0 connection can multiplex multiple streams in parallel:
; multiple requests and responses can be in flight simultaneously and stream
; data can be interleaved and prioritized.
;
; This class encapsulates all of the state, transition, flow-control, and
; error management as defined by the HTTP 2.0 specification. All you have
; to do is subscribe to appropriate events (marked with ":" prefix in
; diagram below) and provide your application logic to handle request
; and response processing.
;
;                         +--------+
;                    PP   |        |   PP
;                ,--------|  idle  |--------.
;               /         |        |         \
;              v          +--------+          v
;       +----------+          |           +----------+
;       |          |          | H         |          |
;   ,---|:reserved |          |           |:reserved |---.
;   |   | (local)  |          v           | (remote) |   |
;   |   +----------+      +--------+      +----------+   |
;   |      | :active      |        |      :active |      |
;   |      |      ,-------|:active |-------.      |      |
;   |      | H   /   ES   |        |   ES   \   H |      |
;   |      v    v         +--------+         v    v      |
;   |   +-----------+          |          +-_---------+  |
;   |   |:half_close|          |          |:half_close|  |
;   |   |  (remote) |          |          |  (local)  |  |
;   |   +-----------+          |          +-----------+  |
;   |        |                 v                |        |
;   |        |    ES/R    +--------+    ES/R    |        |
;   |        `----------->|        |<-----------'        |
;   | R                   | :close |                   R |
;   `-------------------->|        |<--------------------'
;                         +--------+

(defclass stream (flowbuffer-include emitter-include error-include)
  ((id :reader stream-id :initarg :id :type integer
       :documentation "Stream ID (odd for client initiated streams, even otherwise).")
   (connection :reader stream-connection :initarg :connection :type connection
	       :documentation "The parent connection of the stream.")
   (priority :reader stream-priority :initarg :priority :type integer
	     :initform 0
	     :documentation "Stream priority weight as set by initiator.")
   (dependency :accessor stream-dependency :initarg :dependency :type (or null stream)
	       :initform nil
	       :documentation "Stream dependency as set by initiator.")
   (window :reader stream-window :initarg :window :type (or integer float)
	   :documentation "Size of current stream flow control window.")
   (parent :reader stream-parent :initarg :parent :initform nil :type (or null stream)
	   :documentation "Request parent stream of push stream.")
   (state :reader stream-state :initform :idle
	  :type (member :idle :open :reserved-local :reserved-remote
			:half-closed-local :half-closed-remote
			:local-closed :remote-closed
			:local-rst :remote-rst
			:half-closing :closing :closed)
	  :documentation "Stream state as defined by HTTP 2.0.")
   (error :reader stream-error-type :initform nil)
   (closed :reader stream-closed :initform nil
	   :documentation "Reason why connection was closed.")
   (send-buffer :initform nil)
   (queue :initform nil)))

; Note that you should never have to call MAKE-INSTANCE directly. To
; create a new client initiated stream, use (DEFMETHOD NEW-STREAM
; (CONNECTION ...)). Similarly, CONNECTION will emit new stream
; objects, when new stream frames are received.

(defmethod initialize-instance :after ((stream stream) &key)
  (with-slots (window) stream
    (on stream :window (lambda (v) (setf window v)))))

(defmethod print-object ((stream stream) print-stream)
  (with-slots (id) stream
    (print-unreadable-object (stream print-stream :type t :identity t)
      (format print-stream ":STREAM ~D" id))))

(defmethod update-priority ((stream stream) frame)
  (with-slots (priority dependency connection) stream
    (setf priority (getf frame :weight))
    (let ((dep-id (getf frame :stream-dependency))
	  (exclusive (getf frame :exclusive-dependency)))
      (when (and dep-id (plusp dep-id))
	(with-slots (streams) connection
	  (when-let ((dep-stream (gethash dep-id streams)))
	    (dohash (key other-stream streams)
	      (when (eq (stream-dependency other-stream) dep-stream)
		(setf (stream-dependency other-stream) stream)))
	    (setf dependency dep-stream))))
      (values priority dependency exclusive))))

(defmethod receive ((stream stream) frame)
  "Processes incoming HTTP 2.0 frames. The frames must be decoded upstream."
  (with-slots (priority dependency window id connection) stream
    (transition stream frame nil)

    (case (getf frame :type)
      (:data
       (when (not (getf frame :ignore))
	 (emit stream :data frame)))
      ((:headers :push-promise)
       (when (member :priority (getf frame :flags))
	 (update-priority stream frame))
       (if (listp (getf frame :payload))
	   (when (not (getf frame :ignore))
	     (emit stream :headers (plist-alist (flatten (getf frame :payload)))))
	   (when (not (getf frame :ignore))
	     (emit stream :headers (getf frame :payload)))))
      (:priority
       (multiple-value-bind (p d e)
	   (update-priority stream frame)
	 (emit stream :priority p d e)))
      (:window-update
       (incf window (getf frame :increment))
       (drain-send-buffer stream))
      (:extensible
       (emit stream :extensible frame))
      (:experimental
       (emit stream :experimental frame)))

    (complete-transition stream frame)))

(defmethod send ((stream stream) frame)
  "Processes outgoing HTTP 2.0 frames. Data frames may be automatically
split and buffered based on maximum frame size and current stream flow
control window size."
  (with-slots (id priority) stream
    (transition stream frame t)
    (ensuref (getf frame :stream) id)
    
    (when (eq (getf frame :type) :priority)
      (setf priority (getf frame :weight)))

    (if (eq (getf frame :type) :data)
	(send-data stream frame)
	(emit stream :frame frame))

    (complete-transition stream frame)))

(defmethod enqueue ((stream stream) frame)
  (assert (or (and (listp frame) (member :type frame)) (functionp frame)) (frame) "Not a frame or function: ~S" frame)
  (with-slots (queue) stream
    (push frame queue)))

(defmethod queue-populated-p ((stream stream))
  (with-slots (queue) stream
    (not (null queue))))

(defmethod headers ((stream stream) headers &key (end-headers t) (end-stream nil) (action :send))
  "Sends a HEADERS frame containing HTTP response headers."
  (let ((frame (list :type :headers
		     :flags `(,@(if end-headers '(:end-headers)) ,@(if end-stream '(:end-stream)))
		     :payload headers)))
    (case action
      (:send    (send stream frame))
      (:enqueue (enqueue stream frame))
      (:return  (list frame)))))

(defmethod promise ((stream stream) headers &optional (end-headers t) block)
  (when (null block)
    (error "must provide callback"))

  (let ((flags (if end-headers (list :end-headers) nil)))
    (emit stream :promise stream headers flags block)))

(defmethod reprioritize ((stream stream) p)
  "Sends a PRIORITY frame with new stream priority value (can only be
performed by the client)."
  (with-slots (id) stream
    (when (evenp id)
      (stream-error stream))
    (send stream (list :type :priority :priority p))))

(defmethod data ((stream stream) payload &key (end-stream t) (action :send))
  "Sends DATA frame containing response payload."
  (let (frames)
    (when (bufferp payload)
      (while (> (buffer-size payload) *max-payload-size*)
	(let ((chunk (buffer-slice! payload 0 *max-payload-size*)))
	  (push (list :type :data :payload chunk) frames))))
    (push (list :type :data :flags (if end-stream '(:end-stream)) :payload payload) frames)
    (let ((frames* (nreverse frames)))
      (case action
	(:send    (dolist (frame frames*) (send stream frame)))
	(:enqueue (dolist (frame frames*) (enqueue stream frame)))
	(:return  frames*)))))

(defmethod pump-queue ((stream stream) n)
  (with-slots (queue state) stream
    (while-max queue n
      (let ((frame (shift queue)))
	(when (not (functionp frame))
	  (assert (member :type frame) (frame) "Frame is not a frame: ~S" frame))
	(when (functionp frame)
	  (let* ((callback frame))
	    (multiple-value-bind (yielded call-again-p)
		(funcall callback)
	      (when yielded
		(when-let (frames (funcall yielded stream))
		  (assert (every (lambda (f) (member :type f)) frames) (frames) "Frames contains a non-frame: ~S" frames)
		  (setf frame (first frames))
		  (dolist (additional-frame (reverse (rest frames)))
		    (assert (member :type additional-frame) (additional-frame) "Frame is not a frame: ~S" additional-frame)
		    (unshift additional-frame queue))))
	      (when call-again-p
		(unshift callback queue)))))
	(when (listp frame)
	  (assert (member :type frame) (frame) "Frame is not a frame: ~S" frame)
	  ; (format t "(pump-queue ~A):~%  (send ~A ~S)~%" stream stream frame)
	  (send stream frame)
	  ;; most implementations seem to nudge the other side after ending headers
	  (when (and (endp queue)
		     (member :end-stream (getf frame :flags))
		     (not (eq state :closed)))
	    (nudge stream)))))))

(defmethod stream-close ((stream stream) &optional (error :stream-closed)) ; @ ***
  "Sends a RST_STREAM frame which closes current stream - this does not
close the underlying connection."
  (send stream (list :type :rst-stream :error error)))

(defmethod cancel ((stream stream))
  "Sends a RST_STREAM indicating that the stream is no longer needed."
  (send stream (list :type :rst-stream :error :cancel)))

(defmethod refuse ((stream stream))
  "Sends a RST_STREAM indicating that the stream has been refused prior
to performing any application processing."
  (send stream (list :type :rst-stream :error :refused-stream)))

(defmethod restrict ((stream stream))
  "Issue ENHANCE_YOUR_CALM to peer."
  (send stream (list :type :rst-stream :error :ehance-your-calm)))

(defmethod nudge ((stream stream))
  "Send a nominal WINDOW_UPDATE just to wake up the peer."
  (send stream (list :type :window-update :flags nil :increment 1)))

(defmethod ranged-frame ((stream stream) type (type-code number) flags payload)
  "Send a frame that uses one of the extensible range type codes."
  (destructuring-bind (min . max) (getf *frame-types* type)
    (if (<= min type-code max)
	(send stream (list :type type :type-code type-code :flags flags :payload payload))
	(error "Type code (~A) is out of range (~D-~D) for type ~A." type-code min max type))))

(defmethod extensible ((stream stream) (type-code number) flags payload)
  "Send a frame that uses one of the extensible range type codes."
  (ranged-frame stream :extensible type-code flags payload))

(defmethod experimental ((stream stream) (type-code number) flags payload)
  "Send a frame that uses one of the extensible range type codes."
  (ranged-frame stream :experimental type-code flags payload))

(defmethod connected ((stream stream))
  "Marks a stream as a successful CONNECT method stream where the 2xx
success headers have been sent and the stream is ready for DATA frames."
  (format t "(connected ~S)~%" stream)
  (change-class stream 'connect-stream))

; HTTP 2.0 Stream States
; - http://tools.ietf.org/html/draft-ietf-httpbis-http2-05#section-5
;
;                       +--------+
;                 PP    |        |    PP
;              ,--------|  idle  |--------.
;             /         |        |         \
;            v          +--------+          v
;     +----------+          |           +----------+
;     |          |          | H         |          |
; ,---| reserved |          |           | reserved |---.
; |   | (local)  |          v           | (remote) |   |
; |   +----------+      +--------+      +----------+   |
; |      |          ES  |        |  ES          |      |
; |      | H    ,-------|  open  |-------.      | H    |
; |      |     /        |        |        \     |      |
; |      v    v         +--------+         v    v      |
; |   +----------+          |           +----------+   |
; |   |   half   |          |           |   half   |   |
; |   |  closed  |          | R         |  closed  |   |
; |   | (remote) |          |           | (local)  |   |
; |   +----------+          |           +----------+   |
; |        |                v                 |        |
; |        |  ES / R    +--------+  ES / R    |        |
; |        `----------->|        |<-----------'        |
; |  R                  | closed |                  R  |
; `-------------------->|        |<--------------------'
;                       +--------+
;
(defmethod transition ((stream stream) frame sending)
  (with-slots (state closed) stream
    (case state
      ; All streams start in the "idle" state.  In this state, no frames
      ; have been exchanged.
      ; *  Sending or receiving a HEADERS frame causes the stream to
      ;    become "open".  The stream identifier is selected as described
      ;    in Section 5.1.1.
      ; *  Sending a PUSH_PROMISE frame marks the associated stream for
      ;    later use.  The stream state for the reserved stream
      ;    transitions to "reserved (local)".
      ; *  Receiving a PUSH_PROMISE frame marks the associated stream as
      ;    reserved by the remote peer.  The state of the stream becomes
      ;    "reserved (remote)".
      (:idle
       (if sending
	   (case (getf frame :type)
	     (:push-promise
	      (event stream :reserved-local))
	     (:headers
	      (if (end-stream-p stream frame)
		  (event stream :half-closed-local)
		  (event stream :open)))
	     (:rst-stream
	      (event stream :local-rst))
	     (otherwise
	      (stream-error stream)))
	   (case (getf frame :type)
	     (:push-promise
	      (event stream :reserved-remote))
	     (:headers
	      (if (end-stream-p stream frame)
		  (event stream :half-closed-remote)
		  (event stream :open)))
	     (otherwise
	      (stream-error stream :type :protocol-error)))))

      ; A stream in the "reserved (local)" state is one that has been
      ; promised by sending a PUSH_PROMISE frame.  A PUSH_PROMISE frame
      ; reserves an idle stream by associating the stream with an open
      ; stream that was initiated by the remote peer (see Section 8.2).
      ; *  The endpoint can send a HEADERS frame.  This causes the stream
      ;    to open in a "half closed (remote)" state.
      ; *  Either endpoint can send a RST_STREAM frame to cause the stream
      ;    to become "closed".  This also releases the stream reservation.
      ; An endpoint MUST NOT send any other type of frame in this state.
      ; Receiving any frame other than RST_STREAM or PRIORITY MUST be
      ; treated as a connection error (Section 5.4.1) of type
      ; PROTOCOL_ERROR.
      (:reserved-local
       (if sending
	   (setf state (case (getf frame :type)
			 (:headers (event stream :half-closed-remote))
			 (:rst-stream (event stream :local-rst))
			 (otherwise (stream-error stream))))
	   (setf state (case (getf frame :type)
			 (:rst-stream (event stream :remote-rst))
			 (:priority state)
			 (otherwise (stream-error stream))))))
      
      ; A stream in the "reserved (remote)" state has been reserved by a
      ; remote peer.
      ; *  Receiving a HEADERS frame causes the stream to transition to
      ;    "half closed (local)".
      ; *  Either endpoint can send a RST_STREAM frame to cause the stream
      ;    to become "closed".  This also releases the stream reservation.
      ; Receiving any other type of frame MUST be treated as a stream
      ; error (Section 5.4.2) of type PROTOCOL_ERROR.  An endpoint MAY
      ; send RST_STREAM or PRIORITY frames in this state to cancel or
      ; reprioritize the reserved stream.
      (:reserved-remote
       (if sending
	   (setf state (case (getf frame :type)
			 (:rst-stream (event stream :local-rst))
			 (:priority state)
			 (otherwise (stream-error stream))))
	   (setf state (case (getf frame :type)
			 (:headers (event stream :half-closed-local))
			 (:rst-stream (event stream :remote-rst))
			 (otherwise (stream-error stream))))))
      
      ; The "open" state is where both peers can send frames of any type.
      ; In this state, sending peers observe advertised stream level flow
      ; control limits (Section 5.2).
      ; * From this state either endpoint can send a frame with a END_STREAM
      ;   flag set, which causes the stream to transition into one of the
      ;   "half closed" states: an endpoint sending a END_STREAM flag causes
      ;   the stream state to become "half closed (local)"; an endpoint
      ;   receiving a END_STREAM flag causes the stream state to become
      ;   "half closed (remote)".
      ; * Either endpoint can send a RST_STREAM frame from this state,
      ;   causing it to transition immediately to "closed".
      (:open
       (if sending
	   (case (getf frame :type)
	     ((:data :headers)
	      (when (end-stream-p stream frame)
		(event stream :half-closed-local)))
	     (:rst-stream
	      (event stream :local-rst)))
	   (case (getf frame :type)
	     ((:data :headers)
	      (when (end-stream-p stream frame)
		(event stream :half-closed-remote)))
	     (:rst-stream
	      (event stream :remote-rst)))))
      
      ; A stream that is "half closed (local)" cannot be used for sending
      ; frames.
      ; A stream transitions from this state to "closed" when a frame that
      ; contains a END_STREAM flag is received, or when either peer sends
      ; a RST_STREAM frame.
      ; A receiver can ignore WINDOW_UPDATE or PRIORITY frames in this
      ; state.  These frame types might arrive for a short period after a
      ; frame bearing the END_STREAM flag is sent.
      (:half-closed-local
       (if sending
	   (case (getf frame :type)
	     (:rst-stream
	      (event stream :local-rst))
	     (:window-update
	      nil)
	     (t
	      (stream-error stream)))
	   (case (getf frame :type)
	     ((:data :headers)
	      (when (end-stream-p stream frame)
		(event stream :remote-closed)))
	     (:rst-stream
	      (event stream :remote-rst))
	     ((:window-update :priority)
	      (setf (getf frame :ignore) t)))))

      ; A stream that is "half closed (remote)" is no longer being used by
      ; the peer to send frames.  In this state, an endpoint is no longer
      ; obligated to maintain a receiver flow control window if it
      ; performs flow control.
      ; If an endpoint receives additional frames for a stream that is in
      ; this state it MUST respond with a stream error (Section 5.4.2) of
      ; type STREAM_CLOSED.
      ; A stream can transition from this state to "closed" by sending a
      ; frame that contains a END_STREAM flag, or when either peer sends a
      ; RST_STREAM frame.
      (:half-closed-remote
       (if sending
	   (case (getf frame :type)
	     ((:data :headers)
	      (when (end-stream-p stream frame)
		(event stream :local-closed)))
	     (:rst-stream
	      (event stream :local-rst)))
	   (case (getf frame :type)
	     (:rst-stream
	      (event stream :remote-rst))
	     (:window-update
	      (setf (getf frame :ignore) t))
	     (:priority nil)
	     (otherwise
	      (stream-error stream :type :stream-closed)))))

      ; An endpoint MUST NOT send frames on a closed stream. An endpoint
      ; that receives a frame after receiving a RST_STREAM or a frame
      ; containing a END_STREAM flag on that stream MUST treat that as a
      ; stream error (Section 5.4.2) of type STREAM_CLOSED.
      ;
      ; WINDOW_UPDATE or PRIORITY frames can be received in this state for
      ; a short period after a a frame containing an END_STREAM flag is
      ; sent.  Until the remote peer receives and processes the frame
      ; bearing the END_STREAM flag, it might send either frame type.
      ;
      ; If this state is reached as a result of sending a RST_STREAM
      ; frame, the peer that receives the RST_STREAM might have already
      ; sent - or enqueued for sending - frames on the stream that cannot
      ; be withdrawn. An endpoint MUST ignore frames that it receives on
      ; closed streams after it has sent a RST_STREAM frame.
      ;
      ; An endpoint might receive a PUSH_PROMISE or a CONTINUATION frame
      ; after it sends RST_STREAM. PUSH_PROMISE causes a stream to become
      ; "reserved". If promised streams are not desired, a RST_STREAM can
      ; be used to close any of those streams.
      (:closed
       (if sending
	   (case (getf frame :type)
	     ((:rst-stream :priority) nil)
	     (otherwise
	      (stream-error stream :type :stream-closed)))
	   (case closed
	     ((:remote-rst :remote-closed)
	      (case (getf frame :type)
		((:rst-stream :priority) nil)
		(otherwise
		 (stream-error stream :type :stream-closed))))
	     ((:local-rst :local-closed)
	      (setf (getf frame :ignore) t))))))))

(defmethod event ((stream stream) newstate)
  (with-slots (state closed) stream
    (case newstate
      (:open
       (setf state newstate)
       (emit stream :active))
      ((:reserved-local :reserved-remote)
       (setf state newstate)
       (emit stream :reserved))
      ((:half-closed-local :half-closed-remote)
       (setf closed newstate)
       (unless (eq state :open)
	 (emit stream :active))
       (setf state :half-closing))
      ((:local-closed :remote-closed :local-rst :remote-rst)
       (setf closed newstate)
       (setf state :closing)))
    state))

(defmethod complete-transition ((stream stream) frame)
  (with-slots (state closed) stream
    (case state
      (:closing
       (setf state :closed)
       (emit stream :close (getf frame :error)))
      (:half-closing
       (setf state closed)
       (emit stream :half-close)))))

(defmethod end-stream-p ((stream stream) frame)
  (case (getf frame :type)
    ((:data :headers)
     (if (member :end-stream (getf frame :flags)) t nil))
    (otherwise nil)))

(defmethod stream-error ((stream stream) &key (type :stream-error) (msg "Stream error"))
  (with-slots (error state) stream
    (setf error type)
    (when (not (eq state :closed))
      (stream-close stream (if (eq type :stream-error) :protocol-error type)))

    (raise (find-symbol (concatenate 'string "HTTP2-" (symbol-name type))) msg)))

(defclass connect-stream (stream) ()
  (:documentation "Subclass of STREAM for CONNECT method."))

(defparameter *allowed-connect-stream-frame-types* '(:data :rst-stream :window-update :priority))

(defmethod receive :before ((stream connect-stream) frame)
  (unless (member (getf frame :type) *allowed-connect-stream-frame-types*)
    (stream-error stream :msg "Disallowed frame on CONNECT stream.")))

(defmethod send :before ((stream connect-stream) frame)
  (unless (member (getf frame :type) *allowed-connect-stream-frame-types*)
    (stream-error stream :msg "Disallowed frame on CONNECT stream.")))
