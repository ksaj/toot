;;; Copyright (c) 2004-2010, Dr. Edmund Weitz.  All rights reserved.

;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions
;;; are met:
;;;
;;;   * Redistributions of source code must retain the above copyright
;;;     notice, this list of conditions and the following disclaimer.
;;;
;;;   * Redistributions in binary form must reproduce the above
;;;     copyright notice, this list of conditions and the following
;;;     disclaimer in the documentation and/or other materials
;;;     provided with the distribution.
;;;
;;; THIS SOFTWARE IS PROVIDED BY THE AUTHOR 'AS IS' AND ANY EXPRESSED
;;; OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
;;; WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
;;; ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
;;; DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
;;; DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
;;; GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
;;; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
;;; WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;; NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;; SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

(in-package :toot)

(defvar *default-logger* (make-instance 'stream-logger :destination *error-output*))

(defclass acceptor ()
  ((port :initarg :port :reader acceptor-port)
   (address :initarg :address :reader acceptor-address)
   (name :initarg :name :accessor acceptor-name)
   (taskmaster :initarg :taskmaster :reader taskmaster)
   (output-chunking-p :initarg :output-chunking-p :accessor acceptor-output-chunking-p)
   (input-chunking-p :initarg :input-chunking-p :accessor acceptor-input-chunking-p)
   (persistent-connections-p :initarg :persistent-connections-p :accessor acceptor-persistent-connections-p)
   (read-timeout :initarg :read-timeout :reader acceptor-read-timeout)
   (write-timeout :initarg :write-timeout :reader acceptor-write-timeout)
   (listen-socket :initform nil :accessor acceptor-listen-socket)
   (listen-backlog :initarg :listen-backlog :reader acceptor-listen-backlog)
   (acceptor-shutdown-p :initform t :accessor acceptor-shutdown-p)
   (requests-in-progress :initform 0 :accessor accessor-requests-in-progress)
   (shutdown-queue :initform (make-condition-variable) :accessor acceptor-shutdown-queue)
   (shutdown-lock :initform (make-lock "toot-acceptor-shutdown") :accessor acceptor-shutdown-lock)
   (access-loggger :initarg :access-logger :accessor access-logger)
   (message-logger :initarg :message-logger :accessor message-logger)
   (ssl-adapter :initarg :ssl-adapter :accessor ssl-adapter)
   (dispatcher :initarg :dispatcher :accessor dispatcher)
   (error-generator :initarg :error-generator :accessor error-generator))

  (:default-initargs
    :address nil
    :port 80
    :name (gensym)
    :listen-backlog 50
    :taskmaster (make-instance *default-taskmaster-class*)
    :access-logger *default-logger*
    :message-logger *default-logger*
    :output-chunking-p t
    :input-chunking-p t
    :persistent-connections-p t
    :read-timeout *default-connection-timeout*
    :write-timeout *default-connection-timeout*
    :ssl-adapter nil
    :error-generator #'default-error-message-generator))

(defmethod print-object ((acceptor acceptor) stream)
  (print-unreadable-object (acceptor stream :type t)
    (format stream "\(host ~A, port ~A)"
            (or (acceptor-address acceptor) "*") (acceptor-port acceptor))))

;; SSL

(defclass ssl-adapter ()
  ((ssl-certificate-file :initarg :ssl-certificate-file :reader ssl-certificate-file)
   (ssl-private-key-file :initarg :ssl-private-key-file :reader ssl-private-key-file)
   (ssl-private-key-password :initform nil :initarg :ssl-private-key-password :reader ssl-private-key-password)))

(defmethod initialize-instance :after ((adapter ssl-adapter) &key &allow-other-keys)
  ;; OpenSSL doesn't know much about Lisp pathnames...
  (with-slots (ssl-private-key-file ssl-certificate-file) adapter
    (setf ssl-private-key-file (namestring (truename ssl-private-key-file)))
    (setf ssl-certificate-file (namestring (truename ssl-certificate-file)))))

(defun setup-ssl-stream (adapter stream)
  ;; attach SSL to the stream if necessary
  (with-slots (ssl-certificate-file ssl-private-key-file ssl-private-key-password) adapter
    (cl+ssl:make-ssl-server-stream 
     stream
     :certificate ssl-certificate-file
     :key ssl-private-key-file
    :password ssl-private-key-password)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Start and stop an acceptor

(defun start-server (&key port)
  (start (make-instance 'acceptor
           :port port
           :dispatcher (make-static-file-dispatcher (test-document-directory)))))


(defun start (acceptor)
  (with-accessors 
        ((listen-socket acceptor-listen-socket)
         (shutdown-p acceptor-shutdown-p)
         (address acceptor-address)
         (port acceptor-port)
         (listen-backlog acceptor-listen-backlog))
      acceptor

    (when listen-socket
      (toot-error "acceptor ~A is already listening" acceptor))

    (setf shutdown-p nil)
    (setf listen-socket
          (usocket:socket-listen
           (or address usocket:*wildcard-host*) port
           :reuseaddress t
           :backlog listen-backlog
           :element-type '(unsigned-byte 8)))
      
    (execute-acceptor (taskmaster acceptor) acceptor)
    acceptor))

(defun stop (acceptor &key soft)
  (setf (acceptor-shutdown-p acceptor) t)
  (shutdown (taskmaster acceptor) acceptor)
  (when soft
    (with-lock-held ((acceptor-shutdown-lock acceptor))
      ;; FIXME: seems like this should perhaps be a while loop not a
      ;; when? The thread which called STOP is waiting here while all
      ;; the threads processing requests will signal on the
      ;; acceptor-shutdown-queue
      (when (plusp (accessor-requests-in-progress acceptor))
        (condition-variable-wait (acceptor-shutdown-queue acceptor) 
                                 (acceptor-shutdown-lock acceptor)))))
  (usocket:socket-close (acceptor-listen-socket acceptor))
  (setf (acceptor-listen-socket acceptor) nil)
  acceptor)

(defun do-with-acceptor-request-count-incremented (acceptor function)
  (with-lock-held ((acceptor-shutdown-lock acceptor))
    (incf (accessor-requests-in-progress acceptor)))
  (unwind-protect
       (funcall function)
    (with-lock-held ((acceptor-shutdown-lock acceptor))
      (decf (accessor-requests-in-progress acceptor))
      (when (acceptor-shutdown-p acceptor)
        (condition-variable-signal (acceptor-shutdown-queue acceptor))))))

(defmacro with-acceptor-request-count-incremented ((acceptor) &body body)
  "Execute BODY with ACCEPTOR-REQUESTS-IN-PROGRESS of ACCEPTOR
  incremented by one.  If the ACCEPTOR-SHUTDOWN-P returns true after
  the BODY has been executed, the ACCEPTOR-SHUTDOWN-QUEUE condition
  variable of the ACCEPTOR is signalled in order to finish shutdown
  processing."
  `(do-with-acceptor-request-count-incremented ,acceptor (lambda () ,@body)))

(defun process-connection (acceptor socket)
  "Called by taskmaster's handle-incoming-connection."
  (handler-bind ((error
                  ;; abort if there's an error which isn't caught inside
                  (lambda (cond)
                    (log-message 
                     acceptor
                     *lisp-errors-log-level* 
                     "Error while processing connection: ~A" cond)
                    (return-from process-connection)))
                 (warning
                  ;; log all warnings which aren't caught inside
                  (lambda (cond)
                    (log-message 
                     acceptor
                     *lisp-warnings-log-level*
                     "Warning while processing connection: ~A" cond))))
    (usocket:with-mapped-conditions ()
      (let ((content-stream (make-socket-stream socket acceptor)))
        (unwind-protect
             ;; process requests until either the acceptor is shut
             ;; down, close-stream-p on the reply is T, or the peer
             ;; fails to send a request
             (loop 
                (when (acceptor-shutdown-p acceptor) (return))
                
                (multiple-value-bind (headers-in method url-string protocol)
                    (get-request-data content-stream)
                  ;; check if there was a request at all
                  (unless method (return))
                  (let ((reply (make-instance 'reply :acceptor acceptor))
                        (transfer-encodings (cdr (assoc* :transfer-encoding headers-in))))

                    (when transfer-encodings
                      (setf transfer-encodings (split "\\s*,\\s*" transfer-encodings))

                      (when (member "chunked" transfer-encodings :test #'equalp)
                        (cond 
                          ((acceptor-input-chunking-p acceptor)
                           ;; turn chunking on before we read the request body
                           (setf content-stream (make-chunked-stream content-stream))
                           (setf (chunked-stream-input-chunking-p content-stream) t))
                          (t (toot-error "Client tried to use ~
chunked encoding, but acceptor is configured to not use it.")))))

                    (multiple-value-bind (remote-addr remote-port)
                        (get-peer-address-and-port socket)
                      (with-acceptor-request-count-incremented (acceptor)
                        (process-request (make-instance 'request
                                           :acceptor acceptor
                                           :reply reply
                                           :remote-addr remote-addr
                                           :remote-port remote-port
                                           :headers-in headers-in
                                           :content-stream content-stream
                                           :method method
                                           :uri url-string
                                           :server-protocol protocol))))
                    (force-output content-stream)
                    (setf content-stream (unchunked-stream content-stream))
                    (when (close-stream-p reply) (return)))))

          (when content-stream
            ;; as we are at the end of the request here, we ignore all
            ;; errors that may occur while flushing and/or closing the
            ;; stream.
            (ignore-errors* (force-output content-stream))
            (ignore-errors* (close content-stream :abort t))))))))

(defun unchunked-stream (stream)
  (cond 
    ((typep stream 'chunked-stream)
     ;; Setting these flushes the output stream and checks if there's
     ;; unread input which would be an error.
     (setf (chunked-stream-output-chunking-p stream) nil)
     (setf (chunked-stream-input-chunking-p stream) nil)
     (chunked-stream-stream stream))
    (t stream)))

(defun accept-connections (acceptor)
  "Called by taskmaster's execute-acceptor."
  (usocket:with-server-socket (listener (acceptor-listen-socket acceptor))
    (loop
       (when (acceptor-shutdown-p acceptor) (return))

       (when (usocket:wait-for-input listener :ready-only t :timeout +new-connection-wait-time+)
         (when-let (client-connection
                    (handler-case (usocket:socket-accept listener)                               
                      ;; ignore condition
                      (usocket:connection-aborted-error ())))
           (set-timeouts client-connection
                         (acceptor-read-timeout acceptor)
                         (acceptor-write-timeout acceptor))
           (handle-incoming-connection (taskmaster acceptor) acceptor client-connection))))))

(defun handle-request (request)
  ;; If the handler we dispatch to throws handler-done, we will return
  ;; the values thrown. Otherwise we return whatever values the
  ;; handler returns. If the handler returns a value (and it has not
  ;; called send-headers) the value should be a string which will be
  ;; encoded and sent as the body of the reply.
  (catch 'handler-done
    (handler-bind 
        ((error
          (lambda (cond)
            ;; if the headers were already sent, the error happened
            ;; within the body and we have to close the stream
            (let ((reply (reply request)))
              (when (headers-sent-p reply) (setf (close-stream-p reply) t)))
            (throw 'handler-done (values nil cond (get-backtrace)))))
         (warning
          (lambda (cond)
            (when *log-lisp-warnings-p*
              (log-message request *lisp-warnings-log-level* "~A" cond)))))
      (with-debugger
        (dispatch (dispatcher (acceptor request)) request)))))

(defun abort-request-handler (request response-status-code &optional body)
  "Abort the handling of a request, sending instead a response with
the given response-status-code. A request can only be aborted if
SEND-HEADERS has not been called."
  (setf (return-code (reply request)) response-status-code)
  (throw 'handler-done body))

(defun error-page (request &key error backtrace)
  "Generate the body of an error page, using the acceptors error generator."
  (generate-error-page (error-generator (acceptor request)) request :error error :backtrace backtrace))

(defun acceptor-server-name (acceptor)
  (format nil "Toot ~A (~A)" *toot-version* (acceptor-name acceptor)))

