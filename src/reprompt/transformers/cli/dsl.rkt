#lang racket/base
;; Surface syntax for command interfaces.
;;
;;   (define-command-interface grep-cli
;;     #:names ("grep" "egrep" "fgrep")
;;     #:unknown 'reject
;;     (flag recursive "-r" "-R" "--recursive")
;;     (option pattern "-e" "--regexp" #:repeatable)
;;     (option color "--color" #:optional-value)
;;     (operand pattern-operand #:arity one
;;              #:unless (lambda (inv) (invocation-has-flag? inv 'pattern)))
;;     (operand files #:arity many)
;;     (subcommand "restart" (operand units #:arity many)))
;;
;; A thin macro over the runtime constructors in spec.rkt -- validation logic
;; lives there once; the macro re-checks everything statically visible
;; (duplicate ids, alias collisions, malformed aliases, arity spellings, more
;; than one 'many operand, duplicate subcommand names) so mistakes surface as
;; syntax errors pointing at the offending clause. Operand clauses keep their
;; declared order; that order is the assignment order. An operand's #:when /
;; #:unless takes a predicate over the invocation-so-far, deciding whether
;; the slot is active.
(require (for-syntax racket/base
                     syntax/parse)
         "spec.rkt")

(provide define-command-interface)

(begin-for-syntax
  (define (alias-kind a)
    (cond
      [(regexp-match? #px"^-[^-=\\s]$" a) 'short]
      [(regexp-match? #px"^--[^=\\s]+$" a) 'long]
      [(and (positive? (string-length a))
            (not (regexp-match? #px"[=\\s]" a)))
       'literal]
      [else #f]))

  (define-syntax-class flag-clause
    #:datum-literals (flag)
    (pattern (flag id:id alias:str ...+)))

  (define-syntax-class option-clause
    #:datum-literals (option)
    (pattern (option id:id alias:str ...+
                     (~alt (~optional (~and #:repeatable repeatable))
                           (~optional (~and #:optional-value optional-value))
                           (~optional (~and #:attached-only attached-only))
                           (~optional (~seq #:values (val:str ...+))))
                     ...)))

  (define-syntax-class operand-clause
    #:datum-literals (operand)
    (pattern (operand id:id #:arity arity:id
                      (~optional (~or* (~seq #:when when-guard:expr)
                                       (~seq #:unless unless-guard:expr))))))

  ;; One validation scope: an interface level (top level, or one subcommand).
  (struct scope (ids shorts longs literals many? subnames) #:mutable)
  (define (new-scope) (scope '() '() '() '() #f '()))

  (define (check-id! sc stx)
    (define sym (syntax-e stx))
    (when (memq sym (scope-ids sc))
      (raise-syntax-error 'define-command-interface "duplicate id" stx))
    (set-scope-ids! sc (cons sym (scope-ids sc))))

  (define (check-alias! sc stx)
    (define a (syntax-e stx))
    (define kind (alias-kind a))
    (unless kind
      (raise-syntax-error 'define-command-interface "malformed alias" stx))
    (define-values (get set!!)
      (case kind
        [(short) (values scope-shorts set-scope-shorts!)]
        [(long) (values scope-longs set-scope-longs!)]
        [(literal) (values scope-literals set-scope-literals!)]))
    (when (member a (get sc))
      (raise-syntax-error 'define-command-interface "duplicate alias" stx))
    (set!! sc (cons a (get sc))))

  (define (check-arity! sc arity-stx)
    (define arity (syntax-e arity-stx))
    (unless (memq arity '(one optional many))
      (raise-syntax-error 'define-command-interface
                          "arity must be one, optional, or many" arity-stx))
    (when (eq? arity 'many)
      (when (scope-many? sc)
        (raise-syntax-error 'define-command-interface
                            "a second operand with arity many" arity-stx))
      (set-scope-many?! sc #t)))

  (define (check-subname! sc stx)
    (define n (syntax-e stx))
    (when (member n (scope-subnames sc))
      (raise-syntax-error 'define-command-interface "duplicate subcommand" stx))
    (set-scope-subnames! sc (cons n (scope-subnames sc))))

  (define (parse-clauses clauses allow-subcommands?)
    ;; -> (values flag-exprs option-exprs operand-exprs subcommand-exprs)
    (define sc (new-scope))
    (define flags '())
    (define options '())
    (define operands '())
    (define subs '())
    (for ([c (in-list clauses)])
      (syntax-parse c
        #:datum-literals (subcommand)
        [f:flag-clause
         (check-id! sc #'f.id)
         (for ([a (in-list (syntax->list #'(f.alias ...)))]) (check-alias! sc a))
         (set! flags (cons #'(make-flag 'f.id (list f.alias ...)) flags))]
        [o:option-clause
         (check-id! sc #'o.id)
         (for ([a (in-list (syntax->list #'(o.alias ...)))]) (check-alias! sc a))
         (define rep (if (attribute o.repeatable) #'#t #'#f))
         (define opt (if (attribute o.optional-value) #'#t #'#f))
         (define att (if (attribute o.attached-only) #'#t #'#f))
         (set! options
               (cons #`(make-option 'o.id (list o.alias ...)
                                    #:repeatable? #,rep
                                    #:optional-value? #,opt
                                    #:attached-only? #,att
                                    #:values (~? (list o.val ...) #f))
                     options))]
        [op:operand-clause
         (check-id! sc #'op.id)
         (check-arity! sc #'op.arity)
         (set! operands
               (cons #'(make-operand 'op.id 'op.arity
                                     (~? op.when-guard
                                         (~? (let ([p op.unless-guard])
                                               (lambda (inv) (not (p inv))))
                                             #f)))
                     operands))]
        [(subcommand name:str inner ...)
         (unless allow-subcommands?
           (raise-syntax-error 'define-command-interface
                               "subcommands do not nest" c))
         (check-subname! sc #'name)
         (define-values (f o op sub)
           (parse-clauses (syntax->list #'(inner ...)) #f))
         (set! subs
               (cons #`(make-subcommand name
                                        (make-command-interface
                                         #:names (list name)
                                         #:flags (list #,@f)
                                         #:options (list #,@o)
                                         #:operands (list #,@op)))
                     subs))]
        [_ (raise-syntax-error 'define-command-interface "bad clause" c)]))
    (when (and (pair? subs) (pair? operands))
      (raise-syntax-error 'define-command-interface
                          "an interface with subcommands cannot take operands"
                          (car clauses)))
    (values (reverse flags) (reverse options) (reverse operands) (reverse subs))))

(define-syntax (define-command-interface stx)
  (syntax-parse stx
    [(_ name:id #:names (cmd:str ...+)
        (~optional (~seq #:unknown policy:expr))
        clause ...)
     (define-values (flags options operands subs)
       (parse-clauses (syntax->list #'(clause ...)) #t))
     #`(define name
         (make-command-interface
          #:names (list cmd ...)
          #:flags (list #,@flags)
          #:options (list #,@options)
          #:operands (list #,@operands)
          #:subcommands (list #,@subs)
          #:unknown (~? policy 'reject)))]))
