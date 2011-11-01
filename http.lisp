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

;; Helper macro

(defmacro with-request-count-incremented ((acceptor) &body body)
  "Execute BODY with REQUESTS-IN-PROGRESS of ACCEPTOR
  incremented by one. If the SHUTDOWN-P returns true after the BODY
  has been executed, the SHUTDOWN-QUEUE condition variable of the
  ACCEPTOR is signalled in order to finish shutdown processing."
  `(do-with-request-count-incremented ,acceptor (lambda () ,@body)))

(defun do-with-request-count-incremented (acceptor function)
  (with-lock-held ((shutdown-lock acceptor))
    (incf (accessor-requests-in-progress acceptor)))
  (unwind-protect
       (funcall function)
    (with-lock-held ((shutdown-lock acceptor))
      (decf (accessor-requests-in-progress acceptor))
      (when (shutdown-p acceptor)
        (condition-notify (shutdown-queue acceptor))))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Generic functions to be implemented by users to customize the
;;; server.

(defgeneric handle-request (handler request)
  (:documentation "Used by the acceptor to handle a request."))

(defgeneric generate-error-page (generator request &key error backtrace)
  (:documentation "Used by acceptor to generate an error page for a
  request based on the http status code."))

(defvar *default-logger* (make-instance 'stream-logger :destination *error-output*))

(defclass acceptor ()
  ((port :initarg :port :reader port)
   (address :initarg :address :reader address)
   (taskmaster :initarg :taskmaster :reader taskmaster)
   (output-chunking-p :initarg :output-chunking-p :accessor output-chunking-p)
   (input-chunking-p :initarg :input-chunking-p :accessor input-chunking-p)
   (persistent-connections-p :initarg :persistent-connections-p :accessor persistent-connections-p)
   (read-timeout :initarg :read-timeout :reader read-timeout)
   (write-timeout :initarg :write-timeout :reader write-timeout)
   (listen-socket :initform nil :accessor listen-socket)
   (listen-backlog :initarg :listen-backlog :reader listen-backlog)
   (shutdown-p :initform t :accessor shutdown-p)
   (requests-in-progress :initform 0 :accessor accessor-requests-in-progress)
   (shutdown-queue :initform (make-condition-variable) :accessor shutdown-queue)
   (shutdown-lock :initform (make-lock "toot-shutdown") :accessor shutdown-lock)
   (access-loggger :initarg :access-logger :initform *default-logger* :accessor access-logger)
   (message-logger :initarg :message-logger :initform *default-logger* :accessor message-logger)
   (ssl-adapter :initarg :ssl-adapter :accessor ssl-adapter)
   (handler :initarg :handler :accessor handler)
   (error-generator :initarg :error-generator :accessor error-generator))

  (:default-initargs
    :address nil
    :port 80
    :listen-backlog 50
    :taskmaster (make-instance *default-taskmaster-class*)
    :output-chunking-p t
    :input-chunking-p t
    :persistent-connections-p t
    :read-timeout *default-connection-timeout*
    :write-timeout *default-connection-timeout*
    :ssl-adapter nil
    :error-generator #'default-error-message-generator))

(defmethod print-object ((acceptor acceptor) stream)
  (print-unreadable-object (acceptor stream :type t)
    (format stream "\(host ~A, port ~A)" (or (address acceptor) "*") (port acceptor))))

(defclass request ()
  (
   ;; Information about the request itself
   (remote-addr :initarg :remote-addr :reader remote-addr) ; cgi REMOTE_ADDR
   (remote-port :initarg :remote-port :reader remote-port) ; cgi - weirdly missing
   (script-name :initform nil :reader script-name) ; cgi SCRIPT_NAME
   (method :initarg :method :reader request-method) ; cgi REQUEST_METHOD
   (query-string :initform nil :reader query-string) ; cgi QUERY_STRING
   (server-protocol :initarg :server-protocol :reader server-protocol) ; cgi SERVER_PROTOCOL
   (uri :initarg :uri :reader request-uri)
   (get-parameters :initform nil :reader get-parameters) 
   (post-parameters :initform nil :reader post-parameters)
   (raw-post-data :initform nil)
   (headers-in :initarg :headers-in :reader headers-in)
   (cookies-in :initform nil :reader cookies-in)

   ;; Information used in generating the reply
   (return-code :initform +http-ok+ :accessor return-code)
   (content-length :reader content-length :initform nil)
   (content-type :reader content-type)
   (external-format :initform *default-external-format* :accessor external-format)
   (headers-out :initform nil :reader headers-out)
   (cookies-out :initform nil :accessor cookies-out)

   ;; Lifecycle control
   (headers-sent-p :initform nil :accessor headers-sent-p)
   (close-stream-p :initform t :accessor close-stream-p)

   ;; Internal foo
   (acceptor :initarg :acceptor :reader acceptor)
   (content-stream :initarg :content-stream :accessor content-stream)
   (tmp-files :initform () :accessor tmp-files)
   (aux-data :initform nil :accessor aux-data)
   ))

(defmethod initialize-instance :after ((request request) &rest init-args)
  (declare (ignore init-args))

  (setf (header-out :content-type request) *default-content-type*)

  (with-slots (headers-in cookies-in get-parameters script-name query-string) request
    (handler-case*
        (progn
          (let* ((uri (request-uri request))
                 (match-start (position #\? uri)))
            (cond
              (match-start
               (setf script-name (subseq uri 0 match-start))
               (setf query-string (subseq uri (1+ match-start))))
              (t (setf script-name uri))))

          ;; some clients (e.g. ASDF-INSTALL) send requests like
          ;; "GET http://server/foo.html HTTP/1.0"...
          (setf script-name (regex-replace "^https?://[^/]+" script-name ""))
          ;; compute GET parameters from query string and cookies from
          ;; the incoming 'Cookie' header
          (setf get-parameters
                (let ((*substitution-char* #\?))
                  (form-url-encoded-list-to-alist (split "&" query-string))))

          ;; FIXME: Are cookies really always encoded in UTF-8?
          (setf cookies-in
                (form-url-encoded-list-to-alist (split "\\s*[,;]\\s*" (cdr (assoc :cookie headers-in)))
                                                +utf-8+)))
      (error (condition)
        (log-message request :error "Error when creating REQUEST object: ~A" condition)
        ;; we assume it's not our fault...
        (setf (return-code request) +http-bad-request+)))))

(defclass ssl-adapter ()
  ((ssl-certificate-file :initarg :ssl-certificate-file :reader ssl-certificate-file)
   (ssl-private-key-file :initarg :ssl-private-key-file :reader ssl-private-key-file)
   (ssl-private-key-password :initform nil :initarg :ssl-private-key-password :reader ssl-private-key-password)))

(defmethod initialize-instance :after ((adapter ssl-adapter) &key &allow-other-keys)
  ;; OpenSSL doesn't know much about Lisp pathnames...
  (with-slots (ssl-private-key-file ssl-certificate-file) adapter
    (setf ssl-private-key-file (namestring (truename ssl-private-key-file)))
    (setf ssl-certificate-file (namestring (truename ssl-certificate-file)))))

;;; Convenience methods to pass along log-message calls until we hit the actual logger.

(defmethod log-message ((acceptor acceptor) log-level format-string &rest format-arguments)
  (apply #'log-message (message-logger acceptor) log-level format-string format-arguments))

(defmethod log-message ((request request) log-level format-string &rest format-arguments)
  (apply #'log-message (acceptor request) log-level format-string format-arguments))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; API functions

(defun (setf content-type) (new-value request)
  "Sets the outgoing 'Content-Type' http header of REQUEST."
  (setf (header-out :content-type request) new-value))

(defun (setf content-length) (new-value request)
  "Sets the outgoing 'Content-Length' http header of REQUEST."
  (setf (header-out :content-length request) new-value))

(defun header-out-set-p (name request)
  "Returns a true value if the outgoing http header named NAME has
been specified already.  NAME should be a keyword or a string."
  (assoc* name (headers-out request)))

(defun cookie-out (name request)
  "Returns the current value of the outgoing cookie named
NAME. Search is case-sensitive."
  (cdr (assoc name (cookies-out request) :test #'string=)))

(defun header-out (name request)
  "Returns the current value of the outgoing http header named NAME.
NAME should be a keyword or a string."
  (cdr (assoc name (headers-out request))))

(defun (setf header-out) (new-value name request)
  "Changes the current value of the outgoing http
header named NAME \(a keyword or a string).  If a header with this
name doesn't exist, it is created."
  (when (headers-sent-p request)
    (error "Can't set reply headers after headers have been sent."))

  (when (stringp name)
    (setf name (as-keyword name :destructivep nil)))

  (let ((entry (assoc name (headers-out request))))
    (if entry
        (setf (cdr entry) new-value)
        (setf (slot-value request 'headers-out)
              (acons name new-value (headers-out request))))
    new-value)

  (case name
    (:content-length
     (check-type new-value integer)
     (setf (slot-value request 'content-length) new-value))
    (:content-type
     (check-type new-value (or null string))
     (setf (slot-value request 'content-type) new-value))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Start and stop the server

(defun start-server (&key port (handler (make-static-file-handler (test-document-directory))))
  (start (make-instance 'acceptor :port port :handler handler)))

(defun start (acceptor)
  (when (listen-socket acceptor)
    (toot-error "acceptor ~A is already listening" acceptor))

  (setf (shutdown-p acceptor) nil)
  (setf (listen-socket acceptor)
        (usocket:socket-listen
         (or (address acceptor) usocket:*wildcard-host*) (port acceptor)
         :reuseaddress t
         :backlog (listen-backlog acceptor)
         :element-type '(unsigned-byte 8)))
  (execute-acceptor (taskmaster acceptor) acceptor)
  acceptor)

(defun stop (acceptor &key soft)
  (setf (shutdown-p acceptor) t)
  (shutdown (taskmaster acceptor) acceptor)
  (when soft
    (with-lock-held ((shutdown-lock acceptor))
      ;; FIXME: seems like this should perhaps be a while loop not a
      ;; WHEN? The thread which called STOP is waiting here while all
      ;; the threads processing requests will signal on the
      ;; shutdown-queue
      (when (plusp (accessor-requests-in-progress acceptor))
        (condition-wait (shutdown-queue acceptor) (shutdown-lock acceptor)))))
  (usocket:socket-close (listen-socket acceptor))
  (setf (listen-socket acceptor) nil)
  acceptor)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Server -- these functions interact with a taskmaster to implement
;;; the basic read a request and reply functionality.

(defun accept-connections (acceptor)
  "Accept connections on our listen socket and hand them back to the
taskmaster via handle-incoming-connection. Called by taskmaster's
execute-acceptor."
  (usocket:with-server-socket (listener (listen-socket acceptor))
    (loop
       (when (shutdown-p acceptor) (return))

       (when (usocket:wait-for-input listener :ready-only t :timeout +new-connection-wait-time+)
         (when-let (client-connection
                    (handler-case (usocket:socket-accept listener)                               
                      ;; ignore condition
                      (usocket:connection-aborted-error ())))
           (set-timeouts client-connection
                         (read-timeout acceptor)
                         (write-timeout acceptor))
           (handle-incoming-connection (taskmaster acceptor) acceptor client-connection))))))

(defun process-connection (acceptor socket)
  "Actually process the connection accepted via accept connection.
Called by taskmaster's handle-incoming-connection, possibly in a
different thread than accept-connection is running in."
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
             ;; down, close-stream-p on the most recent request is T,
             ;; or the peer fails to send a request
             (loop 
                (when (shutdown-p acceptor) (return))
                
                (multiple-value-bind (headers-in method url-string protocol)
                    (read-request content-stream)
                  ;; check if there was a request at all
                  (unless method (return))
                  (let ((request nil)
                        (transfer-encodings (cdr (assoc* :transfer-encoding headers-in))))

                    (when transfer-encodings
                      (setf transfer-encodings (split "\\s*,\\s*" transfer-encodings))

                      (when (member "chunked" transfer-encodings :test #'equalp)
                        (cond 
                          ((input-chunking-p acceptor)
                           ;; turn chunking on before we read the request body
                           (setf content-stream (make-chunked-stream content-stream))
                           (setf (chunked-stream-input-chunking-p content-stream) t))
                          (t (toot-error "Client tried to use ~
chunked encoding, but acceptor is configured to not use it.")))))

                    (multiple-value-bind (remote-addr remote-port)
                        (get-peer-address-and-port socket)
                      (with-request-count-incremented (acceptor)
                        (setf request (make-instance 'request
                                           :acceptor acceptor
                                           :remote-addr remote-addr
                                           :remote-port remote-port
                                           :headers-in headers-in
                                           :content-stream content-stream
                                           :method method
                                           :uri url-string
                                           :server-protocol protocol))
                        (process-request request)))
                    (force-output content-stream)
                    (setf content-stream (unchunked-stream content-stream))
                    (when (close-stream-p request) (return)))))

          (when content-stream
            ;; As we are at the end of the requests here, we ignore
            ;; all errors that may occur while flushing and/or closing
            ;; the stream.
            (ignore-errors* (force-output content-stream))
            (ignore-errors* (close content-stream :abort t))))))))

(defun process-request (request)
  "Process a single request. Called repeatedly by process-connection."
  ;; used by HTTP HEAD handling to end request processing in a HEAD
  ;; request (see START-OUTPUT)
  (catch 'request-processed
    (unwind-protect
         (multiple-value-bind (body error backtrace) 
             ;; The handler can throw handler-done (by calling
             ;; abort-request-handler) to provide a body, error, and
             ;; backtrace after setting the HTTP status code.
             ;; Otherwise the handler can either call SEND-HEADERS and
             ;; write the body to the stream or return a string which
             ;; will be encoded and sent as the body of the reply.
             (catch 'handler-done
               (handler-bind 
                   ((error
                     (lambda (cond)
                       ;; if the headers were already sent, the error happened
                       ;; within the body and we have to close the stream
                       (when (headers-sent-p request) (setf (close-stream-p request) t))
                       (throw 'handler-done (values nil cond (get-backtrace)))))
                    (warning
                     (lambda (cond)
                       (when *log-lisp-warnings-p*
                         (log-message request *lisp-warnings-log-level* "~A" cond)))))
                 (with-debugger
                   (let ((result (handle-request (handler (acceptor request)) request)))
                     (cond
                       ((eql result 'not-handled)
                        (abort-request-handler request +http-not-found+))
                       (t result))))))

           (when error (report-error-to-client request error backtrace))

           ;; Headers will have been sent if the handler called
           ;; SEND-HEADERS and wrote the response directly to the
           ;; stream. In that case there is nothing left to do but
           ;; clean up. Otherwise, send the returned body or, if there
           ;; is none, an error message we generated based on the
           ;; return code.
           (unless (headers-sent-p request)
             (handler-case
                 (with-debugger 
                   (start-output request (or body (error-body request))))
               (error (e)
                 ;; error occured while writing to the client. attempt to report.
                 (report-error-to-client request e)))))

      (delete-tmp-files request))))

(defun make-socket-stream (socket acceptor)
  (let ((base-stream (usocket:socket-stream socket))
        (ssl-adapter (ssl-adapter acceptor)))
    (cond
      (ssl-adapter (setup-ssl-stream ssl-adapter base-stream))
      (t base-stream))))

(defun setup-ssl-stream (adapter stream)
  ;; attach SSL to the stream if necessary
  (with-slots (ssl-certificate-file ssl-private-key-file ssl-private-key-password) adapter
    (cl+ssl:make-ssl-server-stream 
     stream
     :certificate ssl-certificate-file
     :key ssl-private-key-file
    :password ssl-private-key-password)))

;;; FIXME: possibly the call site of handler-incoming-connection
;;; should be set up to allow the taskmaster to simply signal a
;;; condition or throw something
(defun send-service-unavailable-reply (acceptor socket)
  "Send a response to the client before we've created a request
object. This can be used by taskmasters when they cannot accept a
connection."
  (log-message acceptor :warning "Can't handle a new request, too many request threads already")
  (with-open-stream (stream (make-header-stream (make-socket-stream socket acceptor)))
    (write-status-line stream +http-service-unavailable+)
    (write-headers stream '((:content . 0)))
    (format stream "~C~C" #\Return #\Linefeed)))

(defun unchunked-stream (stream)
  (cond 
    ((typep stream 'chunked-stream)
     ;; Setting these flushes the output stream and checks if there's
     ;; unread input which would be an error.
     (setf (chunked-stream-output-chunking-p stream) nil)
     (setf (chunked-stream-input-chunking-p stream) nil)
     (chunked-stream-stream stream))
    (t stream)))

(defun report-error-to-client (request error &optional backtrace)
  (when *log-lisp-errors-p*
    (log-message
     request
     *lisp-errors-log-level*
     "~A~@[~%~A~]"
     error
     (and *log-lisp-backtraces-p* backtrace)))
  (setf (return-code request) +http-internal-server-error+)
  (start-output request (error-body request :error error :backtrace backtrace)))

(defun error-body (request &key error backtrace)
  (let ((generator (error-generator (acceptor request))))
    (generate-error-page generator request :error error :backtrace backtrace)))

(defun delete-tmp-files (request)
  (dolist (path (tmp-files request))
    (when (and (pathnamep path) (probe-file path))
      ;; the handler may have chosen to (re)move the uploaded
      ;; file, so ignore errors that happen during deletion
      (ignore-errors* (delete-file path)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Request -- reading the HTTP request from the client

(defun read-request (stream)
  "Reads incoming headers from the client via STREAM.  Returns as
multiple values the headers as an alist, the method, the URI, and the
protocol of the request."
  (with-character-stream-semantics
   (let ((first-line (read-initial-request-line stream)))
     (when first-line
       (unless (every #'printable-ascii-char-p first-line)
         (send-bad-request-response stream "Non-ASCII character in request line")
         (return-from read-request nil))
       (destructuring-bind (&optional method url-string protocol)
           (split "\\s+" first-line :limit 3)
         (unless url-string
           (send-bad-request-response stream)
           (return-from read-request nil))
         (when *header-stream*
           (format *header-stream* "~A~%" first-line))
         (let ((headers (and protocol (read-http-headers stream *header-stream*))))
           (unless protocol (setf protocol "HTTP/0.9"))
           ;; maybe handle 'Expect: 100-continue' header
           (when-let (expectations (cdr (assoc* :expect headers)))
             (when (member "100-continue" (split "\\s*,\\s*" expectations) :test #'equalp)
               ;; according to 14.20 in the RFC - we should actually
               ;; check if we have to respond with 417 here
               (let ((continue-line
                      (format nil "HTTP/1.1 ~D ~A"
                              +http-continue+
                              (reason-phrase +http-continue+))))
                 (write-sequence (map 'list #'char-code continue-line) stream)
                 (write-sequence +crlf+ stream)
                 (write-sequence +crlf+ stream)
                 (force-output stream)
                 (when *header-stream*
                   (format *header-stream* "~A~%" continue-line)))))
           (values headers
                   (as-keyword method)
                   url-string
                   (as-keyword (trim-whitespace protocol)))))))))

(defun read-initial-request-line (stream)
  (handler-case
      (let ((*current-error-message* "While reading initial request line:"))
        (usocket:with-mapped-conditions ()
          (read-line* stream)))
    ((or end-of-file usocket:timeout-error) ())))

(defun printable-ascii-char-p (char)
  (<= 32 (char-code char) 126))

(defun get-peer-address-and-port (socket)
  "Returns the peer address and port of the socket SOCKET as two
values.  The address is returned as a string in dotted IP address
notation."
  (values (usocket:vector-quad-to-dotted-quad (usocket:get-peer-address socket))
          (usocket:get-peer-port socket)))

(defun convert-hack (string external-format)
  "The rfc2388 code is buggy in that it operates on a character stream
and thus only accepts encodings which are 8 bit transparent. In order
to support different encodings for parameter values submitted, we post
process whatever string values the rfc2388 package has returned."
  (flex:octets-to-string (map '(vector (unsigned-byte 8) *) 'char-code string)
                         :external-format external-format))



(defun parse-multipart-form-data (request external-format)
  "Parse the REQUEST body as multipart/form-data, assuming that its
content type has already been verified.  Returns the form data as
alist or NIL if there was no data or the data could not be parsed."
  (handler-case*
      (let ((content-stream (make-flexi-stream (content-stream request) :external-format +latin-1+)))
        (prog1
            (parse-rfc2388-form-data
             content-stream
             (header-in :content-type request)
             external-format
             (make-tmp-filename-generator request))
          (let ((stray-data (read-request-body request :already-read (flexi-stream-position content-stream))))
            (when (and stray-data (plusp (length stray-data)))
              (toot-warn "~A octets of stray data after form-data sent by client."
                         (length stray-data))))))
    (error (condition)
      (log-message request :error "While parsing multipart/form-data parameters: ~A" condition)
      nil)))

(defun parse-rfc2388-form-data (stream content-type-header external-format tmp-filename-generator)
  "Creates an alist of POST parameters from the stream STREAM which is
supposed to be of content type 'multipart/form-data'."
  (let* ((parsed-content-type-header (parse-header content-type-header :value))
	 (boundary (or (cdr (find-parameter
                             "BOUNDARY"
                             (header-parameters parsed-content-type-header)))
		       (return-from parse-rfc2388-form-data))))
    (loop for part in (parse-mime stream boundary tmp-filename-generator)
          for headers = (mime-part-headers part)
          for content-disposition-header = (find-content-disposition-header headers)
          for name = (cdr (find-parameter
                           "NAME"
                           (header-parameters content-disposition-header)))
          when name
          collect (cons name
                        (let ((contents (mime-part-contents part)))
                          (if (pathnamep contents)
                            (list contents
                                  (get-file-name headers)
                                  (mime-content-type part :as-string t))
                            (convert-hack contents external-format)))))))




;;; FIXME: Is this actually useful? Either its part of the API or it
;;; should be axed.
(defun recompute-request-parameters (request &key (external-format *default-external-format*))
  "Recomputes the GET and POST parameters for the REQUEST object
REQUEST.  This only makes sense if you're switching external formats
during the request."
  (maybe-read-post-parameters request :force t :external-format external-format)
  (setf (slot-value request 'get-parameters)
        (form-url-encoded-list-to-alist (split "&" (query-string request)) external-format))
  (values))
                                                
(defmethod post-parameters :before ((request request))
  ;; Force here because if someone calls POST-PARAMETERS they actually
  ;; want them, regardless of why the RAW-POST-DATA has been filled
  ;; in. (For instance, if SEND-HEADERS has been called, filling in
  ;; RAW-POST-DATA, and then subsequent code calls POST-PARAMETERS,
  ;; without the :FORCE flag POST-PARAMETERS would return NIL.)
  (maybe-read-post-parameters request :force (not (slot-value request 'post-parameters))))

(defun maybe-read-post-parameters (request &key force external-format)
  "Make sure that any POST parameters in the REQUEST are parsed. The
body of the request must be either application/x-www-form-urlencoded
or multipart/form-data to be considered as containing POST parameters.
If FORCE is true, parsing is done unconditionally. Otherwise, parsing
will only be done if the RAW-POST-DATA slot in the REQUEST is false.
EXTERNAL-FORMAT specifies the external format of the data in the
request body. By default, the encoding is determined from the
Content-Type header of the request or from *DEFAULT-EXTERNAL-FORMAT*
if none is found."
  (when (and (header-in :content-type request)
             (member (request-method request) *methods-for-post-parameters* :test #'eq)
             (or force
                 (not (slot-value request 'raw-post-data)))
	     ;; can't reparse multipart posts, even when FORCEd
	     (not (eql t (slot-value request 'raw-post-data))))
    (unless (or (header-in :content-length request)
                (chunking-input-p request))
      (log-message request :warning "Can't read request body because there's ~
no Content-Length header and input chunking is off.")
      (return-from maybe-read-post-parameters nil))
    (handler-case*
        (multiple-value-bind (type subtype charset)
              (parse-content-type-header (header-in :content-type request))
          (let ((external-format (or external-format
                                     (when charset
                                       (handler-case
                                           (make-external-format charset :eol-style :lf)
                                         (error ()
                                           (toot-warn "Ignoring ~
unknown character set ~A in request content type."
                                                 charset))))
                                     *default-external-format*)))
            (setf (slot-value request 'post-parameters)
                  (cond ((and (string-equal type "application")
                              (string-equal subtype "x-www-form-urlencoded"))
                         (form-url-encoded-list-to-alist
                          (split "&" (raw-post-data request :external-format +latin-1+))
                          external-format))
                        ((and (string-equal type "multipart")
                              (string-equal subtype "form-data"))
                         (prog1 (parse-multipart-form-data request external-format)
                           (setf (slot-value request 'raw-post-data) t)))))))
      (error (condition)
        (log-message request :error "Error when reading POST parameters from body: ~A" condition)
        ;; this is not the right thing to do because it could happen
        ;; that we aren't finished reading from the request stream and
        ;; can't send a reply - to be revisited
        (setf (close-stream-p request) t)
        (abort-request-handler request +http-bad-request+)))))

(defun raw-post-data (request &key external-format force-text force-binary want-stream)
  "Returns the content sent by the client if there was any \(unless
the content type was \"multipart/form-data\"). By default, the result
is a string if the type of the `Content-Type' media type is \"text\",
and a vector of octets otherwise. In the case of a string, the
external format to be used to decode the content will be determined
from the `charset' parameter sent by the client \(or otherwise
*DEFAULT-EXTERNAL-FORMAT* will be used).

You can also provide an external format explicitly \(through
EXTERNAL-FORMAT) in which case the result will unconditionally be a
string.  Likewise, you can provide a true value for FORCE-TEXT which
will force Toot to act as if the type of the media type had
been \"text\".  Or you can provide a true value for FORCE-BINARY which
means that you want a vector of octets at any rate.

If, however, you provide a true value for WANT-STREAM, the other
parameters are ignored and you'll get the content \(flexi) stream to
read from it yourself.  It is then your responsibility to read the
correct amount of data, because otherwise you won't be able to return
a response to the client.  If the content type of the request was
`multipart/form-data' or `application/x-www-form-urlencoded', the
content has been read by Toot already and you can't read from
the stream anymore.

You can call RAW-POST-DATA more than once per request, but you can't
mix calls which have different values for WANT-STREAM.

Note that this function is slightly misnamed because a client can send
content even if the request method is not POST."
  (when (and force-binary force-text)
    (parameter-error "It doesn't make sense to set both FORCE-BINARY and FORCE-TEXT to a true value."))

  (unless (or external-format force-binary)
    (setf external-format (or (external-format-from-content-type (header-in :content-type request))
                              (and force-text *default-external-format*))))
  (let ((raw-post-data (or (slot-value request 'raw-post-data)
                           (read-request-body request :want-stream want-stream))))
    (cond ((typep raw-post-data 'stream) raw-post-data)
          ((member raw-post-data '(t nil)) nil)
          (external-format (octets-to-string raw-post-data :external-format external-format))
          (t raw-post-data))))

(defun read-request-body (request &key want-stream (already-read 0))
  "Reads the request body from the stream and stores the raw contents
\(as an array of octets) in the corresponding slot of the REQUEST
object.  Returns just the stream if WANT-STREAM is true.  If there's a
Content-Length header, it is assumed, that ALREADY-READ octets have
already been read."
  (let* ((headers-in (headers-in request))
         (content-length (when-let (content-length-header (cdr (assoc :content-length headers-in)))
                           (parse-integer content-length-header :junk-allowed t)))
         (content-stream (content-stream request)))
    (setf (slot-value request 'raw-post-data)
          (cond
            (want-stream
             (let ((stream (make-flexi-stream content-stream :external-format +latin-1+)))
               (when content-length
                 (setf (flexi-stream-bound stream) content-length))
               stream))

            ((and content-length (> content-length already-read))
             (decf content-length already-read)
             (when (chunking-input-p request)
               ;; see RFC 2616, section 4.4
               (log-message request :warning "Got Content-Length header although input chunking is on."))
             (let ((content (make-array content-length :element-type 'octet)))
               (read-sequence content content-stream)
               content))

            ((chunking-input-p request)
             (loop with buffer = (make-array +buffer-length+ :element-type 'octet)
                with content = (make-array 0 :element-type 'octet :adjustable t)
                for index = 0 then (+ index pos)
                for pos = (read-sequence buffer content-stream)
                do (adjust-array content (+ index pos))
                (replace content buffer :start1 index :end2 pos)
                while (= pos +buffer-length+)
                finally (return content)))))))

(defun send-bad-request-response (stream &optional additional-info)
  (write-sequence 
   (flex:string-to-octets
    (format nil "HTTP/1.0 ~D ~A~C~C~
                 Connection: close~C~C~
                 ~C~C~
                 Your request could not be interpreted by this HTTP server~C~C~@[~A~]~C~C"
            +http-bad-request+ (reason-phrase +http-bad-request+) #\Return #\Linefeed
            #\Return #\Linefeed
            #\Return #\Linefeed
            #\Return #\Linefeed
            additional-info #\Return #\Linefeed))
   stream))

(defun external-format-from-content-type (content-type)
  "Creates and returns an external format corresponding to the value
of the content type header provided in CONTENT-TYPE.  If the content
type was not set or if the character set specified was invalid, NIL is
returned."
  (when content-type
    (when-let (charset (nth-value 2 (parse-content-type-header content-type)))
      (handler-case
          (make-external-format (as-keyword charset) :eol-style :lf)
        (error ()
          (toot-warn "Invalid character set ~S in request has been ignored." charset))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Reply -- sending back the HTTP reply.

(defun start-output (request &optional (content nil content-provided-p))
  "Start sending the reply."
  (let* ((return-code (return-code request))
         (acceptor (acceptor request))
         (chunkedp (and (output-chunking-p acceptor)
                        (eql (server-protocol request) :http/1.1)
                        ;; only turn chunking on if the content
                        ;; length is unknown at this point...
                        (null (or (content-length request) content-provided-p))))
         (head-request-p (eql (request-method request) :head)))

    (multiple-value-bind (keep-alive-p keep-alive-requested-p)
        (keep-alive-p request)
      (when keep-alive-p
        (setf keep-alive-p
              ;; use keep-alive if there's a way for the client to
              ;; determine when all content is sent (or if there
              ;; is no content)
              (or chunkedp
                  head-request-p
                  (eql return-code +http-not-modified+)
                  (content-length request)
                  content)))
      ;; now set headers for keep-alive and chunking
      (when chunkedp
        (setf (header-out :transfer-encoding request) "chunked"))

      (cond 
        (keep-alive-p
         (setf (close-stream-p request) nil)
         (when (and (read-timeout acceptor)
                    (or (not (eql (server-protocol request) :http/1.1))
                        keep-alive-requested-p))
           ;; persistent connections are implicitly assumed for
           ;; HTTP/1.1, but we return a 'Keep-Alive' header if the
           ;; client has explicitly asked for one
           (setf (header-out :connection request) "Keep-Alive")
           (setf (header-out :keep-alive request) (format nil "timeout=~D" (read-timeout acceptor)))))

        (t (setf (header-out :connection request) "Close"))))

    (unless (and (header-out-set-p :server request) 
                 (null (header-out :server request)))
      (setf (header-out :server request) (or (header-out :server request)
                                             (format nil "Toot ~A" *toot-version*))))

    (setf (header-out :date request) (rfc-1123-date))

    (when (stringp content)
      ;; if the content is a string, convert it to the proper external format
      (setf content (string-to-octets content :external-format (external-format request)))
      (setf (content-type request) (maybe-add-charset-to-content-type-header 
                                    (content-type request)
                                    (external-format request))))

    ;; FIXME: this should probably be within the preceeding WHEN.
    (when content
      ;; whenever we know what we're going to send out as content, set
      ;; the Content-Length header properly; maybe the user specified
      ;; a different content length, but that will be wrong anyway
      (setf (header-out :content-length request) (length content)))


    ;; If the handler calls send-headers, then we will get here with
    ;; no content and need to send the headers. Then, after the
    ;; handler returns, the acceptor will call start-output again and
    ;; we'll end up here with still no content but with the headers
    ;; sent, in which case we do nothing (and the return value is
    ;; ignored).
    ;;
    ;; If, however, the handler didn't call send-headers, then
    ;; start-output will be called for the first time from
    ;; process-request after the handler returns with (presumably) a
    ;; non-nil content, in which case we need to send the headers and
    ;; then send the content.
    ;;
    ;; Finally, there's the wrinkle that either of those scenarios
    ;; could also occur in response to a HEAD request in which case we
    ;; want to skip sending the content anyway.
    (unless (headers-sent-p request)
      (let ((stream (content-stream request)))

        (when content
          (unless head-request-p
            (setf (content-length request) (length content))))
        
        (%send-headers stream request return-code)

        (when content
          (unless head-request-p
            (write-sequence content stream)
            (finish-output stream)))
      
        ;; when processing a HEAD request, exit to return from
        ;; PROCESS-REQUEST. In the case of a handler that calls
        ;; send-header this will cause the handler to exit suddenly,
        ;; before it outputs any content.
        (when head-request-p (throw 'request-processed nil))
        
        ;;; This case is mostly (only?) interesting in the
        ;;; send-headers case (and perhaps should be moved there)
        ;;; since if we were called with content, it was already
        ;;; written and the request has been processed and after
        ;;; process-request returns the request whose content-stream
        ;;; we are setting here will become garbage.
        (when chunkedp
          ;; turn chunking on after the headers have been sent
          (unless (typep (content-stream request) 'chunked-stream)
            (setf (content-stream request) (make-chunked-stream (content-stream request))))
          (setf (chunked-stream-output-chunking-p (content-stream request)) t))
      
        (content-stream request)))))

(defun %send-headers (stream request status-code)
  (log-access (access-logger (acceptor request)) request)

  ;; Read post data to clear stream - Force binary mode to avoid
  ;; OCTETS-TO-STRING overhead.
  (raw-post-data request :force-binary t)

  (let ((header-stream (make-header-stream stream)))
    (write-status-line header-stream status-code)
    (write-headers header-stream (headers-out request))
    (write-cookies header-stream (cookies-out request))
    (format header-stream "~C~C" #\Return #\Linefeed))

  (setf (headers-sent-p request) t))

(defun make-header-stream (stream)
  "Make a stream just for writing the HTTP headers."
  (let* ((client-header-stream (flex:make-flexi-stream stream :external-format :iso-8859-1)))
    (if *header-stream*
        (make-broadcast-stream *header-stream* client-header-stream)
        client-header-stream)))

(defun maybe-add-charset-to-content-type-header (content-type external-format)
  (if (and (cl-ppcre:scan "(?i)^text" content-type)
           (not (cl-ppcre:scan "(?i);\\s*charset=" content-type)))
      (format nil "~A; charset=~(~A~)" content-type (flex:external-format-name external-format))
      content-type))

(defun write-line-crlf (stream fmt &rest args)
  (apply #'format stream fmt args)
  (write-char #\Return stream)
  (write-char #\Linefeed stream))

(defun write-status-line (stream status-code)
  (write-line-crlf stream "HTTP/1.1 ~D ~A" status-code (reason-phrase status-code)))

(defun write-headers (stream headers)
  (loop for (key . value) in headers
     when value do (write-header-line (as-capitalized-string key) value stream)))

(defun write-cookies (stream cookies)
  (loop for (nil . cookie) in cookies
     do (write-header-line "Set-Cookie" (stringify-cookie cookie) stream)))

(defun write-header-line (key value stream)
  (let ((string (princ-to-string value)))
    (write-string key stream)
    (write-char #\: stream)
    (write-char #\Space stream)
    (let ((start 0))
      (loop
         (let ((end (or (position #\Newline string :start start)
                        (length string))))
           ;; skip empty lines, as they confuse certain HTTP clients
           (unless (eql start end)
             (unless (zerop start)
               (write-char #\Tab stream))
             (write-string string stream :start start :end end)
             (write-char #\Return stream)
             (write-char #\Linefeed stream))
           (setf start (1+ end))
           (when (<= (length string) start)
             (return)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Goofy aux values stuff

(defun aux-request-value (symbol request)
  "Returns the value associated with SYMBOL from the request object
REQUEST \(the default is the current request) if it exists.  The
second return value is true if such a value was found."
  (when request
    (let ((found (assoc symbol (aux-data request) :test #'eq)))
      (values (cdr found) found))))

(defsetf aux-request-value (symbol request)
    (new-value)
  "Sets the value associated with SYMBOL from the request object
REQUEST. If there is already a value associated with SYMBOL it will be
replaced."
  (once-only (symbol)
    (with-unique-names (place %request)
      `(let* ((,%request ,request)
              (,place (assoc ,symbol (aux-data ,%request) :test #'eq)))
         (cond
           (,place
            (setf (cdr ,place) ,new-value))
           (t
            (push (cons ,symbol ,new-value)
                  (aux-data ,%request))
            ,new-value))))))

(defun delete-aux-request-value (symbol request)
  "Removes the value associated with SYMBOL from the request object
REQUEST."
  (when request
    (setf (aux-data request)
            (delete symbol (aux-data request)
                    :key #'car :test #'eq)))
  (values))
