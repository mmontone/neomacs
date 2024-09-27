(in-package #:neomacs)

(define-command-global neomacs-scratch ()
  (let ((buffer (make-buffer :url (quri:uri "neomacs:scratch.lisp"))))
    (set-current-buffer buffer)))

(defun lisp-selectable-p (cont pos)
  (let ((node (node-after pos))
        (parent (node-containing pos)))
    (or (characterp node)
        (and node (not (symbol-node-p node)))
        (and (not node)
             (class-p parent "doc" "string" "list"))
        (funcall cont))))

(defun lisp-focus-move (old new)
  (declare (ignore old))
  (let ((node (node-containing new)))
    (if (class-p node "list" "symbol" "doc")
        (unless (find-submode 'sexp-editing-mode)
          (enable-modes* 'sexp-editing-mode (current-buffer)))
        (when (find-submode 'sexp-editing-mode)
          (disable-modes* 'sexp-editing-mode (current-buffer))))))

(defgeneric print-dom (object &key &allow-other-keys))

(defun compute-operator (node)
  (when (eql (first-child (parent node)) node)
    ""))

(defun compute-symbol (node)
  (ignore-errors
   (swank::parse-symbol (text (first-child node)))))

(defun compute-symbol-type (node)
  (when-let (symbol (compute-symbol node))
    (cond ((or (and (special-operator-p symbol)
                    (not (member symbol '(function))))
               (member symbol '(declare)))
           "special-operator")
          ((macro-function symbol) "macro")
          ((keywordp symbol) "keyword")
          (t ""))))

(defun lisp-node-setup (node)
  (set-attribute-function node "operator" 'compute-operator)

  (add-observer (slot-value node 'parent)
                (lambda (cell)
                  (let ((parent (cell-ref cell)))
                    (when (symbol-node-p parent)
                      (let ((second-symbol (split-node node)))
                        (move-nodes node (pos-right node) second-symbol))))))
  (when (symbol-node-p node)
    (set-attribute-function node "symbol-type" 'compute-symbol-type)
    (add-observer (slot-value node 'next-sibling)
                  (lambda (cell)
                    (let ((next (cell-ref cell)))
                      (when (symbol-node-p next)
                        (join-nodes node next)))))
    (add-observer (slot-value node 'first-child)
                  (lambda (cell)
                    (unless (cell-ref cell)
                      (delete-nodes node (pos-right node)))))))

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

(defun make-new-line-node ()
  (make-instance 'element :tag-name "br"))

(defun list-node-p (node)
  (class-p node "list"))

(defun atom-node-p (node)
  (class-p node "symbol" "string" "object" "comment"))

(defun sexp-node-p (node)
  (class-p node "list" "symbol" "string" "object"))

(defun symbol-node-p (node)
  (and (element-p node)
       (equal (attribute node "class") "symbol")))

(defun new-line-node-p (node)
  (or (and (element-p node)
           (or (equal (attribute node "class")
                      "new-line")
               (equal (tag-name node) "br")))
      (eql node #\Newline)))

(defun atom-node-text (node)
  (ignore-errors (text (first-child node))))

(defmethod print-dom ((cons cons) &key)
  (make-list-node
   (iter (with last-item)
     (for item in cons)
     (unless (or (first-iteration-p)
                 (eql item '%br)
                 (eql last-item '%br))
       (collect (make-instance 'text-node :text " ")))
     (setq last-item item)
     (collect (print-dom item)))))

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

(defmethod print-dom ((obj t) &key)
  (make-atom-node "symbol" (prin1-to-string obj)))

(defun lisp-self-insert (marker string)
  (cond ((equal string " ")
         (if (symbol-node-p (node-containing marker))
             (lisp-split marker)
             (insert-nodes marker string)))
        ((atom-node-p (node-containing marker))
         (insert-nodes marker string))
        ((class-p (node-before marker) "comment")
         (insert-nodes (end-pos (node-before marker)) string))
        (t
         (let ((node (make-atom-node "symbol" string)))
           (insert-nodes marker node)))))

(define-command open-paren (&optional (marker (focus)))
  (let ((node (make-list-node nil)))
    (insert-nodes marker node)
    (setf (pos marker) (end-pos node))))

(define-command wrap-paren (&optional (pos (focus)))
  (let ((node (make-list-node nil)))
    (setq pos (or (pos-up-ensure pos #'sexp-node-p)
                  (error 'top-of-subtree)))
    (insert-nodes pos node)
    (move-nodes pos (pos-right pos) (end-pos node))))

(define-command open-string (&optional (marker (focus)))
  (let ((node (make-atom-node "string" "")))
    (insert-nodes marker node)
    (setf (pos marker) (end-pos node))))

(define-command open-comment (&optional (marker (focus)))
  (labels ((cycle-level (n)
             (lret ((n (1+ (mod n 4))))
               (echo "Comment Level -> ~a" n))))
    (if-let (node (comment-around marker))
      (setf (attribute node "comment-level")
            (prin1-to-string
             (cycle-level
              (parse-number:parse-number
               (attribute node "comment-level")))))
      (let ((node (make-atom-node "comment" "")))
        (setf (attribute node "comment-level") "1")
        (insert-nodes marker node)
        (setf (pos marker) (end-pos node))))))

(define-command wrap-comment (&optional (pos (focus)))
  (let ((node (make-atom-node "comment" "")))
    (setq pos (or (pos-up-ensure pos #'sexp-node-p)
                  (error 'top-of-subtree)))
    (insert-nodes pos node)
    (move-nodes pos (pos-right pos) (end-pos node))))

(define-command lisp-raise (&optional (pos (focus)))
  (setq pos (or (pos-up-ensure pos #'sexp-node-p)
                (error 'top-of-subtree)))
  (raise-node pos))

(define-command lisp-splice (&optional (pos (focus)))
  (setq pos (or (pos-up-until pos #'list-node-p)
                (error 'top-of-subtree)))
  (splice-node pos))

(define-command lisp-split (&optional (marker (focus)))
  (insert-nodes (setf (pos marker) (split-node marker)) " "))

(define-mode lisp-mode ()
  "Lisp mode."
  ((keyscheme-map
    (keymaps:define-keyscheme-map "lisp" ()
      keyscheme:default
      (list "tab" 'show-completions)
      keyscheme:emacs
      '("M-(" wrap-paren
        "M-;" wrap-comment
        "M-r" lisp-raise
        "M-s" lisp-splice

        "C-M-x" eval-defun
        ;; "C-c C-c" compile-defun
        "tab" show-completions
        "C-x C-e" eval-last-expression
        "C-c C-p" eval-print-last-expression)))))

(define-mode sexp-editing-mode ()
  "Editing S-exp."
  ((keyscheme-map
    (keymaps:define-keyscheme-map "sexp" ()
      keyscheme:default
      (list "(" 'open-paren
            "\"" 'open-string
            ";" 'open-comment)))
   (rememberable-p nil))
  (:toggler-command-p nil))

(defmethod enable ((mode lisp-mode) &key)
  (with-current-buffer (buffer mode)
    (let ((neomacs (current-neomacs)))
      (alex:unionf (word-boundary-list neomacs) '(#\  #\-))
      (pushnew 'lisp-mode (styles neomacs))
      (hooks:add-hook (selectable-p-hook neomacs) 'lisp-selectable-p)
      (hooks:add-hook (self-insert-hook neomacs) 'lisp-self-insert)
      (hooks:add-hook (focus-move-hook neomacs) 'lisp-focus-move)
      (hooks:add-hook (node-setup-hook neomacs) 'lisp-node-setup)
      (hooks:add-hook (completion-hook neomacs) 'lisp-completion)
      (do-elements #'lisp-node-setup (restriction neomacs)))))

(defmethod disable ((mode lisp-mode) &key)
  (let ((neomacs (current-neomacs)))
    (alex:deletef (styles neomacs) 'lisp-mode)
    (hooks:remove-hook (selectable-p-hook neomacs) 'lisp-selectable-p)
    (hooks:remove-hook (self-insert-hook neomacs) 'lisp-self-insert)
    (hooks:remove-hook (focus-move-hook neomacs) 'lisp-focus-move)
    (hooks:remove-hook (node-setup-hook neomacs) 'lisp-node-setup)
    (hooks:remove-hook (completion-hook neomacs) 'lisp-completion)))

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
           (t (decf i) (return))))
        (t (return))))
    (values wrappers (subseq string i))))

(defun node-to-sexp (node)
  "Parse DOM NODE as a Lisp object.
It also takes into account any prefix preceding NODE."
  (labels ((ghost-symbol-p (node)
             (when (symbol-node-p node)
               (bind (((:values wrappers rest)
                       (parse-prefix (atom-node-text node))))
                 (when (zerop (length rest))
                   wrappers))))
           (apply-wrappers (wrappers node)
             (iter (for w in wrappers)
               (setq node (funcall w node)))
             node)
           (process (node)
             (let ((sexp
                     (cond ((list-node-p node)
                            (mapcar #'process
                                    (remove-if (alex:disjoin
                                                #'text-node-p
                                                #'ghost-symbol-p
                                                #'new-line-node-p)
                                               (child-nodes node))))
                           ((equal "string" (attribute node "class"))
                            (atom-node-text node))
                           ((symbol-node-p node)
                            (bind (((:values wrappers rest)
                                    (parse-prefix (atom-node-text node))))
                              (apply-wrappers wrappers (read-from-string rest))))
                           ((new-line-node-p node) nil)
                           (t (error "Unrecognized DOM node: ~a" node)))))
               (if-let (wrappers (ghost-symbol-p (previous-sibling node)))
                 (apply-wrappers wrappers sexp)
                 sexp))))
    (process node)))

(defun current-package (&optional (marker-or-pos (focus)))
  "Return the package in the context of MARKER-OR-POS.
This is determined by searching for a `in-package' top-level form
before MARKER-OR-POS."
  (with-marker (marker marker-or-pos)
    (or (find-package
         (handler-case
             (iter (beginning-of-defun marker)
               (for node = (node-after marker))
               (when (and (list-node-p node)
                          (eql 'in-package (compute-symbol (first-child node))))
                 (let ((p (npos-right-until (first-child node) #'sexp-node-p)))
                   (when-let (s (compute-symbol p))
                     (return (symbol-name s))))))
           (top-of-subtree ())))
        (find-package "NEOMACS"))))

(define-command eval-defun (&optional (marker-or-pos (focus)))
  (with-marker (marker marker-or-pos)
    (beginning-of-defun marker)
    (let* ((*package* (current-package marker))
           (result (eval (node-to-sexp (pos marker)))))
      (echo "=> ~a" result))))

(defun last-expression (pos)
  (iter
    (for node = (node-before pos))
    (until (sexp-node-p node))
    (setq pos (npos-prev pos)))
  (node-before pos))

(define-command eval-last-expression (&optional (marker (focus)))
  (let* ((*package* (current-package marker))
         (result (eval (node-to-sexp (last-expression (pos marker))))))
    (echo "=> ~a" result)))

(define-command eval-print-last-expression (&optional (marker (focus)))
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

(defun comment-around (pos)
  (when-let (node (atom-around pos))
    (when (equal "comment" (attribute node "class"))
      node)))

(defun lisp-completion (pos)
  (when-let (node (symbol-around pos))
    (let* ((package (current-package pos))
           (swank::*buffer-package* package)
           (completions (car (swank:fuzzy-completions
                              (atom-node-text node)
                              package))))
      (list (cons (pos-down node) nil) completions))))

;;; Style

(defstyle sexp-node `(:display "inline-block"
                      :vertical-align "top"
                      :position "relative"
                      :white-space "pre-wrap"))
(defstyle list-node
    `(((:append "::before")
       :content "("
       :margin-left "-0.4em")
      ((:append "::after")
       :content ")"
       :vertical-align "bottom")
      ((:append ".focus-tail::after")
       :content ")"
       :inherit selection)
      ((:append ".focus::before")
       :inherit selection)
      :inherit sexp-node
      :padding-left "0.4em"))

(defstyle string-node `(((:append "::before") :content "\"")
                        ((:append "::after") :content "\"")
                        ((:append ".focus::before")
                         :inherit selection)
                        ((:append ".focus-tail::after")
                         :content "\""
                         :inherit selection)
                        :inherit (sexp-node string)))
(defstyle symbol-node `(:inherit sexp-node))
(defstyle comment-node `(((:append "::after") :content "⁣")
                         :display "inline-block"
                         :white-space "pre-wrap"))
(defstyle comment-node-1 `(:position "sticky"
                           :left "20em"
                           :border-left "0.3rem solid #ccc"
                           :padding-left "0.3rem"
                           :inherit comment))
(defstyle comment-node-2 `(:border-left "0.3rem solid #ccc"
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

(defstyle lisp-mode
    `((".symbol" :inherit symbol-node)
      (".string" :inherit string-node)
      (".object" :inherit symbol-node)
      (".symbol[symbol-type=\"macro\"][operator]" :inherit macro)
      (".symbol[symbol-type=\"keyword\"]" :inherit keyword)
      (".symbol[symbol-type=\"special-operator\"][operator]" :inherit special-operator)
      (".list" :inherit list-node)
      (".comment" :inherit comment-node)
      (".comment[comment-level=\"1\"]" :inherit comment-node-1)
      (".comment[comment-level=\"2\"]" :inherit comment-node-2)
      (".comment[comment-level=\"3\"]" :inherit comment-node-3)
      (".comment[comment-level=\"4\"]" :inherit comment-node-4)))

;;; Default hooks
(add-mode-hook 'lisp-mode 'undo-mode)
(add-mode-hook 'lisp-mode 'auto-completion-mode)
