#lang racket/base
;; Surface syntax for command mappings.
;;
;;   (define-command-mapping grep->rg
;;     #:from grep-cli
;;     #:to   rg-cli
;;     #:heads (("grep" . "rg"))
;;     #:domain dialect-compatible?          ; optional predicate over the
;;                                           ;   raw invocation

;;     (identify (head "fgrep") (head "grep" (flag fixed-strings)))
;;     (identify (option colour) (option color))
;;     (identify (option color #f) (option color "auto"))
;;     (identify (flag recursive) ε)
;;     (same line-number ignore-case)
;;     (rename include glob)
;;     (value size size #:forward g #:witness g-inverse)
;;     (split context (after-context before-context))
;;     (add (flag hidden) #:when some-predicate)
;;     (operands (pattern-operand . pattern-operand) (files . paths))
;;     #:unmapped reject)
;;
;; A thin macro over the runtime constructors in mapping.rkt -- validation
;; lives there once; the macro checks the statically visible shape (clause
;; forms, a source id claimed at most once, a single operands clause) so
;; mistakes surface as syntax errors pointing at the offending clause.
;; `identify` left/right sides are patterns: (head "name"), (flag id),
;; (option id) for any value, (option id "v") / (option id #f) for a
;; specific or omitted value, and ε on the right erases the argument.

(require (for-syntax racket/base
                     syntax/parse)
         "mapping.rkt")

(provide define-command-mapping)

(begin-for-syntax
  (define-syntax-class identify-clause
    #:datum-literals (identify head flag option ε)
    #:attributes (expr)
    (pattern (identify (head hf:str) (head ht:str add ...))
      #:with (add-e ...)
      (for/list ([a (in-list (syntax->list #'(add ...)))])
        (syntax-parse a
          #:datum-literals (flag option)
          [(flag id:id) #'(list 'flag 'id)]
          [(option id:id v:str) #'(list 'option 'id v)]
          [_ (raise-syntax-error 'define-command-mapping
                                 "bad added argument in identify" a)]))
      #:with expr #'(identify-head hf ht (list add-e ...)))
    (pattern (identify (flag fid:id) ε)
      #:with expr #'(identify-arg 'flag 'fid 'any #f))
    (pattern (identify (flag fid:id) (flag tid:id))
      #:with expr #'(identify-arg 'flag 'fid 'any (list 'tid 'copy)))
    (pattern (identify (option fid:id) ε)
      #:with expr #'(identify-arg 'option 'fid 'any #f))
    (pattern (identify (option fid:id) (option tid:id))
      #:with expr #'(identify-arg 'option 'fid 'any (list 'tid 'copy)))
    (pattern (identify (option fid:id fv:str) ε)
      #:with expr #'(identify-arg 'option 'fid fv #f))
    (pattern (identify (option fid:id #f) ε)
      #:with expr #'(identify-arg 'option 'fid #f #f))
    (pattern (identify (option fid:id fv:str) (option tid:id tv:str))
      #:with expr #'(identify-arg 'option 'fid fv (list 'tid tv)))
    (pattern (identify (option fid:id #f) (option tid:id tv:str))
      #:with expr #'(identify-arg 'option 'fid #f (list 'tid tv))))

  (define-syntax-class rule-clause
    #:datum-literals (same rename value split)
    #:attributes ((rule 1) (fid 1))
    (pattern (same id:id ...+)
      #:with (rule ...) #'((map-rule 'id (list (map-target 'id #f #f)) #f) ...)
      #:with (fid ...) #'(id ...))
    (pattern (rename from:id to:id)
      #:with (rule ...) #'((map-rule 'from (list (map-target 'to #f #f)) #f))
      #:with (fid ...) #'(from))
    (pattern (value from:id to:id #:forward g:expr #:witness w:expr
                    (~optional (~or* (~seq #:when when-g:expr)
                                     (~seq #:unless unless-g:expr))))
      #:with (rule ...)
      #'((map-rule 'from (list (map-target 'to g w))
                   (~? when-g
                       (~? (let ([p unless-g]) (lambda (inv) (not (p inv))))
                           #f))))
      #:with (fid ...) #'(from))
    (pattern (split from:id (to:id ...+))
      #:with (rule ...) #'((map-rule 'from (list (map-target 'to #f #f) ...) #f))
      #:with (fid ...) #'(from)))

  (define-syntax-class add-clause
    #:datum-literals (add flag option)
    #:attributes (expr)
    (pattern (add (flag id:id) (~optional (~seq #:when g:expr)))
      #:with expr #'(add-rule 'flag 'id #f (~? g #f)))
    (pattern (add (option id:id v:str) (~optional (~seq #:when g:expr)))
      #:with expr #'(add-rule 'option 'id v (~? g #f))))

  (define-syntax-class operands-clause
    #:datum-literals (operands)
    #:attributes (expr)
    (pattern (operands (f:id . t:id) ...)
      #:with expr #'(list (cons 'f 't) ...))))

(define-syntax (define-command-mapping stx)
  (syntax-parse stx
    [(_ name:id #:from from:expr #:to to:expr
        #:heads ((hf:str . ht:str) ...)
        (~optional (~seq #:domain domain:expr))
        body ...)
     (define identifies '())
     (define rules '())
     (define adds '())
     (define ops #f)
     (define seen-ids '())
     (define (parse-clause! c)
       (syntax-parse c
         [ic:identify-clause (set! identifies (cons #'ic.expr identifies))]
         [rc:rule-clause
          (for ([i (in-list (syntax->list #'(rc.fid ...)))])
            (when (memq (syntax-e i) seen-ids)
              (raise-syntax-error 'define-command-mapping
                                  "source id claimed twice" i))
            (set! seen-ids (cons (syntax-e i) seen-ids)))
          (set! rules (append (reverse (syntax->list #'(rc.rule ...))) rules))]
         [ac:add-clause (set! adds (cons #'ac.expr adds))]
         [oc:operands-clause
          (when ops
            (raise-syntax-error 'define-command-mapping
                                "duplicate operands clause" c))
          (set! ops #'oc.expr)]
         [_ (raise-syntax-error 'define-command-mapping "bad clause" c)]))
     (let loop ([items (syntax->list #'(body ...))])
       (cond
         [(null? items) (void)]
         [(eq? '#:unmapped (syntax-e (car items)))
          (unless (and (pair? (cdr items))
                       (eq? 'reject (syntax-e (cadr items))))
            (raise-syntax-error 'define-command-mapping
                                "the only #:unmapped policy is reject"
                                (car items)))
          (loop (cddr items))]
         [else (parse-clause! (car items)) (loop (cdr items))]))
     (unless ops
       (raise-syntax-error 'define-command-mapping "missing operands clause" stx))
     #`(define name
         (make-command-mapping
          #:from from
          #:to to
          #:heads (list (cons hf ht) ...)
          #:identifies (list #,@(reverse identifies))
          #:rules (list #,@(reverse rules))
          #:adds (list #,@(reverse adds))
          #:operands #,ops
          #:domain (~? domain #f)))]))
