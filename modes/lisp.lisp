(in-package #:neomacs)

;;; Lisp mode

(define-mode lisp-mode (prog-mode) ()
  (:documentation "Lisp mode.")
  (:hooks auto-completion-mode))

(define-keys lisp-mode
  "C-M-x" 'eval-defun
  "C-c C-c" 'compile-defun
  "C-c C-k" 'lisp-compile-file
  "M-p" 'previous-compiler-note
  "M-n" 'next-compiler-note
  "M-." 'goto-definition
  "tab" 'show-completions
  "C-x C-e" 'eval-last-expression
  "C-c C-p" 'eval-print-last-expression)

(defvar *sexp-node-keymap*
  (make-keymap
   'sexp-node
   "tab" 'show-completions
   "M-(" 'wrap-paren
   "M-;" 'wrap-comment
   "M-r" 'lisp-raise
   "M-s" 'lisp-splice
   ";" 'open-comment
   "(" 'open-paren
   "\"" 'open-string
   "space" 'open-space))

(defvar *plaintext-node-keymap*
  (make-keymap
   'plaintext-node
   "(" 'self-insert-command
   "\"" 'self-insert-command
   "space" 'self-insert-command))

(defvar *object-presentation-keymap*
  (make-keymap
   'object-presentation
   "enter" 'inspect-presentation))

(defmethod selectable-p-aux ((buffer lisp-mode) pos)
  (and (if (eql *this-command* 'self-insert-command)
           (characterp (node-before pos))
           (if-let (node (node-after pos))
             (and (not (symbol-node-p node))
                  (not (and (new-line-node-p node)
                            (non-empty-symbol-node-p (node-before pos)))))
             (not (non-empty-symbol-node-p (node-before pos)))))
   (call-next-method)))

(defmethod render-focus-aux ((buffer lisp-mode) pos)
  (match pos
    ((end-pos node)
     (if (non-empty-symbol-node-p node)
         (let ((next (next-sibling node)))
           (cond ((not next)
                  (call-next-method buffer (end-pos (parent node))))
                 (t (call-next-method))))
         (call-next-method)))
    (_ (call-next-method))))

(defmethod block-element-p-aux ((buffer lisp-mode) element)
  (if (equal (tag-name element) "div")
      (not (class-p element "list" "comment"))
      (call-next-method)))

(defgeneric sexp-parent-p (buffer node)
  (:method ((buffer lisp-mode) node)
    (or (class-p node "list") (tag-name-p node "body"))))

(defvar *current-level-in-print* 0)

(defgeneric print-dom (object &key &allow-other-keys))

(defun compute-operator (node)
  (when (eql (first-child (parent node)) node)
    ""))

(defun compute-symbol (node)
  (let ((name (nth-value 1 (parse-prefix (text-content node)))))
    (if (plusp (length name))
        (ignore-errors (swank::parse-symbol (text-content node)))
        'ghost-symbol)))

(defun compute-symbol-type (node)
  (when-let (symbol (compute-symbol node))
    (cond ((eql symbol 'ghost-symbol) "ghost")
          ((or (and (special-operator-p symbol)
                    (not (member symbol '(function))))
               (member symbol '(declare)))
           "special-operator")
          ((macro-function symbol) "macro")
          ((keywordp symbol) "keyword")
          (t ""))))

(defmethod revert-buffer-aux :after ((buffer lisp-mode))
  (when (sexp-parent-p buffer (document-root buffer))
    (setf (attribute (document-root buffer) 'keymap)
          *sexp-node-keymap*)))

(defmethod on-node-setup progn ((buffer lisp-mode) (node element))
  (set-attribute-function node "operator" 'compute-operator)
  (with-post-command (node 'parent)
    (let ((parent (parent node)))
      (cond
        ((symbol-node-p parent)
         (let ((prev (previous-sibling node))
               (next (next-sibling node)))
           (cond ((and (not prev) (not next))
                  (raise-node node))
                 ((not prev)
                  (move-nodes node (pos-right node)
                              parent))
                 ((not next)
                  (move-nodes node nil (pos-right parent)))
                 (t (let ((second-symbol (split-node node)))
                      (move-nodes node (pos-right node)
                                  second-symbol))))))
        ((class-p parent "comment" "string")
         (replace-node
          node
          (with-output-to-string (s)
            (write-dom-aux buffer node s)))))))
  (when (symbol-node-p node)
    (set-attribute-function node "symbol-type" 'compute-symbol-type))
  (when (class-p node "comment" "string")
    (setf (attribute node 'keymap) *plaintext-node-keymap*))
  (when (class-p node "object")
    (setf (attribute node 'read-only) t)
    (setf (attribute node 'keymap) *object-presentation-keymap*)))

(defmethod on-node-setup progn ((buffer lisp-mode) (node text-node))
  (with-post-command (node 'parent)
    (let ((parent (parent node)))
      (when (sexp-parent-p buffer parent)
        (let ((nodes (read-dom-from-string (text node))))
          ;; Assume NODES are non-empty and does not contain text-nodes
          (apply #'insert-nodes (or (next-sibling node)
                                    (end-pos parent))
                 nodes)
          (delete-nodes (text-pos node 0) (car nodes)))))))

(defun make-list-node (children)
  (lret ((node (make-instance 'element :tag-name "div")))
    (setf (attribute node "class") "list")
    (iter (for c in children)
      (append-child node c))))

(defun make-atom-node (class text)
  (lret ((node (make-instance 'element :tag-name "span")))
    (setf (attribute node "class") class)
    (when (plusp (length text))
      (append-child node (make-instance 'text-node :text text)))))

(defun make-presentation-node (text object)
  (lret ((node (make-atom-node "object" text)))
    (setf (attribute node 'presentation) object)))

(defun list-node-p (node)
  (class-p node "list"))

(defun atom-node-p (node)
  (class-p node "symbol" "string" "object" "comment"))

(defun sexp-node-p (node)
  (class-p node "list" "symbol" "string" "object"))

(defun symbol-node-p (node)
  (class-p node "symbol"))

(defun non-empty-symbol-node-p (node)
  (and (symbol-node-p node) (first-child node)))

(defmethod print-dom ((cons cons) &key)
  (if (and *print-level*
           (>= *current-level-in-print* *print-level*))
      (make-presentation-node "#" cons)
      (let ((*current-level-in-print*
              (1+ *current-level-in-print*)))
        (make-list-node
         (iter (for i from 0)
           (for tail first cons then (cdr tail))
           (typecase tail
             (cons
              (if (and *print-length* (>= i *print-length*))
                  (progn
                    (collect (make-presentation-node "..." tail))
                    (finish))
                  (collect (print-dom (car tail)))))
             (null)
             (t (collect (make-atom-node "symbol" "."))
              (collect (print-dom tail))))
           (while (consp tail)))))))

(defmethod print-dom ((null null) &key)
  (make-list-node nil))

(defmethod print-dom ((symbol (eql '%br)) &key)
  (make-new-line-node))

(defmethod print-dom ((symbol symbol) &key)
  (make-atom-node "symbol"
                  (let ((*print-case* :downcase))
                    (prin1-to-string symbol))))

(defmethod print-dom ((string string) &key)
  (make-atom-node "string" string))

(defmethod print-dom ((obj number) &key)
  (make-atom-node "symbol" (prin1-to-string obj)))

(defmethod print-dom ((obj character) &key)
  (make-atom-node "symbol" (prin1-to-string obj)))

(defmethod print-dom ((obj t) &key)
  ;; Turn of CL's pretty printer because it introduces
  ;; unnecessary line breaks
  (let (*print-pretty*)
    (make-presentation-node (prin1-to-string obj) obj)))

(define-command open-paren :mode lisp-mode
  (&optional (marker (focus)))
  (let ((node (make-list-node nil)))
    (insert-nodes marker node)
    (setf (pos marker) (end-pos node))))

(define-command wrap-paren :mode lisp-mode
  (&optional (pos (focus)))
  (let ((node (make-list-node nil)))
    (setq pos (or (pos-up-ensure pos #'sexp-node-p)
                  (error 'top-of-subtree)))
    (wrap-node pos node)))

(define-command open-string :mode lisp-mode
  (&optional (marker (focus)))
  (let ((node (make-atom-node "string" "")))
    (insert-nodes marker node)
    (setf (pos marker) (end-pos node))))

(define-command open-space :mode lisp-mode
  (&optional (marker (focus)))
  (if (class-p (node-containing marker) "symbol")
      (setf (pos marker) (pos-down (split-node marker)))
      (let ((node (make-atom-node "symbol" "")))
        (insert-nodes marker node)
        (setf (pos marker) (end-pos node)))))

(define-command open-comment :mode lisp-mode
  (&optional (marker (focus)))
  (labels ((cycle-level (n)
             (lret ((n (1+ (mod n 4))))
               (message "Comment Level -> ~a" n))))
    (if-let
        (node (find-if (alex:rcurry #'class-p "comment")
                       (list (pos marker)
                             (pos-prev marker))))
      (setf (attribute node "comment-level")
            (prin1-to-string
             (cycle-level
              (parse-number:parse-number
               (attribute node "comment-level")))))
      (let ((node (make-atom-node "comment" "")))
        (setf (attribute node "comment-level") "1")
        (insert-nodes marker node)
        (setf (pos marker) (end-pos node))))))

(define-command wrap-comment :mode lisp-mode
  (&optional (pos (focus)))
  (let ((node (make-atom-node "comment" "")))
    (setq pos (or (pos-up-ensure pos #'sexp-node-p)
                  (error 'top-of-subtree)))
    (wrap-node pos node)))

(define-command lisp-raise :mode lisp-mode
  (&optional (pos (focus)))
  (setq pos (or (pos-up-ensure pos #'sexp-node-p)
                (error 'top-of-subtree)))
  (raise-node pos))

(define-command lisp-splice :mode lisp-mode
  (&optional (pos (focus)))
  (setq pos (or (pos-up-until pos #'list-node-p)
                (error 'top-of-subtree)))
  (splice-node pos))

;;; DOM to Sexp parser

(defvar *form-node-table* nil
  "Hash table that map forms to node that generates them.")

(defun parse-prefix (string)
  "Parse prefix from STRING.
Return a list of wrapper functions and the rest of STRING.  The list
of wrapper functions can be applied to some Lisp object one-by-one and
reproduce the effect of parsed prefix."
  (let (wrappers (i 0))
    (iter (while (< i (length string)))
      (case (aref string i)
        ((#\')
         (incf i)
         (push (lambda (next) (list 'quote next)) wrappers))
        ((#\`)
         (incf i)
         (push (lambda (next) (list 'sb-int:quasiquote next)) wrappers))
        ((#\,)
         (incf i)
         (case (when (< i (length string))
                 (aref string i))
           ((#\@)
            (incf i)
            (push (lambda (next) (sb-int:unquote next 2)) wrappers))
           (t
            (push (lambda (next) (sb-int:unquote next 0)) wrappers))))
        ((#\#)
         (incf i)
         (case (when (< i (length string))
                 (aref string i))
           ((#\')
            (incf i)
            (push (lambda (next) (list 'function next)) wrappers))
           ((#\p)
            (incf i)
            (push (lambda (next) (pathname next)) wrappers))
           ((nil)
            (push (lambda (next) (apply #'vector next)) wrappers))
           (t (decf i) (return))))
        (t (return))))
    (values wrappers (subseq string i))))

(defun ghost-symbol-p (node)
  "Test NODE is a symbol node with only prefix.

These symbol nodes do not correspond to Sexp symbols, instead act on
the following node."
  (when (symbol-node-p node)
    (bind (((:values wrappers rest)
            (parse-prefix (text-content node))))
      (when (zerop (length rest))
        wrappers))))

(defun node-to-sexp (node &optional (intern t))
  "Parse DOM NODE as a Lisp object.
It also takes into account any prefix preceding NODE.

If INTERN is t, this function interns symbol; otherwise, symbols not
found are replaced with a dummy symbol."
  (labels ((apply-wrappers (wrappers node)
             (iter (for w in wrappers)
               (setq node (funcall w node)))
             node)
           (dot-p (node)
             (and (symbol-node-p node)
                  (equal (text-content node) ".")))
           (process (node)
             (let ((sexp
                     (cond ((list-node-p node)
                            (let ((children (sexp-children node)))
                              (if (dot-p (car (last children 2)))
                                  (nconc
                                   (mapcar #'process (butlast children 2))
                                   (process (lastcar children)))
                                  (mapcar #'process children))))
                           ((equal "string" (attribute node "class"))
                            (text-content node))
                           ((symbol-node-p node)
                            (bind (((:values wrappers rest)
                                    (parse-prefix (text-content node))))
                              (apply-wrappers
                               wrappers
                               (if intern
                                   (read-from-string rest)
                                   (or (find-symbol
                                        ;; TODO: handle *readtable-case*
                                        (string-upcase rest)
                                        *package*)
                                       'dummy)))))
                           ((new-line-node-p node) nil)
                           ((class-p node "object")
                            (or (attribute node 'presentation)
                                (error "Presentation attribute missing from ~a" node)))
                           (t (error "Unrecognized DOM node: ~a" node)))))
               (when *form-node-table*
                 (setf (gethash sexp *form-node-table*)
                       (print node)))
               (if-let (wrappers (ghost-symbol-p (previous-sibling node)))
                 (apply-wrappers wrappers sexp)
                 sexp))))
    (process node)))

(defgeneric current-package-aux (buffer pos)
  (:method ((buffer buffer) (pos t))
    (find-package "NEOMACS-USER"))
  (:method ((buffer lisp-mode) pos)
    (with-marker (marker pos)
      (or (find-package
           (handler-case
               (iter (beginning-of-defun marker)
                 (for node = (node-after marker))
                 (for c = (sexp-children node))
                 (when (and
                        (car c)
                        (equal "IN-PACKAGE"
                               (string-upcase (text-content (car c)))))
                   (when-let (name (cadr c))
                     (return (string-upcase
                              (str:trim (text-content name)
                                        :char-bag "#:"))))))
             (motion-error ())))
          (call-next-method)))))

(defun current-package (&optional (marker-or-pos (focus)))
  "Return the package in the context of MARKER-OR-POS.
This is determined by searching for a `in-package' top-level form
before MARKER-OR-POS."
  (let ((pos (resolve-marker marker-or-pos)))
    (current-package-aux (host pos) pos)))

;;; Compiler notes

(defvar *compilation-buffer* nil
  "The buffer for outputting compilation notes.")

(defvar *compilation-document-root* nil
  "Document root of the buffer being compiled.

Used for resolving source-path to DOM node.")

(defvar *compilation-single-form* nil
  "If t, the first element in source-path should always be 0 and is ignored.")

(defun evaluate-feature-expression-node (node)
  (let ((*package* (find-package :keyword)))
    (handler-bind ((warning #'muffle-warning))
      (ignore-errors
       (if (stringp node)
           (sb-int:featurep
            (find-symbol (string-upcase node) *package*))
           (sb-int:featurep (node-to-sexp node nil)))))))

(defun handle-feature-expressions (nodes)
  (iter
    (while nodes)
    (for n = (car nodes))
    (cond
      ((and (symbol-node-p n)
            (sera:string-prefix-p "#+" (text-content n)))
       (if (evaluate-feature-expression-node
            (if (> (length (text-content n)) 2)
                (subseq (text-content n) 2)
                (prog1 (cadr nodes)
                  (setq nodes (cdr nodes)))))
           (setq nodes (cdr nodes))
           (setq nodes (cddr nodes))))
      ((and (symbol-node-p n)
            (sera:string-prefix-p "#-" (text-content n)))
       (if (evaluate-feature-expression-node
            (if (> (length (text-content n)) 2)
                (subseq (text-content n) 2)
                (prog1 (cadr nodes)
                  (setq nodes (cdr nodes)))))
           (setq nodes (cddr nodes))
           (setq nodes (cdr nodes))))
      (t (collect n)
         (setq nodes (cdr nodes))))))

(defun sexp-children (node)
  (handle-feature-expressions
   (remove-if
    (lambda (node)
      (or (not (sexp-node-p node))
          (ghost-symbol-p node)))
    (child-nodes node))))

(defun sexp-nth-child (node n)
  (nth n (sexp-children node)))

(defun sexp-child-number (node)
  (position node (sexp-children (parent node))))

(defun find-node-for-form-path (root path)
  (iter (with node = root)
    (for i in path)
    (when-let (child (sexp-nth-child node i))
      (setq node child))
    (finally (return node))))

(defun find-node-for-compiler-note (context)
  (or
   (when-let (form (sb-c::compiler-error-context-original-form
                    context))
     (gethash form *form-node-table*))
   (when-let (path (reverse (sb-c::compiler-error-context-original-source-path context)))
     (when *compilation-single-form*
       (unless (eql (car path) 0)
         (warn "Compiling single form but source path ~a does not start with 0." path))
       (pop path))
     (find-node-for-form-path
      *compilation-document-root* path))))

(defun handle-notification-condition (condition)
  (let (id)
    (with-current-buffer *compilation-buffer*
      (let ((*inhibit-read-only* t)
            (node (make-element
                   "p" :children
                   (list (princ-to-string condition)))))
        (insert-nodes (focus) node)
        (setq id (attribute node "neomacs-identifier"))))

    (when-let* ((context (sb-c::find-error-context nil))
                (node (find-node-for-compiler-note context)))
      (setf (attribute node "compiler-note-severity")
            (typecase condition
              (sb-ext:compiler-note "note")
              (sb-c:compiler-error  "error")
              (error                "error")
              (style-warning        "style-warning")
              (warning              "warning")
              (t "error")))
      (setf (attribute node "compiler-note-id") id))))

(define-mode compilation-buffer-mode (read-only-mode)
  ((for-buffer :initform nil :initarg :buffer)))

(defmacro with-collecting-notes (() &body body)
  `(let ((*form-node-table* (make-hash-table))
         (*compilation-buffer*
           (get-buffer-create "*compilation*"
                              :mode 'compilation-buffer-mode)))
     (clear-compiler-notes)
     (setf (for-buffer *compilation-buffer*) (current-buffer))
     (with-current-buffer *compilation-buffer*
       (let ((*inhibit-read-only* t))
         (erase-buffer)))
     (handler-bind
         ((sb-c:fatal-compiler-error #'handle-notification-condition)
          (sb-c:compiler-error #'handle-notification-condition)
          (sb-ext:compiler-note #'handle-notification-condition)
          (error #'handle-notification-condition)
          (warning #'handle-notification-condition))
       ,@body)))

(defun clear-compiler-notes ()
  (do-elements
      (lambda (node)
        (when (attribute node "compiler-note-severity")
          (setf (attribute node "compiler-note-severity")
                nil)))
    (document-root (current-buffer))))

(defun goto-compiler-note (id)
  (when-let (buffer (get-buffer "*compilation*"))
    (if (eql (current-buffer) (for-buffer buffer))
        (with-current-buffer buffer
          (do-elements
              (lambda (node)
                (when (equal (attribute node "neomacs-identifier")
                             id)
                  (setf (pos (focus)) node)
                  (return-from goto-compiler-note)))
            (document-root buffer)))
        (message "Compilation output has been overwrite by other buffer"))))

(define-command previous-compiler-note (&optional (marker (focus)))
  "Move to next compiler note."
  (if-let (pos
           (npos-prev-until
            (pos marker)
            (lambda (node)
              (and (element-p node)
                   (attribute node "compiler-note-id")))))
    (progn
      (setf (pos marker) pos)
      (goto-compiler-note (attribute pos "compiler-note-id")))
    (user-error "No previous compiler note")))

(define-command next-compiler-note (&optional (marker (focus)))
  "Move to previous compiler note."
  (if-let (pos
           (npos-next-until
            (pos marker)
            (lambda (node)
              (and (element-p node)
                   (attribute node "compiler-note-id")))))
    (progn
      (setf (pos marker) pos)
      (goto-compiler-note (attribute pos "compiler-note-id")))
    (user-error "No next compiler note")))

;;; Eval/compile commands

(define-command eval-defun :mode lisp-mode ()
  "Evaluate the surrounding top-level form.

Echo the result."
  (with-marker (marker (focus))
    (beginning-of-defun marker)
    (let* ((node (pos marker))
           (*package* (current-package marker))
           (result (eval (node-to-sexp node))))
      (message "=> ~a" result))))

(define-command compile-defun :mode lisp-mode ()
  "Compile the surrounding top-level form.

Highlights compiler notes."
  (with-marker (marker (focus))
    (beginning-of-defun marker)
    (let ((cookie (uuid:format-as-urn nil (uuid:make-v4-uuid)))
          (node (pos marker)))
      (setf (attribute node 'compile-cookie) cookie)
      (with-collecting-notes ()
        (let* ((*package* (current-package marker))
               (*compilation-single-form* t)
               (*compilation-document-root* node)
               (input-file
                 (make-pathname
                  :name cookie :type "lisp"
                  :defaults (uiop:temporary-directory)))
               output-file)
          (with-compilation-unit
              (:source-plist
               (list :neomacs-buffer (name (current-buffer))
                     :neomacs-compile-cookie cookie))
            (with-open-file (s input-file
                               :direction :output
                               :if-exists :supersede)
              (write-dom-aux (current-buffer) node s))
            (unwind-protect
                 (progn
                   (load (setq output-file (compile-file input-file)))
                   (message "Compiled and loaded"))
              (uiop:delete-file-if-exists input-file)
              (uiop:delete-file-if-exists output-file)))
          (unless (frame-root *compilation-buffer*)
            (when (first-child (document-root *compilation-buffer*))
              (display-buffer *compilation-buffer*))))))))

(defun last-expression (pos)
  (setq pos (resolve-marker pos))
  (when (and (end-pos-p pos)
             (symbol-node-p (end-pos-node pos)))
    (return-from last-expression (end-pos-node pos)))
  (iter
    (unless pos (error 'beginning-of-subtree))
    (for node = (node-before pos))
    (until (sexp-node-p node))
    (setq pos (npos-prev pos)))
  (node-before pos))

(define-command eval-last-expression :mode lisp-mode
  (&optional (marker (focus)))
  "Evaluate the last expression and echo the result."
  (let* ((*package* (current-package marker))
         (result (eval (node-to-sexp (last-expression (pos marker))))))
    (message "=> ~S" result)))

(define-command eval-print-last-expression :mode lisp-mode
  (&optional (marker (focus)))
  "Evaluate the last expression and insert result into current buffer."
  (let* ((*package* (current-package marker))
         (node (last-expression marker))
         (pos (pos-right node))
         (last-line (make-new-line-node)))
    (if (new-line-node-p (node-after pos))
        (setf pos (pos-right pos))
        (insert-nodes pos (make-new-line-node)))
    (insert-nodes pos (print-dom (eval (node-to-sexp node)))
                  last-line)
    (setf (pos marker) (pos-right last-line))))

(define-command lisp-compile-file :mode lisp-mode ()
  "Compile current file.

Highlight compiler notes."
  (when (modified (current-buffer))
    (when (read-yes-or-no "Save file? ")
      (save-buffer)))
  (let ((*compilation-document-root*
          (document-root (current-buffer))))
    (with-collecting-notes ()
      (iter (with i = 0)
        (for c in (child-nodes *compilation-document-root*))
        (when (sexp-node-p c)
          (setf (attribute c 'tlf-number) i)
          (incf i)))
      (load (compile-file (file-path (current-buffer))))
      (message "Compiled and loaded"))))

;;; Xref

(defparameter *definition-types*
  '(:variable :constant :type :symbol-macro :macro
    :compiler-macro :function :generic-function :method
    :setf-expander :structure :condition :class
    :method-combination :package :transform :optimizer
    :vop :source-transform :ir1-convert :declaration
    :alien-type)
  "SB-INTROSPECT definition types.")

(defun find-node-for-source
    (pathname tlf-number form-number plist)
  (when-let (buf (or (get-buffer (getf plist :neomacs-buffer))
                     (find-file-buffer pathname)))
    (let* ((candidate-nodes
             (if-let (c (getf plist :neomacs-compile-cookie))
               (remove-if-not
                (lambda (n)
                  (equal c (attribute n 'compile-cookie)))
                (child-nodes (document-root (current-buffer))))
               (sexp-children (document-root (current-buffer)))))
           (tlf (or (find tlf-number candidate-nodes
                          :key (alex:rcurry #'attribute 'tlf-number))
                    (nth tlf-number candidate-nodes)))
           (translation
             (sb-di::form-number-translations
              (node-to-sexp tlf) 0))
           (form-path
             (if (< form-number (length translation))
                 (reverse
                  (cdr (aref translation form-number)))
                 (progn
                   (message "Inconsistent form-number translation")
                   nil))))
      (pop form-path)
      (find-node-for-form-path tlf form-path))))

(defvar *relocated-source-list*
  #.(cons 'list
          (mapcar #'uiop:truenamize
                  '(#P"~/quicklisp/dists/ultralisp/software/"
                    #P"~/quicklisp/dists/quicklisp/software/"
                    #P"~/quicklisp/local-projects/"))))

(defun translate-relocated-source (pathname)
  (when (or (not ceramic.runtime:*releasep*)
            (uiop:file-exists-p pathname))
    (return-from translate-relocated-source pathname))
  (iter (for from in *relocated-source-list*)
    (with to = (ceramic.runtime:executable-relative-pathname
                #P"src/"))
    (multiple-value-bind (p rest)
        (alex:starts-with-subseq
         (pathname-directory from)
         (pathname-directory pathname)
         :test 'equal :return-suffix t)
      (when p
        (return (make-pathname
                 :directory
                 (append (pathname-directory to) rest)
                 :defaults pathname))))
    (finally (return pathname))))

(defun visit-source (pathname tlf-number form-number plist)
  (with-current-buffer
      (or (get-buffer (getf plist :neomacs-buffer))
          (when pathname (find-file (translate-relocated-source pathname)))
          (user-error "Unknown source location"))
    (setf (pos (focus))
          (find-node-for-source
           pathname tlf-number form-number plist))))

(defun visit-definition (definition)
  "Switch to a buffer displaying DEFINITION.

DEFINITION should be a `sb-introspect:definition-source'."
  (visit-source
   (sb-introspect:definition-source-pathname definition)
   (car (sb-introspect:definition-source-form-path definition))
   (sb-introspect:definition-source-form-number definition)
   (sb-introspect:definition-source-plist definition)))

(define-mode xref-list-mode (list-mode)
  ((for-symbol :initform (alex:required-argument :symbol)
               :initarg :symbol)))

(define-keys xref-list-mode
  "q" 'quit-buffer
  "enter" 'xref-list-goto-definition)

(defun render-xref-definition (symbol type def)
  (attach-presentation
   (make-element
    "tr"
    :children
    (list (make-element
           "td" :children
           (list (prin1-to-string type)))
          (make-element
           "td" :children
           (list (print-arglist
                  (sb-introspect::definition-source-description def)
                  (symbol-package symbol))))
          (make-element
           "td" :children
           (list (princ-to-string
                  (translate-relocated-source
                   (sb-introspect::definition-source-pathname def)))))))
   def))

(defmethod generate-rows ((buffer xref-list-mode))
  (let ((*print-case* :downcase)
        (symbol (for-symbol buffer)))
    (iter (for (type def) in (find-definitions symbol))
      (insert-nodes
       (focus) (render-xref-definition symbol type def)))))

(defun find-definitions (symbol &optional (types *definition-types*))
  "Find all definitions for SYMBOL.

Return a list with items of the form `(definition-type
sb-introspect:definition-source)'."
  (iter (for type in types)
    (appending
     (mapcar (alex:curry #'list type)
             (sb-introspect:find-definition-sources-by-name
              symbol type)))))

(define-command xref-list-goto-definition
  :mode xref-list-mode ()
  (visit-definition
   (presentation-at (focus) 'sb-introspect:definition-source t))
  (quit-buffer))

(define-command goto-definition
  :mode lisp-mode ()
  "Goto definition of symbol under focus."
  (if-let (node (symbol-around (focus)))
    (let ((name (nth-value 1 (parse-prefix (text-content node)))))
      (when (> (length name) 0)
        (let ((*package* (current-package)))
          (if-let (symbol (swank::parse-symbol name (current-package)))
            (let ((definitions (find-definitions symbol)))
              (case (length definitions)
                (0 (user-error "No known definition for ~a" symbol))
                (1 (push-global-marker)
                 (visit-definition (cadr (car definitions))))
                (t (push-global-marker)
                 (pop-to-buffer
                  (make-buffer
                   "*xref*" :mode 'xref-list-mode
                   :symbol symbol :revert t)))))
            (user-error "No symbol named ~a" name)))))
    (user-error "No symbol under focus")))

;;; Auto-completion

(defun atom-around (pos)
  (let ((parent (node-containing pos))
        (before (node-before pos))
        (after (node-after pos)))
    (cond ((atom-node-p parent) parent)
          ((atom-node-p before) before)
          ((atom-node-p after) after))))

(defun symbol-around (pos)
  (when-let (node (atom-around pos))
    (when (equal "symbol" (attribute node "class"))
      node)))

(defmethod compute-completion ((buffer lisp-mode) pos)
  (when-let (node (symbol-around pos))
    (let* ((package (current-package pos))
           (text (text-content node))
           (name (nth-value 1 (parse-prefix text)))
           (swank::*buffer-package* package)
           (completions (car (swank:fuzzy-completions
                              name package
                              :limit (completion-limit buffer)))))
      (values
       (range (text-pos (first-child node) (- (length text) (length name)))
              (pos-down-last node))
       (iter (for c in completions)
         (collect (list (car c) (remove #\- (lastcar c)))))))))

;;; Autodoc

(define-mode autodoc-mode () ()
  (:documentation
   "Show documentation of form around focus.")
  (:toggler t))

(defun format-swank-highlighted-arglist (string)
  (let ((match (ppcre:all-matches "===>.*<===" string)))
    (if match
        (list (subseq string 0 (car match))
              (make-element
               "span" :class "focus-arg" :children
               (list (str:trim (subseq string
                                       (+ (car match) 4)
                                       (- (cadr match) 4)))))
              (subseq string (cadr match)))
        (list string))))

(defun compute-autodoc (pos)
  (let ((*package* (current-package pos)))
    (let (form form-path operator arglist)
      (setq pos (or (pos-up-ensure pos #'sexp-node-p)
                    (return-from compute-autodoc nil)))
      (iter
        (for last first nil then cur)
        (for cur first pos then (pos-up cur))
        (while (sexp-node-p cur))
        (when last
          (push (or (sexp-child-number last)
                    (return-from compute-autodoc))
                form-path))
        (for operator-node = (first-child cur))
        (for symbol = (when (symbol-node-p operator-node)
                        (compute-symbol operator-node)))
        (when (fboundp symbol)
          (multiple-value-bind (l unavailable)
              (sb-introspect:function-lambda-list symbol)
            (unless unavailable
              (setq arglist l operator symbol
                    form (ignore-errors (node-to-sexp cur nil)))
              (return)))))
      (when operator
        (let ((arglist (swank::decode-arglist arglist)))
          (append
           (format-swank-highlighted-arglist
            (swank::decoded-arglist-to-string
             arglist
             :operator operator
             :highlight (swank::form-path-to-arglist-path form-path form arglist)))
           (when (documentation operator 'function)
             (list ": "
                   (make-element
                    "span" :class "docstring"
                           :children (short-doc operator))))))))))

(defun autodoc-for-thing (symbol)
  (let ((doc
          (when (documentation symbol 'function)
            (list (make-element
                   "span" :class "docstring"
                          :children (short-doc symbol))))))
    (append
     (when (fboundp symbol)
       (let ((*print-case* :downcase))
         (list
          (str:concat
           (print-arglist
            (cons symbol
                  (sb-introspect:function-lambda-list
                   symbol))
            (symbol-package symbol))
           (when doc ": ")))))
     doc)))

(defun maybe-show-autodoc ()
  (when-let* ((frame-root (current-frame-root))
              (echo-area (echo-area frame-root)))
    (unless (first-child (document-root echo-area))
      (let (*message-log-max*)
        (if (typep (current-buffer) 'active-completion-mode)
            (progn
              (pushnew 'echo-area-autodoc (styles echo-area))
              (message
               (let ((*package* (current-package (focus)))
                     (row (node-after (focus (completion-buffer (current-buffer))))))
                 (autodoc-for-thing
                  (ignore-errors
                   (swank::parse-symbol
                    (text-content (first-child row))))))))
           (when-let (nodes (compute-autodoc (pos (focus))))
             (pushnew 'echo-area-autodoc (styles echo-area))
             (message nodes)))))))

(defvar *autodoc-wait-seconds* 0.5
  "Seconds to wait before updating autodocs echo area.")

(defvar *autodoc-turn* 0)

(defmethod on-post-command progn ((buffer autodoc-mode))
  (if (or (not *autodoc-wait-seconds*) (zerop *autodoc-wait-seconds*))
      (maybe-show-autodoc)
      (let ((my-turn (incf *autodoc-turn*)))
        (sb-ext:schedule-timer
         (sb-ext:make-timer (lambda ()
                              (when (= my-turn *autodoc-turn*)
                                (maybe-show-autodoc))))
         *autodoc-wait-seconds*))))

;;; Parser

(defun read-symbol (stream c)
  (unread-char c stream)
  (append-child
   *dom-output*
   (make-atom-node "symbol" (read-constituent stream 'read-symbol '(#\\)))))

(defun read-string (stream c)
  (declare (ignore c))
  (append-child
   *dom-output*
   (make-atom-node
    "string"
    (iter (for c = (read-char stream))
      (until (eql c #\"))
      (if (eql c #\\)
          (collect (read-char stream) result-type string)
          (collect c result-type string))))))

(defun read-line-comment (stream c)
  (declare (ignore c))
  (let ((n 1))
    (iter (for c = (peek-char nil stream nil nil t))
      (while (eql c #\;))
      (incf n)
      (read-char stream))
    (bind (((:values line eof-p) (read-line stream))
           (node (make-atom-node "comment" line)))
      (setf (attribute node "comment-level") (prin1-to-string n))
      (append-child *dom-output* node)
      (unless eof-p (unread-char #\Newline stream)))))

(defvar *lisp-syntax-table*
  (lret ((table (make-syntax-table)))
    (set-syntax-range table 33 127 'read-symbol)
    (setf (get-syntax-table #\( table) (make-read-delimited #\)))
    (setf (get-syntax-table #\) table) nil)
    (setf (get-syntax-table #\  table) 'read-ignore)
    (setf (get-syntax-table #\Newline table) 'read-newline)
    (setf (get-syntax-table #\Page table) 'read-newline)
    (setf (get-syntax-table #\Tab table) 'read-ignore)
    (setf (get-syntax-table #\" table) 'read-string)
    (setf (get-syntax-table #\; table) 'read-line-comment)))

(defmethod read-dom-aux ((buffer lisp-mode) stream)
  (let ((*syntax-table* *lisp-syntax-table*))
    (read-dispatch *syntax-table* stream)))

;;; Pretty printer

(defun symbol-indentation (symbol)
  (case symbol
    ((lambda) 1)
    ((block catch return-from throw eval-when
            multiple-value-call multiple-value-prog1
            unwind-protect)
     1)
    ((locally progn) 0)
    ((progv) 1)
    ((flet labels macrolet)
     '((&whole 4 &rest (&whole 1 4 4 &rest 2)) &rest 2))
    ((let let* symbol-macrolet dx-let)
     '((&whole 4 &rest (&whole 1 1 2)) &rest 2))
    ((case ccase ecase)
     '(4 &rest (&whole 2 &rest 1)))
    ((handler-case handler-bind) 1)
    (t (when-let (mf (macro-function symbol))
         (or (sb-pretty::macro-indentation mf)
             (when (sera:string-prefix-p "DEF" (symbol-name symbol))
               1))))))

(defun normalize-indent-spec (indent-spec)
  (when indent-spec
    (when (numberp indent-spec)
      (setq indent-spec
            (nconc (make-list indent-spec :initial-element 4)
                   (list '&rest 2))))
    (push nil indent-spec)
    indent-spec))

(defun pprint-form (list-node stream indent-spec)
  (pprint-logical-block (stream nil :prefix "(" :suffix ")")
    (if indent-spec
        (iter
          (with prev = nil)
          (for c in (child-nodes list-node))
          (unless (or (first-iteration-p)
                      (new-line-node-p prev))
            (write-char #\space stream))
          (if (sexp-node-p c)
              (let* ((this-indent-spec
                       (if (eql (car indent-spec) '&rest)
                           (cadr indent-spec)
                           (pop indent-spec)))
                     (next-indent-spec
                       (if (eql (car indent-spec) '&rest)
                           (cadr indent-spec)
                           (car indent-spec)))
                     (indent-number
                       (or (when (numberp next-indent-spec)
                             next-indent-spec)
                           (getf next-indent-spec '&whole)
                           1)))
                (pprint-indent :block (1- indent-number) stream)
                (if (and (listp this-indent-spec) (list-node-p c))
                    (progn
                      (setq this-indent-spec (copy-tree this-indent-spec))
                      (remf this-indent-spec '&whole)
                      (pprint-form c stream this-indent-spec))
                    (write c :stream stream)))
              (write c :stream stream))
          (setq prev c))
        ;; Print function call form
        (iter
          (with prev = nil)
          (with i = 0)
          (for c in (child-nodes list-node))
          (unless (or (first-iteration-p)
                      (new-line-node-p prev)
                      (ghost-symbol-p prev))
            (write-char #\space stream))
          (when (and (sexp-node-p c) (<= i 1))
            (pprint-indent :current 0 stream))
          (write c :stream stream)
          (when (sexp-node-p c)
            (incf i))
          (setq prev c)))))

(defvar *lisp-pprint-dispatch*
  (lret ((*print-pprint-dispatch*
          (copy-pprint-dispatch *print-pprint-dispatch*)))
    (set-pprint-dispatch
     'element
     (lambda (stream self &rest noise)
       (declare (ignore noise))
       (cond ((list-node-p self)
              (if-let (op (first-child self))
                (pprint-form self stream
                             (if (when-let (prev (previous-sibling self))
                                   (and (class-p prev "symbol")
                                        (sera:string-suffix-p
                                         "'" (text-content prev))))
                                 '(&rest 1)
                                 (normalize-indent-spec
                                  (symbol-indentation
                                   (compute-symbol op)))))
                (write-string "()" stream)))
             ((new-line-node-p self)
              (pprint-newline :mandatory stream))
             ((symbol-node-p self)
              (write-string (text-content self) stream))
             ((equal (attribute self "class") "string")
              (write
               (with-output-to-string (s)
                 (iter (for c in (child-nodes self))
                   (write c :stream s)))
               :stream stream))
             ((equal (attribute self "class") "comment")
              (dotimes (_ (parse-number:parse-number (attribute self "comment-level")))
                (write-char #\; stream))
              (write-char #\  stream)
              (iter (for c in (child-nodes self))
                (write c :stream stream)))
             (t (error "TODO")))))

    (set-pprint-dispatch
     'text-node
     (lambda (stream self &rest noise)
       (declare (ignore noise))
       (write-string (text self) stream)))))

(defmethod write-dom-aux ((buffer lisp-mode) node stream)
  (let ((*print-pprint-dispatch* *lisp-pprint-dispatch*)
        (*package* (if (eql (host node) buffer)
                       (current-package node)
                       (current-package (focus buffer))))
        (*print-pretty* t))
    (prin1 node stream)))

;;; Minibuffer

(define-mode lisp-minibuffer-mode (lisp-mode minibuffer-mode) ())

(defmethod sexp-parent-p ((buffer lisp-minibuffer-mode) node)
  (or (class-p node "list") (tag-name-p node "input")))

(defmethod revert-buffer-aux :after ((buffer lisp-minibuffer-mode))
  (setf (attribute (minibuffer-input-element buffer) 'keymap)
        *sexp-node-keymap*))

(defmethod minibuffer-input ((buffer lisp-minibuffer-mode))
  (node-to-sexp (first-child (minibuffer-input-element buffer))))

(define-command eval-expression ()
  "Read a Lisp expression from minibuffer and evaluate it."
  (let ((*package* (current-package)))
    (message
     "~S"
     (eval (read-from-minibuffer
            (format nil "Eval (~a): " (package-name *package*))
            :mode 'lisp-minibuffer-mode)))))

(define-keys :global
  "M-:" 'eval-expression)

;;; Style

(defstyle sexp-node `(((:append ":not(:last-child):not(.focus-tail)")
                       :margin-right "0.4em")
                      :display "inline-block"
                      :vertical-align "top"
                      :position "relative"
                      :white-space "pre"))
(defstyle list-node
    `(((:append "::before")
       :content "("
       :margin-left "-0.4em")
      ((:append "::after")
       :content ")"
       :vertical-align "bottom")
      ((:append ":not(:last-child)")
       :margin-right "0.4em")
      ((:append ".focus-tail::after")
       :content ")"
       :width "auto"
       :inherit selection)
      ((:append ".focus::before")
       :inherit selection)
      :inherit sexp-node
      :padding-left "0.4em"))

(defstyle string-node `(((:append "::before") :content "\"")
                        ((:append "::after") :content "\"")
                        ((:append ":not(:last-child)")
                         :margin-right "0.4em")
                        ((:append ".focus::before")
                         :inherit selection)
                        ((:append ".focus-tail::after")
                         :content "\""
                         :width "auto"
                         :inherit selection)
                        :inherit (sexp-node string)))
(defstyle symbol-node `(:inherit sexp-node))
(defstyle object-node `(:inherit symbol-node
                        :text-decoration "underline"))
(defstyle empty-symbol-node `(((:append "::after")
                               :content "_")
                              ((:append ":not(:last-child)")
                               :margin-right "0.4em")
                              ((:append ".focus-tail::after")
                               :content "_"
                               :width "auto"
                               :inherit selection)))
(defstyle comment-node `(((:append "::after") :content "⁣")
                         :display "inline-block"
                         :white-space "pre-wrap"))
(defstyle comment-node-1 `(:position "sticky"
                           :left "20em"
                           :border-left "0.3rem solid #a997a0"
                           :padding-left "0.3rem"
                           :inherit comment))
(defstyle comment-node-2 `(:border-left "0.3rem solid #a997a0"
                           :padding-left "0.3rem"
                           :inherit comment))
(defstyle comment-node-3 `(((:append "::before")
                            :content ""
                            :display "list-item"
                            :position "absolute")
                           :font-size "1.2em"
                           :inherit comment))
(defstyle comment-node-4 `(((:append "::before")
                            :content ""
                            :display "list-item"
                            :position "absolute")
                           :font-size "1.1em"
                           :inherit comment))

(defstyle compiler-note
    `(:border "solid 1px rgba(169,151,160,1.0)"))
(defstyle compiler-style-warning
    `(:border "dashed 1px rgba(240,0,120,1.0)"))
(defstyle compiler-warning
    `(:border "solid 1px rgba(240,0,120,1.0)"))
(defstyle compiler-error
    `(:border "double 1px rgba(240,0,120,1.0)"))

(defsheet lisp-mode
    `((".symbol" :inherit symbol-node)
      (".symbol:empty" :inherit empty-symbol-node)
      (".string" :inherit string-node)
      (".object" :inherit object-node)
      (".symbol[symbol-type=\"ghost\"]" :margin-right "0!important")
      (".symbol[symbol-type=\"macro\"][operator]" :inherit macro)
      (".symbol[symbol-type=\"keyword\"]" :inherit keyword)
      (".symbol[symbol-type=\"special-operator\"][operator]" :inherit special-operator)
      (".list" :inherit list-node)
      (".comment" :inherit comment-node)
      (".comment[comment-level=\"1\"]" :inherit comment-node-1)
      (".comment[comment-level=\"2\"]" :inherit comment-node-2)
      (".comment[comment-level=\"3\"]" :inherit comment-node-3)
      (".comment[comment-level=\"4\"]" :inherit comment-node-4)
      ("[compiler-note-severity=\"note\"]"
       :inherit compiler-note)
      ("[compiler-note-severity=\"style-warning\"]"
       :inherit compiler-style-warning)
      ("[compiler-note-severity=\"warning\"]"
       :inherit compiler-warning)
      ("[compiler-note-severity=\"error\"]"
       :inherit compiler-error)))

(defsheet echo-area-autodoc
    `((".focus-arg" :inherit keyword)
      (".docstring" :inherit comment)))

;;; Mode hooks

(pushnew 'autodoc-mode (hooks 'lisp-mode))
