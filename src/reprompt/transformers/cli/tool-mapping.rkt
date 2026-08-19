#lang racket/base
;; Command-to-tool mappings: rewrite one whole command invocation into a
;; single MCP tool call.
;;
;; The source side is a command interface, exactly as in mapping.rkt:
;; the invocation is parsed against #:from, a #:domain predicate narrows
;; the claimed fragment, and coverage is strict -- every dash argument
;; present must be either bound to a parameter or explicitly consumed by
;; the chosen tool case, or the invocation rejects and the command runs
;; unmodified. The target side is a tool interface (#:to): the first
;; tool case whose guard and coverage admit the invocation builds the
;; call's argument object from its parameter bindings, validates it
;; against the tool spec (required parameters, enumerated values), and
;; the caller renders it as <server>.<tool>({...}). Only a lone pipeline
;; stage with no redirects, connectors, or background marker can become
;; a tool call: a tool call cannot be spliced into shell syntax.
;;
;; Mappings are authored at development time, so constructor validation
;; failures raise: tool and parameter ids must exist on the respective
;; interfaces, parameters bind at most once, required parameters must be
;; bound, value forwards carry a witness (re-checked per translated
;; value at runtime), and consumed ids must exist on the source
;; interface.

(require racket/list
         "words.rkt"
         "line.rkt"
         "spec.rkt"
         "parse.rkt"
         "tool-spec.rkt"
         "toolcall.rkt")

(provide (struct-out param-binding)
         (struct-out tool-case)
         command-tool-mapping?
         command-tool-mapping-from
         command-tool-mapping-to
         make-command-tool-mapping
         tool-mapping-forward
         tool-mapping-rewrite-call)

;; kind 'option: source is a source option id, the value is the option's;
;; kind 'operand: source is a source operand slot id, the value is the
;; slot's single value; kind 'const: source is the constant string.
;; default: #f, or the string used when an option/operand source is
;; absent from the invocation.
(struct param-binding (param-id kind source forward witness default)
  #:transparent)
;; consumes: source flag/option ids the case accounts for beyond its
;; bindings (mode selectors); guard: #f or a predicate over the
;; invocation.
(struct tool-case (tool-name guard consumes bindings) #:transparent)
(struct command-tool-mapping (from to cases domain) #:transparent)

(define (iface-find-dash iface id)
  (for/or ([s (in-list (append (command-interface-flags iface)
                               (command-interface-options iface)))])
    (and (eq? id (arg-spec-id s)) s)))

(define (iface-operand-ids iface)
  (map operand-spec-id (command-interface-operands iface)))

;; ---------------------------------------------------------------------------
;; Construction and validation

(define (make-command-tool-mapping #:from from #:to to #:cases cases
                                   #:domain [domain #f])
  (define who 'make-command-tool-mapping)
  (when (null? cases)
    (error who "a mapping needs at least one tool case"))
  (unless (or (not domain) (procedure? domain))
    (error who "#:domain must be a predicate over the invocation"))
  (for ([c (in-list cases)])
    (define ts (tool-interface-find-tool to (tool-case-tool-name c)))
    (unless ts
      (error who "no tool ~s on server ~a"
             (tool-case-tool-name c) (tool-interface-server to)))
    (define bound '())
    (for ([b (in-list (tool-case-bindings c))])
      (define pid (param-binding-param-id b))
      (unless (tool-find-param ts pid)
        (error who "tool ~s has no parameter ~s" (tool-spec-name ts) pid))
      (when (memq pid bound)
        (error who "tool ~s: parameter ~s bound twice" (tool-spec-name ts) pid))
      (set! bound (cons pid bound))
      (case (param-binding-kind b)
        [(option)
         (define s (iface-find-dash from (param-binding-source b)))
         (unless (option-spec? s)
           (error who "binding for ~s: ~s is not a source option"
                  pid (param-binding-source b)))]
        [(operand)
         (unless (memq (param-binding-source b) (iface-operand-ids from))
           (error who "binding for ~s: ~s is not a source operand"
                  pid (param-binding-source b)))]
        [(const)
         (unless (string? (param-binding-source b))
           (error who "binding for ~s: a const binding needs a string" pid))]
        [else (error who "binding for ~s: bad kind ~s"
                     pid (param-binding-kind b))])
      (when (and (param-binding-forward b) (not (param-binding-witness b)))
        (error who "binding for ~s: #:forward requires a #:witness left inverse"
               pid))
      (when (and (param-binding-default b)
                 (not (string? (param-binding-default b))))
        (error who "binding for ~s: #:default must be a string" pid)))
    (for ([p (in-list (tool-spec-params ts))])
      (when (and (param-spec-required? p)
                 (not (memq (param-spec-id p) bound)))
        (error who "tool ~s: required parameter ~s is unbound"
               (tool-spec-name ts) (param-spec-id p))))
    (for ([id (in-list (tool-case-consumes c))])
      (unless (iface-find-dash from id)
        (error who "consumed id ~s is not on the source interface" id))))
  (command-tool-mapping from to cases domain))

;; ---------------------------------------------------------------------------
;; Translation

(define (case-forward m c inv)
  ;; -> (cons tool-name params-alist) | #f
  (define from (command-tool-mapping-from m))
  (define to (command-tool-mapping-to m))
  (define ts (tool-interface-find-tool to (tool-case-tool-name c)))
  (define bound-option-ids
    (for/list ([b (in-list (tool-case-bindings c))]
               #:when (eq? 'option (param-binding-kind b)))
      (param-binding-source b)))
  (define bound-operand-ids
    (for/list ([b (in-list (tool-case-bindings c))]
               #:when (eq? 'operand (param-binding-kind b)))
      (param-binding-source b)))
  (and (or (not (tool-case-guard c)) ((tool-case-guard c) inv))
       ;; Strict coverage of the dash region.
       (for/and ([a (in-list (invocation-args inv))])
         (cond
           [(or (operand-arg? a) (double-dash-arg? a)) #t]
           [(flag-arg? a) (and (memq (flag-arg-id a) (tool-case-consumes c)) #t)]
           [(option-arg? a)
            (define id (option-arg-id a))
            (or (memq id (tool-case-consumes c))
                (and (memq id bound-option-ids) #t))]
           [else #f]))
       ;; A bound option carries at most one occurrence; every filled
       ;; operand slot is bound and carries one value.
       (for/and ([id (in-list bound-option-ids)])
         (<= (length (invocation-option-values inv id)) 1))
       (for/and ([slot (in-list (iface-operand-ids from))])
         (define vs (invocation-operands inv slot))
         (cond
           [(null? vs) #t]
           [(memq slot bound-operand-ids) (= 1 (length vs))]
           [else #f]))
       ;; Build and validate the argument object.
       (let loop ([bs (tool-case-bindings c)] [acc '()])
         (cond
           [(null? bs) (cons (tool-spec-name ts) (reverse acc))]
           [else
            (define b (car bs))
            (define ps (tool-find-param ts (param-binding-param-id b)))
            (define raw
              (case (param-binding-kind b)
                [(const) (param-binding-source b)]
                [(option)
                 (define vs (invocation-option-values inv (param-binding-source b)))
                 (if (and (pair? vs) (string? (car vs)))
                     (car vs)
                     (param-binding-default b))]
                [(operand)
                 (define vs (invocation-operands inv (param-binding-source b)))
                 (if (pair? vs) (car vs) (param-binding-default b))]))
            (cond
              [(not raw)
               ;; Absent without a default: a required parameter rejects
               ;; the case, an optional one is simply omitted.
               (if (param-spec-required? ps) #f (loop (cdr bs) acc))]
              [else
               (define g (param-binding-forward b))
               (define g* (param-binding-witness b))
               (define v (if g (g raw) raw))
               (and (string? v)
                    (or (not g) (equal? (g* v) raw))
                    (or (not (param-spec-values ps))
                        (member v (param-spec-values ps)))
                    (loop (cdr bs)
                          (cons (cons (symbol->string (param-binding-param-id b)) v)
                                acc)))])]))))

(define (tool-mapping-forward m inv)
  ;; -> (cons tool-name params-alist) | #f. The first admitting tool
  ;; case wins.
  (define dom (command-tool-mapping-domain m))
  (cond
    [(and dom (not (dom inv))) #f]
    [else
     (for/or ([c (in-list (command-tool-mapping-cases m))])
       (case-forward m c inv))]))

(define (tool-mapping-rewrite-call m command)
  ;; command string -> rendered <server>.<tool>({...}) call | #f. Only a
  ;; lone stage with no redirects, connectors, or trailing & is
  ;; eligible.
  (define from (command-tool-mapping-from m))
  (define cl (parse-line command))
  (and (cmd-line? cl)
       (null? (cmd-line-connectors cl))
       (null? (cmd-line-trailing cl))
       (= 1 (length (cmd-line-pipelines cl)))
       (let ([stages (pipeline-stages (car (cmd-line-pipelines cl)))])
         (and (= 1 (length stages))
              (let ([st (car stages)])
                (and (null? (stage-redirects st))
                     (let ([head (stage-head st)])
                       (and head
                            (member head (command-interface-names from))
                            (let ([inv (parse-invocation from (stage-words st))])
                              (and (invocation? inv)
                                   (let ([r (tool-mapping-forward m inv)])
                                     (and r
                                          (render-mcp-call
                                           (tool-interface-server
                                            (command-tool-mapping-to m))
                                           (car r)
                                           (cdr r))))))))))))))
