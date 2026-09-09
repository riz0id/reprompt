#lang racket/base

;; mcp-spec: a declarative language for MCP interface specifications. An
;; operator is a named MCP method with typed, possibly-optional arguments and
;; a typed return. Argument types are cli-spec types (atom symbols such as
;; 'int and 'path, or compound cli-type values like cli:enum / cli:custom)
;; and value parsing delegates to cli-spec's type-parse, so both languages
;; share one type vocabulary.
;;
;; All structs are prefab so specs serialize with write/read, with cli-spec's
;; caveat inherited verbatim: a cli:custom type stores its parse procedure in
;; the cli-type, so an operator carrying one is a legal value in memory but
;; not write-able.

(require racket/contract
         racket/match
         racket/string
         (prefix-in cli: cli-spec))

(provide define-mcp
         (contract-out
          [operator (->* (symbol?)
                         (#:method string?
                          #:returns (or/c symbol? cli:cli-type?)
                          #:doc (or/c #f string?))
                         #:rest (listof mcp-argument?)
                         mcp-operator?)]
          [argument (->* (symbol?)
                         ((or/c symbol? cli:cli-type?)
                          #:optional? boolean?
                          #:default any/c
                          #:doc (or/c #f string?))
                         mcp-argument?)]
          [parse-operator-args (-> mcp-operator? any/c mcp-result?)])
         (struct-out mcp-operator)
         (struct-out mcp-argument)
         (struct-out mcp-ok)
         (struct-out mcp-error)
         (struct-out exn:fail:mcp-spec)
         check-operator
         mcp-result?
         mcp-argument-has-default?
         mcp-error->string)

;; ---------------------------------------------------------------------------
;; Structs

(struct mcp-argument (name        ; symbol
                      type        ; cli-type (normalized)
                      optional?   ; boolean
                      default     ; any, or cli:no-default
                      doc)        ; (or/c #f string?)
  #:prefab)

(struct mcp-operator (name        ; symbol -- the Racket binding/identity
                      method      ; string -- wire-level MCP tool name
                      arguments   ; (listof mcp-argument)
                      return-type ; cli-type (normalized)
                      doc)        ; (or/c #f string?)
  #:prefab)

(struct exn:fail:mcp-spec exn:fail (path) #:transparent)

;; path : (listof symbol), e.g. '(read-file) or '(read-file start-line)
;; values : (hash symbol -> typed value); optional arguments that were absent
;; and declared no default are simply not bound
(struct mcp-ok (operator values) #:prefab)

;; kind ∈ '(bad-payload unknown-argument missing-required bad-value)
;; datum : offending key / argument name / (cons name raw-string)
;; at : path into the spec; detail : alist of extra context
(struct mcp-error (kind datum at detail) #:prefab)

(define (mcp-result? v)
  (or (mcp-ok? v) (mcp-error? v)))

(define (mcp-argument-has-default? a)
  (not (eq? (mcp-argument-default a) cli:no-default)))

;; ---------------------------------------------------------------------------
;; Errors

(define (render-spec-path path)
  (string-join (map (lambda (s) (format "~a" s)) path) " → "))

(define (raise-mcp-spec-error path fmt . args)
  (raise (exn:fail:mcp-spec
          (if (null? path)
              (format "mcp-spec: ~a" (apply format fmt args))
              (format "mcp-spec: ~a: ~a"
                      (render-spec-path path) (apply format fmt args)))
          (current-continuation-marks)
          path)))

;; ---------------------------------------------------------------------------
;; Types
;;
;; cli-spec exports its type interpreters (type-parse, describe-type,
;; known-atom?) but not its atom-type constructor or check-type walker, so
;; small mirrors live here. An atom cli-type carries the atom symbol in its
;; parse field; describe-type falls back to the atom's description.

(define (normalize-type t path who)
  (cond
    [(cli:cli-type? t) t]
    [(cli:known-atom? t) (cli:cli-type t #f t #f)]
    [else (raise-mcp-spec-error path "~a: unknown type atom '~a" who t)]))

(define (check-mcp-type t path who)
  (cond
    [(not (cli:cli-type? t))
     (raise-mcp-spec-error path "~a: not a type: ~e" who t)]
    [else
     (define tag (cli:cli-type-parse t))
     (cond
       [(procedure? tag) (void)]
       [(cli:known-atom? tag) (void)]
       [(eq? tag 'enum)
        (unless (and (list? (cli:cli-type-base t))
                     (pair? (cli:cli-type-base t))
                     (andmap string? (cli:cli-type-base t)))
          (raise-mcp-spec-error path "~a: malformed enum type" who))]
       [(eq? tag 'list-of)
        (match (cli:cli-type-base t)
          [(list inner (? string?)) (check-mcp-type inner path who)]
          [_ (raise-mcp-spec-error path "~a: malformed list-of type" who)])]
       [(eq? tag 'pair-of)
        (match (cli:cli-type-base t)
          [(list l r (? string?))
           (check-mcp-type l path who)
           (check-mcp-type r path who)]
          [_ (raise-mcp-spec-error path "~a: malformed pair-of type" who)])]
       [(eq? tag 'or)
        (define ts (cli:cli-type-base t))
        (unless (and (list? ts) (pair? ts))
          (raise-mcp-spec-error path "~a: malformed or-type" who))
        (for ([inner (in-list ts)]) (check-mcp-type inner path who))]
       [else
        (raise-mcp-spec-error path "~a: unknown type atom '~a" who tag)])]))

;; ---------------------------------------------------------------------------
;; Constructors

;; 'read-file -> "read_file": Racket identifiers are kebab-case, MCP tool
;; names are conventionally snake_case.
(define (default-method-name name)
  (regexp-replace* #rx"-" (symbol->string name) "_"))

(define (argument name [type 'string]
                  #:optional? [optional? #f]
                  #:default   [default cli:no-default]
                  #:doc       [doc #f])
  (mcp-argument name
                (normalize-type type (list name) "argument")
                optional? default doc))

(define (operator name
                  #:method  [method (default-method-name name)]
                  #:returns [returns 'string]
                  #:doc     [doc #f]
                  . args)
  (define op
    (mcp-operator name method args
                  (normalize-type returns (list name) "#:returns")
                  doc))
  (check-operator op)
  op)

(define-syntax-rule (define-mcp name body ...)
  (define name (operator 'name body ...)))

;; ---------------------------------------------------------------------------
;; Coherence pass
;;
;; check-operator validates a fully built operator, raising exn:fail:mcp-spec
;; with a path into the spec on the first problem. `operator` runs it; it is
;; exported so hand-assembled or deserialized prefab specs can be checked
;; too. There are no argument-ordering rules: MCP arguments travel name-keyed
;; in a JSON object, so declaration order carries no parsing semantics.

(define (check-operator op)
  (define name (mcp-operator-name op))
  (define here (list name))
  (unless (symbol? name)
    (raise-mcp-spec-error '() "operator name must be a symbol: ~e" name))
  (define method (mcp-operator-method op))
  (unless (and (string? method)
               (regexp-match? #px"^[A-Za-z0-9_./-]+$" method))
    (raise-mcp-spec-error here "invalid method name: ~e" method))
  (for ([a (in-list (mcp-operator-arguments op))])
    (unless (mcp-argument? a)
      (raise-mcp-spec-error here "invalid clause: ~e" a)))
  (let loop ([args (mcp-operator-arguments op)] [seen '()])
    (unless (null? args)
      (define n (mcp-argument-name (car args)))
      (when (memq n seen)
        (raise-mcp-spec-error here "duplicate argument name '~a" n))
      (loop (cdr args) (cons n seen))))
  (for ([a (in-list (mcp-operator-arguments op))])
    (define at (list name (mcp-argument-name a)))
    (check-mcp-type (mcp-argument-type a) at "argument")
    (when (and (mcp-argument-has-default? a)
               (not (mcp-argument-optional? a)))
      (raise-mcp-spec-error at "#:default requires #:optional? #t")))
  (check-mcp-type (mcp-operator-return-type op) here "#:returns"))

;; ---------------------------------------------------------------------------
;; Argument parsing
;;
;; parse-operator-args interprets an argument payload against an operator.
;; The payload is a hash or assoc list with symbol or string keys, as falls
;; out of a decoded MCP-call JSON object or a Racket caller's hand-built
;; hash. Values are normalized to strings (JSON scalars included) and every
;; value runs through cli-spec's type-parse, so a payload validates exactly
;; when the equivalent command-line token would. Payload problems answer with
;; an mcp-error, never a raise.

;; normalize-payload : any -> (hash symbol -> string) | mcp-error
(define (normalize-payload payload op-name)
  (define (bad datum)
    (mcp-error 'bad-payload datum (list op-name) '()))
  (define (norm-key k)
    (cond [(symbol? k) k]
          [(string? k) (string->symbol k)]
          [else #f]))
  (define (norm-value v)
    (cond [(string? v) v]
          [(and (number? v) (or (exact-integer? v) (real? v)))
           (number->string v)]
          [(boolean? v) (if v "true" "false")]
          [else #f]))
  (define pairs
    (cond [(hash? payload) (hash->list payload)]
          [(and (list? payload) (andmap pair? payload)) payload]
          [else #f]))
  (cond
    [(not pairs) (bad payload)]
    [else
     (let loop ([pairs pairs] [acc (hash)])
       (cond
         [(null? pairs) acc]
         [else
          (define k (norm-key (car (car pairs))))
          (define v (norm-value (cdr (car pairs))))
          (cond
            [(not k) (bad (car (car pairs)))]
            [(hash-has-key? acc k) (bad k)]
            [(not v) (bad (cdr (car pairs)))]
            [else (loop (cdr pairs) (hash-set acc k v))])]))]))

(define (parse-operator-args op payload)
  (define op-name (mcp-operator-name op))
  (define args (mcp-operator-arguments op))
  (define normalized (normalize-payload payload op-name))
  (cond
    [(mcp-error? normalized) normalized]
    [else
     (define known (map mcp-argument-name args))
     (define unknown
       (for/first ([k (in-hash-keys normalized)]
                   #:unless (memq k known))
         k))
     (cond
       [unknown
        (mcp-error 'unknown-argument unknown (list op-name)
                   (list (cons 'known known)))]
       [else
        (let loop ([args args] [values (hash)])
          (cond
            [(null? args) (mcp-ok op values)]
            [else
             (define a (car args))
             (define n (mcp-argument-name a))
             (define raw (hash-ref normalized n #f))
             (cond
               [raw
                (match (cli:type-parse (mcp-argument-type a) raw)
                  [(list 'ok v) (loop (cdr args) (hash-set values n v))]
                  [(list 'bad expected)
                   (mcp-error 'bad-value (cons n raw) (list op-name n)
                              (list (cons 'expected expected)))])]
               [(not (mcp-argument-optional? a))
                (mcp-error 'missing-required n (list op-name) '())]
               [(mcp-argument-has-default? a)
                (loop (cdr args) (hash-set values n (mcp-argument-default a)))]
               [else (loop (cdr args) values)])]))])]))

;; mcp-error->string : mcp-error -> string
(define (mcp-error->string e)
  (define at (render-spec-path (mcp-error-at e)))
  (define datum (mcp-error-datum e))
  (define (dref k)
    (cond [(assq k (mcp-error-detail e)) => cdr] [else #f]))
  (case (mcp-error-kind e)
    [(bad-payload)
     (format "~a: malformed argument payload at ~e" at datum)]
    [(unknown-argument)
     (string-append
      (format "~a: unknown argument '~a'" at datum)
      (cond
        [(dref 'known)
         => (lambda (ks)
              (format " (known: ~a)"
                      (string-join (map symbol->string ks) ", ")))]
        [else ""]))]
    [(missing-required)
     (format "~a: missing required argument '~a'" at datum)]
    [(bad-value)
     (string-append
      (format "~a: invalid value '~a' for ~a" at (cdr datum) (car datum))
      (cond
        [(dref 'expected) => (lambda (x) (format ": expected ~a" x))]
        [else ""]))]
    [else (format "~a: ~a" at (mcp-error-kind e))]))
