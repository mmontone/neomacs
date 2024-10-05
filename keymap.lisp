;; Adapted from lem

(in-package #:neomacs)

(defstruct (key (:constructor %make-key))
  (ctrl nil :type boolean)
  (meta nil :type boolean)
  (super nil :type boolean)
  (hypher nil :type boolean)
  (shift nil :type boolean)
  (sym (alex:required-argument) :type string))

(defvar *key-constructor-cache* (make-hash-table :test 'equal))

(defun make-key (&rest args &key ctrl meta super hypher shift sym)
  (let ((hashkey (list ctrl meta super hypher shift sym)))
    (or (gethash hashkey *key-constructor-cache*)
        (setf (gethash hashkey *key-constructor-cache*)
              (apply #'%make-key args)))))

(defvar *keymaps* nil)

(deftype key-sequence ()
  '(trivial-types:proper-list key))

(defstruct (keymap (:constructor %make-keymap))
  undef-hook
  parent
  (table (make-hash-table :test 'eq))
  (function-table (make-hash-table :test 'eq))
  name)

(defmethod print-object ((object keymap) stream)
  (print-unreadable-object (object stream :identity t :type t)
    (when (keymap-name object)
      (princ (keymap-name object) stream))))

(defun make-keymap (&key undef-hook parent name)
  (let ((keymap (%make-keymap
                 :undef-hook undef-hook
                 :parent parent
                 :name name)))
    (push keymap *keymaps*)
    keymap))

(defun prefix-command-p (command)
  (hash-table-p command))

;; TODO: handle undefine key sequence (with prefix key),
;; i.e. cleanup empty prefix hash-table

(defun define-key (keymap keyspec command)
  "Bind COMMAND to a KEYSPEC in a KEYMAP.

If KEYSPEC argument is a `string', valid prefixes are:
H (Hyper), S (Super), M (Meta), C (Ctrl), Shift

Example: (define-key *global-keymap* \"C-'\" 'list-modes)"
  (check-type keyspec (or symbol string))
  (check-type command (or symbol function keymap))
  (typecase keyspec
    (symbol
     (setf (gethash keyspec (keymap-function-table keymap))
           command))
    (string
     (let ((keys (parse-keyspec keyspec)))
       (define-key-internal keymap keys command))))
  (values))

(defmacro define-keys (keymap &body bindings)
  `(progn
     ,@ (iter (for (k v) on bindings by #'cddr)
          (collect `(define-key ,keymap ,k ,v)))))

(defmacro define-keymap (name parent &body bindings)
  `(lret ((m (make-keymap :name ,name :parent ,parent)))
     (define-keys m ,@bindings)))

(defun define-key-internal (keymap keys symbol)
  (loop :with table := (keymap-table keymap)
        :for rest :on (uiop:ensure-list keys)
        :for k := (car rest)
        :do (cond ((null (cdr rest))
                   (setf (gethash k table) symbol))
                  (t
                   (let ((next (gethash k table)))
                     (if (and next (prefix-command-p next))
                         (setf table next)
                         (let ((new-table (make-hash-table :test 'eq)))
                           (setf (gethash k table) new-table)
                           (setf table new-table))))))))

(defun string-to-camel-case (str)
  (with-output-to-string (s)
    (iter (with upcase = t)
      (for c in-string str)
      (if (eql c #\-)
          (setq upcase t)
          (if upcase
              (progn
                (write-char (char-upcase c) s)
                (setq upcase nil))
              (write-char c s))))))

(defun string-from-camel-case (str)
  (with-output-to-string (s)
    (iter (for c in-string str)
      (if (upper-case-p c)
          (progn
            (unless (first-iteration-p)
              (write-char #\- s))
            (write-char (char-downcase c) s))
          (write-char c s)))))

(defvar *char-to-event* (make-hash-table) "Map character to (event-code . shift-p).")
(defvar *event-to-char* (make-hash-table :test 'equal) "Map (event-code . shift-p) to character.")
;; Add character event translations
(labels ((add (char sym shift-p)
           (setq sym (string-to-camel-case sym))
           (setf (gethash char *char-to-event*) (cons sym shift-p)
                 (gethash (cons sym shift-p) *event-to-char*) char)))
  (iter (for i from (char-code #\a) to (char-code #\z))
    (for c = (code-char i))
    (add c (sera:concat "key-" (string c)) nil))
  (iter (for i from (char-code #\A) to (char-code #\Z))
    (for c = (code-char i))
    (add c (sera:concat "key-" (string c)) t))
  (iter (for i from (char-code #\0) to (char-code #\9))
    (for c = (code-char i))
    (add c (sera:concat "digit-" (string c)) nil))
  (iter (for c in '(#\) #\! #\@ #\# #\$ #\% #\^ #\& #\* #\())
    (for i from 0)
    (add c (format nil "digit-~A" i) t))
  (add #\; "semicolon" nil)
  (add #\= "equal" nil)
  (add #\, "comma" nil)
  (add #\- "minus" nil)
  (add #\. "period" nil)
  (add #\/ "slash" nil)
  (add #\` "backquote" nil)
  (add #\\ "backslash" nil)
  (add #\[ "bracket-left" nil)
  (add #\] "bracket-right" nil)
  (add #\' "quote" nil)
  (add #\: "semicolon" t)
  (add #\+ "equal" t)
  (add #\< "comma" t)
  (add #\_ "minus" t)
  (add #\> "period" t)
  (add #\? "slash" t)
  (add #\~ "backquote" t)
  (add #\| "backslash" t)
  (add #\{ "bracket-left" t)
  (add #\} "bracket-right" t)
  (add #\" "quote" t))

(defun parse-keyspec (string)
  (labels ((fail ()
             (error "parse error: ~A" string))
           (parse (str)
             (iter (with ctrl) (with meta) (with super) (with hypher) (with shift)
               (cond
                 ((ppcre:scan "^[cmshCMSH]-" str)
                  (ecase (char str 0)
                    ((#\c #\C) (setf ctrl t))
                    ((#\m #\M) (setf meta t))
                    ((#\s) (setf super t))
                    ((#\S) (setf shift t))
                    ((#\h #\H) (setf hypher t)))
                  (setf str (subseq str 2)))
                 ((string= str "")
                  (fail))
                 (t
                  (if (= (length str) 1)
                      (if-let (translation (gethash (only-elt str) *char-to-event*))
                        (setf str (car translation)
                              shift (cdr translation))
                        (fail))
                      (setq str (string-to-camel-case str)))
                  (return (make-key :ctrl ctrl
                                    :meta meta
                                    :super super
                                    :hypher hypher
                                    :shift shift
                                    :sym str)))))))
    (mapcar #'parse (uiop:split-string string :separator " "))))

(defun key-description (key &optional stream)
  (match key
    ((key ctrl meta super hypher shift sym)
     (if-let (translation (gethash (cons sym shift) *event-to-char*))
       (setf shift nil sym (string translation))
       (setq sym (string-from-camel-case sym)))
     (format stream "~:[~;C-~]~:[~;M-~]~:[~;s-~]~:[~;H-~]~:[~;S-~]~A"
             ctrl meta super hypher shift sym))))

(defun keys-description (keys &optional stream)
  (sera:mapconcat #'key-description keys " " :stream stream))

(defun traverse-keymap (keymap fun)
  (labels ((f (table prefix)
             (maphash (lambda (k v)
                        (cond ((prefix-command-p v)
                               (f v (cons k prefix)))
                              ((keymap-p v)
                               (f (keymap-table v) (cons k prefix)))
                              (t (funcall fun (reverse (cons k prefix)) v))))
                      table)))
    (f (keymap-table keymap) nil)))

(defgeneric keymap-find-keybind (keymap key cmd)
  (:method ((keymap t) key cmd)
    (let ((table (keymap-table keymap)))
      (labels ((f (k)
                 (let ((cmd (gethash k table)))
                   (cond ((prefix-command-p cmd)
                          (setf table cmd))
                         ((keymap-p cmd)
                          (setf table (keymap-table cmd)))
                         (t cmd)))))
        (let ((parent (keymap-parent keymap)))
          (when parent
            (setf cmd (keymap-find-keybind parent key cmd))))
        (or (etypecase key
              (key
               (f key))
              (list
               (let (cmd)
                 (dolist (k key)
                   (unless (setf cmd (f k))
                     (return)))
                 cmd)))
            (gethash cmd (keymap-function-table keymap))
            (keymap-undef-hook keymap)
            cmd)))))

(defun all-keymaps (buffer)
  (delete-duplicates
   (append (iter (for mode in (modes buffer))
             (when-let (keymap (keymap mode))
               (collect keymap)))
           (list *global-keymap*))))

(defun lookup-keybind (key &optional (keymaps (all-keymaps)))
  (let (cmd)
    (loop :for keymap :in (reverse keymaps)
          :do (setf cmd (keymap-find-keybind keymap key cmd)))
    cmd))

(defun find-keybind (key)
  (let ((cmd (lookup-keybind key)))
    (when (symbolp cmd)
      cmd)))

(defun collect-command-keybindings (command keymap)
  (let ((bindings '()))
    (traverse-keymap keymap
                     (lambda (kseq cmd)
                       (when (eq cmd command)
                         (push kseq bindings))))
    (nreverse bindings)))

(defvar *global-keymap* (make-keymap :name "global"))

;;; Default keybinds

(define-keys *global-keymap*
  "arrow-right" 'forward-node
  "arrow-left" 'backward-node
  "M-arrow-right" 'forward-word
  "M-arrow-left" 'backward-word
  "arrow-down" 'next-line
  "arrow-up" 'previous-line
  "end" 'end-of-line
  "home" 'beginning-of-line)

(define-keys *global-keymap*
  "C-f" 'forward-node
  "C-b" 'backward-node
  "M-f" 'forward-word
  "M-b" 'backward-word
  "C-M-f" 'forward-element
  "C-M-b" 'backward-element
  "M-<" 'beginning-of-buffer
  "M->" 'end-of-buffer
  "C-a" 'beginning-of-line
  "C-e" 'end-of-line
  "M-a" 'beginning-of-defun
  "M-e" 'end-of-defun
  "C-n" 'next-line
  "C-p" 'previous-line
  "C-v" 'scroll-down-command
  "M-v" 'scroll-up-command)