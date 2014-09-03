; Copyright (c) 2014 Akamai Technologies, Inc. (MIT License)

;; Add & override some functions in CL-ASYNC-SSL
(in-package :cl-async-ssl)

(defun init-ssl-npn (type ssl-ctx npn)
  "Setup NPN (next protocol negotiation) on an SSL context.
Returns a cleanup closure to be called upon disconnect."
  (check-type npn list)
  (let ((spec-str (format nil "~{~C~A~}" (loop for p in npn collect (code-char (length p)) collect p))))
    (ecase type
      (:server
       (let ((npn-arg-fo (cffi:foreign-alloc '(:struct cl+ssl::server-tlsextnextprotoctx)))
	     (npn-str-fo (cffi:foreign-string-alloc spec-str)))
	 (cffi:with-foreign-slots ((cl+ssl::data cl+ssl::len) npn-arg-fo (:struct cl+ssl::server-tlsextnextprotoctx))
	   (setf cl+ssl::data npn-str-fo
		 cl+ssl::len (length spec-str)))
	 (cl+ssl::ssl-ctx-set-next-protos-advertised-cb ssl-ctx
							(cffi:callback cl+ssl::lisp-server-next-proto-cb)
							npn-arg-fo)
	 (lambda ()
	   (cffi:foreign-free npn-arg-fo)
	   (cffi:foreign-string-free npn-str-fo))))
      (:client
       (let ((npn-arg-fo (cffi:foreign-alloc '(:struct cl+ssl::client-tlsextnextprotoctx)))
	     (npn-str-fo (cffi:foreign-string-alloc spec-str)))
	 (cffi:with-foreign-slots ((cl+ssl::data cl+ssl::len) npn-arg-fo (:struct cl+ssl::client-tlsextnextprotoctx))
	   (setf cl+ssl::data npn-str-fo
		 cl+ssl::len (length spec-str)))
	 (cl+ssl::ssl-ctx-set-next-proto-select-cb ssl-ctx ; cl+ssl::*ssl-global-context*
						   (cffi:callback cl+ssl::lisp-client-next-proto-cb)
						   npn-arg-fo)
	 (lambda ()
	   (cffi:foreign-free npn-arg-fo)
	   (cffi:foreign-string-free npn-str-fo)))))))

(defun init-ssl-sni (type ssl-ctx servername)
  "Setup SNI (server name identification) on an SSL context.
Returns a cleanup closure to be called upon disconnect."
  (check-type servername string)
  (ecase type
    ;; server not implemented
    (:client
     (let ((sni-fo (cffi:foreign-alloc '(:struct cl+ssl::tlsextctx)))
	   (sni-str-fo (cffi:foreign-string-alloc servername)))
       (cffi:with-foreign-slots ((cl+ssl::biodebug) sni-fo (:struct cl+ssl::tlsextctx))
	 ;; (setf cl+ssl::biodebug (cffi:null-pointer))
	 ;; (cl+ssl::ssl-ctx-set-tlsext-servername-callback ssl-ctx (cffi:callback cl+ssl::lisp-ssl-servername-cb))
	 ;; (cl+ssl::ssl-ctx-set-tlsext-servername-arg ssl-ctx sni-fo)
	 ;; (cl+ssl::ssl-set-tlsext-host-name ssl-ctx sni-str-fo)
	 )
       (lambda ()
	 (cffi:foreign-free sni-fo)
	 (cffi:foreign-string-free sni-str-fo))))))

;; Add SSL-METHOD and DHPARAMS key parameters
(defun tcp-ssl-server (bind-address port read-cb event-cb
                       &key connect-cb (backlog -1) stream
                            (ssl-method 'cl+ssl::ssl-v23-server-method)
			    certificate key password dhparams npn)
  "Start a TCP listener, and wrap incoming connections in an SSL handler.
   Returns a tcp-server object, which can be closed with close-tcp-server.

   If you need a self-signed cert/key to test with:
     openssl genrsa -out pkey 2048
     openssl req -new -key pkey -out cert.req
     openssl x509 -req -days 3650 -in cert.req -signkey pkey -out cert"
  ;; make sure SSL is initialized
  (cl+ssl:ensure-initialized :method ssl-method)

  ;; create the server and grab its data-pointer
  (let* ((server (tcp-server bind-address port
                             read-cb event-cb
                             :connect-cb connect-cb
                             :backlog backlog
                             :stream stream))
         (data-pointer (tcp-server-data-pointer server)))
    ;; overwrite the accept callback from tcp-accept-cb -> tcp-ssl-accept-cb
    (le:evconnlistener-set-cb (tcp-server-c server)
                              (cffi:callback tcp-ssl-accept-cb)
                              data-pointer)
    ;; create a server context
    (let* ((ssl-ctx (cl+ssl::ssl-ctx-new (funcall ssl-method)))
           (ssl-server (change-class server 'tcp-ssl-server :ssl-ctx ssl-ctx)))
      ;; make sure if there is a cert password, it's used
      (cl+ssl::with-pem-password (password)
        (cl+ssl::ssl-ctx-set-default-passwd-cb ssl-ctx (cffi:callback cl+ssl::pem-password-callback))

        ;; load the cert
        (when certificate
          (let ((res (cffi:foreign-funcall "SSL_CTX_use_certificate_chain_file"
                                           :pointer ssl-ctx
                                           :string (namestring certificate)
                                           :int)))
            (unless (= res 1)
              (error (format nil "Error initializing certificate: ~a."
                             (last-ssl-error))))))

        ;; load the private key
        (when key
          (let ((res (cffi:foreign-funcall "SSL_CTX_use_PrivateKey_file"
                                           :pointer ssl-ctx
                                           :string (namestring key)
                                           :int cl+ssl::+ssl-filetype-pem+
                                           :int)))
            (unless (= res 1)
              (error (format nil "Error initializing private key file: ~a."
                             (last-ssl-error)))))))

      ;; setup dhparams
      (when dhparams
	(cl+ssl::init-dhparams dhparams))

      ;; setup DH
      (cl+ssl::ssl-ctx-set-tmp-dh-callback ssl-ctx (cffi:callback cl+ssl::lisp-tmp-dh-callback))
      (cl+ssl::ssl-ctx-set-tmp-ecdh ssl-ctx (cl+ssl::ec-key-new-by-curve-name cl+ssl::+NID_X9_62_prime256v1+))

      ;; setup next protocol negotiation
      (when npn
	(let ((npn-cleanup (init-ssl-npn :server ssl-ctx npn)))
	  (add-event-loop-exit-callback npn-cleanup)))

      ;; adjust the data-pointer's data a bit
      (attach-data-to-pointer data-pointer
                              (list :server server
                                    :ctx ssl-ctx))
      ssl-server)))
