#lang racket/base
;; Lower a cli-spec command (https://github.com/riz0id/cli-syntax) into the
;; parser's internal interface model (spec.rkt).
;;
;; Interfaces are authored in the cli-spec language -- cmd, subcommand,
;; flag, arg, enum -- and lowered here into command-interface values that
;; parse.rkt and invocation.rkt consume. The
;; lowering accepts the subset of cli-spec this library gives semantics to
;; and raises on anything outside it, so a spec that lowers is a spec whose
;; every construct the transformers honor:
;;
;;   cmd/subcommand        -> command-interface / subcommand-spec (nesting
;;                            preserved; subcommand aliases preserved)
;;   switch param          -> flag-spec
;;   valued param          -> option-spec ('string or enum types only;
;;                            #:repeat 'list -> repeatable?; #:arity '? ->
;;                            optional-value? + attached-only?, since a
;;                            '?-arity value never consumes the next word)
;;   positional            -> operand-spec (arity 1/'?/'* -> 'one/'optional/
;;                            'many)
;;
;; Everything else -- rest clauses, constraint groups, defaults, #:env,
;; #:negatable?, #:required?, #:repeat 'count, counted or ranged arities,
;; 'posix style, default subcommands, root aliases (a command's head
;; uniquely identifies it; there are no multi-head commands) -- is
;; rejected at lowering time. #:doc, #:metavar, #:hidden, #:deprecated,
;; and #:global? are documentation or help-level metadata with no bearing
;; on parsing here and are dropped; enclosing-scope flags are always
;; visible inside subcommands, so #:global? is implied.
(require (prefix-in cli: cli-spec)
         "spec.rkt")

(provide command->interface)

(define (lower-error path fmt . args)
  (apply error 'command->interface
         (string-append "~a: " fmt)
         (reverse path) args))

(define (alias-strings aliases)
  (map symbol->string aliases))

(define (lower-type path who t)
  ;; -> (values 'plain #f) for strings | (values 'enum values)
  (define tag (cli:cli-type-parse t))
  (cond
    [(eq? tag 'string) (values 'plain #f)]
    [(eq? tag 'enum) (values 'enum (cli:cli-type-base t))]
    [else (lower-error path "~a: only 'string and enum types are supported" who)]))

(define (lower-param path p)
  (define who (format "flag ~a" (cli:param-name p)))
  (unless (eq? (cli:param-global-position p) 'anywhere)
    (lower-error path "~a: #:global-position is not supported" who))
  (when (cli:param-env p)
    (lower-error path "~a: #:env is not supported" who))
  (when (cli:param-negatable? p)
    (lower-error path "~a: #:negatable? is not supported" who))
  (when (cli:param-required? p)
    (lower-error path "~a: #:required? is not supported" who))
  (define aliases (alias-strings (cli:param-aliases p)))
  (when (null? aliases)
    (lower-error path "~a: an explicit #:aliases list is required" who))
  (case (cli:param-kind p)
    [(switch)
     ;; cli-spec gives every plain switch the implicit default #f.
     (unless (eq? #f (cli:param-default p))
       (lower-error path "~a: a switch cannot take #:default" who))
     (unless (eq? (cli:param-repeat p) 'last)
       (lower-error path "~a: #:repeat '~a is not supported on a switch"
                    who (cli:param-repeat p)))
     (make-flag (cli:param-name p) aliases)]
    [(valued)
     (when (cli:param-has-default? p)
       (lower-error path "~a: #:default is not supported" who))
     (define-values (kind values) (lower-type path who (cli:param-type p)))
     (define optional-value? (eq? (cli:param-arity p) '?))
     (make-option (cli:param-name p) aliases
                  #:repeatable? (eq? (cli:param-repeat p) 'list)
                  ;; A '?-arity value never consumes the next word, which
                  ;; is exactly the model's attached-only behavior.
                  #:optional-value? optional-value?
                  #:attached-only? optional-value?
                  #:values (and (eq? kind 'enum) values))]))

(define (lower-positional path a)
  (define who (format "arg ~a" (cli:positional-name a)))
  (define-values (kind _values)
    (lower-type path who (cli:positional-type a)))
  (unless (eq? kind 'plain)
    (lower-error path "~a: only 'string positionals are supported" who))
  (define arity
    (case (cli:positional-arity a)
      [(1) 'one]
      [(?) 'optional]
      [(*) 'many]
      [else (lower-error path "~a: arity ~s is not supported"
                         who (cli:positional-arity a))]))
  (make-operand (cli:positional-name a) arity))

(define (lower-node c path root?)
  (define here (cons (cli:command-name c) path))
  (when (and root? (pair? (cli:command-aliases c)))
    (lower-error here
                 "root aliases are not supported: a command's head uniquely identifies it"))
  (unless (eq? (cli:command-style c) 'gnu)
    (lower-error here "#:style '~a is not supported" (cli:command-style c)))
  (when (cli:command-rest c)
    (lower-error here "rest clauses are not supported"))
  (when (pair? (cli:command-groups c))
    (lower-error here "constraint groups are not supported"))
  (when (cli:command-default-subcommand c)
    (lower-error here "default subcommands are not supported"))
  (define-values (flags options)
    (for/fold ([flags '()] [options '()]
               #:result (values (reverse flags) (reverse options)))
              ([p (in-list (cli:command-params c))])
      (define lowered (lower-param here p))
      (if (flag-spec? lowered)
          (values (cons lowered flags) options)
          (values flags (cons lowered options)))))
  (make-command-interface
   #:names (list (symbol->string (cli:command-name c)))
   #:flags flags
   #:options options
   #:operands (for/list ([a (in-list (cli:command-positionals c))])
                (lower-positional here a))
   #:subcommands (for/list ([s (in-list (cli:command-subcommands c))])
                   (make-subcommand
                    (symbol->string (cli:command-name s))
                    (lower-node s here #f)
                    #:aliases (alias-strings (cli:command-aliases s))))))

(define (command->interface c)
  ;; cli-spec command (built with cli:cmd, so already coherence-checked)
  ;; -> command-interface
  (unless (cli:command? c)
    (error 'command->interface "not a cli-spec command: ~e" c))
  (lower-node c '() #t))
