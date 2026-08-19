#lang racket/base
;; Command mappings: surjective translations between command interfaces.
;;
;; A mapping declares how invocations of one interface (#:from) translate to
;; equivalent invocations of another (#:to). It is one-directional and
;; partial -- any argument its rules do not claim rejects the stage -- and
;; surjective on its domain up to the equivalences its identify rules
;; declare. Translation runs in three steps:
;;
;;   1. canonicalize: identify rewrites quotient the source side
;;      (fgrep = grep -F, --colour = --color, a bare --color = --color=auto,
;;      -r = nothing because rg recurses by default), each applied only when
;;      its result stays well-formed and each strictly decreasing a
;;      well-founded measure, so normal forms exist and are unique;
;;   2. map: each remaining argument is relabeled into the target interface
;;      by its rule -- one source argument to one or more target arguments,
;;      values carried through surjective transforms, multiplicity always
;;      preserved -- and the head is renamed;
;;   3. validate: the result must re-parse against the target interface, so
;;      a translation is never emitted unless the target's own parser
;;      vouches for it.
;;
;; Validation mirrors spec.rkt: mappings are authored at development time,
;; so constructor failures raise. The checks are the mapping model's
;; hypotheses: source ids and emitted target ids claimed at most once,
;; value transforms carrying a left-inverse witness, identify rewrites
;; decreasing the measure (headrank, argument count, id rank, bare-value
;; count), heads and operand slots aligned surjectively.

(require racket/list
         "words.rkt"
         "spec.rkt"
         "parse.rkt"
         "invocation.rkt")

(provide (struct-out identify-head)
         (struct-out identify-arg)
         (struct-out map-target)
         (struct-out map-rule)
         (struct-out add-rule)
         command-mapping?
         command-mapping-from
         command-mapping-to
         make-command-mapping
         mapping-claimed-ids
         mapping-forward
         mapping->transformer)

;; adds: (listof (list 'flag id) | (list 'option id value))
(struct identify-head (from to adds) #:transparent)
;; kind: 'flag | 'option; from-value: 'any | #f | string (options only);
;; to: #f (erase) | (list to-id to-value), to-value: 'copy | string
(struct identify-arg (kind from-id from-value to) #:transparent)
;; forward/witness: #f, or value procedures (witness is forward's left
;; inverse -- the clause's surjectivity obligation)
(struct map-target (to-id forward witness) #:transparent)
;; targets: one per emitted argument; singleton for same/rename/value
(struct map-rule (from-id targets guard) #:transparent)
(struct add-rule (kind id value guard) #:transparent)
;; domain: #f, or a predicate over the raw (pre-canonicalization)
;; invocation restricting the mapping's domain -- the place to state
;; conditions the clauses cannot, like regex-dialect compatibility.
;; Restricting the domain of an surjection leaves it an surjection.
(struct command-mapping (from to heads identifies rules adds keep-ids domain)
  #:transparent)

(define (iface-find iface id)
  (for/or ([s (in-list (append (command-interface-flags iface)
                               (command-interface-options iface)))])
    (and (eq? id (arg-spec-id s)) s)))

(define (spec-aliases s)
  (if (flag-spec? s)
      (append (flag-spec-shorts s) (flag-spec-longs s) (flag-spec-literals s))
      (append (option-spec-shorts s) (option-spec-longs s)
              (option-spec-literals s))))

(define (id-rank iface id)
  (for/first ([s (in-list (append (command-interface-flags iface)
                                  (command-interface-options iface)))]
              [i (in-naturals)]
              #:when (eq? id (arg-spec-id s)))
    i))

(define (head-rank iface name)
  (for/first ([n (in-list (command-interface-names iface))]
              [i (in-naturals)]
              #:when (equal? n name))
    i))

;; ---------------------------------------------------------------------------
;; Construction and validation

(define (make-command-mapping #:from from #:to to #:heads heads
                              #:identifies [identifies '()]
                              #:rules [rules '()]
                              #:adds [adds '()]
                              #:operands operands
                              #:domain [domain #f])
  (define who 'make-command-mapping)

  (define (need-spec iface id where)
    (or (iface-find iface id)
        (error who "~a: no flag or option ~s in the ~a interface"
               where id (car (command-interface-names iface)))))

  ;; Rules: source ids claimed once, kinds match, repeatability and
  ;; optional-value compatibility, forwards paired with witnesses.
  (define rule-table (make-hasheq))
  (for ([r (in-list rules)])
    (define fid (map-rule-from-id r))
    (when (hash-ref rule-table fid #f)
      (error who "source id ~s claimed twice" fid))
    (define fs (need-spec from fid "rule"))
    (when (null? (map-rule-targets r))
      (error who "rule ~s emits nothing" fid))
    (for ([t (in-list (map-rule-targets r))])
      (define ts (need-spec to (map-target-to-id t) "rule target"))
      (unless (eq? (flag-spec? fs) (flag-spec? ts))
        (error who "rule ~s: ~s and ~s differ in kind"
               fid fid (map-target-to-id t)))
      (when (and (map-target-forward t) (flag-spec? fs))
        (error who "rule ~s: a flag carries no value to transform" fid))
      (when (and (map-target-forward t) (not (map-target-witness t)))
        (error who "rule ~s: #:forward requires a #:witness left inverse" fid))
      (when (and (option-spec? fs)
                 (option-spec-repeatable? fs)
                 (not (option-spec-repeatable? ts)))
        (error who "rule ~s: repeatable ~s maps to non-repeatable ~s"
               fid fid (map-target-to-id t))))
    (hash-set! rule-table fid r))

  ;; An identify with left pattern (option id #f) eliminates bare
  ;; occurrences of the option before rules apply.
  (define (bare-eliminated? id)
    (for/or ([r (in-list identifies)])
      (and (identify-arg? r)
           (eq? 'option (identify-arg-kind r))
           (eq? id (identify-arg-from-id r))
           (eq? #f (identify-arg-from-value r)))))

  (for ([(fid r) (in-hash rule-table)])
    (define fs (iface-find from fid))
    (when (and (option-spec? fs) (option-spec-optional-value? fs))
      (unless (or (bare-eliminated? fid)
                  (for/and ([t (in-list (map-rule-targets r))])
                    (option-spec-optional-value?
                     (iface-find to (map-target-to-id t)))))
        (error who
               "rule ~s: optional-value option needs an identify for its bare form or optional-value targets"
               fid))))

  ;; Emitted target ids (rules and adds) claimed at most once.
  (define emitted (make-hasheq))
  (define (claim-target! id where)
    (when (hash-ref emitted id #f)
      (error who "target id ~s emitted twice" id))
    (hash-set! emitted id #t))
  (for ([(fid r) (in-hash rule-table)])
    (for ([t (in-list (map-rule-targets r))])
      (claim-target! (map-target-to-id t) fid)))
  (for ([a (in-list adds)])
    (need-spec to (add-rule-id a) "add")
    (claim-target! (add-rule-id a) 'add))

  ;; Identifies: patterns well-formed, left patterns distinct, and each
  ;; rewrite strictly decreasing the measure
  ;; (headrank, |m|, id rank, bare-value count).
  (define seen-pats '())
  (define (claim-pat! key)
    (when (member key seen-pats)
      (error who "identify patterns overlap: ~s" key))
    (set! seen-pats (cons key seen-pats)))
  (for ([r (in-list identifies)])
    (cond
      [(identify-head? r)
       (define hf (identify-head-from r))
       (define ht (identify-head-to r))
       (unless (head-rank from hf)
         (error who "identify: ~s is not a head of the source interface" hf))
       (unless (head-rank from ht)
         (error who "identify: ~s is not a head of the source interface" ht))
       (unless (< (head-rank from ht) (head-rank from hf))
         (error who "identify: head ~s must rewrite to an earlier-declared head" hf))
       (claim-pat! (list 'head hf))
       (for ([a (in-list (identify-head-adds r))])
         (define s (need-spec from (cadr a) "identify head"))
         (case (car a)
           [(flag) (unless (flag-spec? s)
                     (error who "identify: ~s is not a flag" (cadr a)))]
           [(option) (unless (option-spec? s)
                       (error who "identify: ~s is not an option" (cadr a)))
                     (unless (string? (caddr a))
                       (error who "identify: option ~s needs a string value" (cadr a)))]
           [else (error who "identify: bad added argument ~s" a)]))]
      [(identify-arg? r)
       (define kind (identify-arg-kind r))
       (define fid (identify-arg-from-id r))
       (define fv (identify-arg-from-value r))
       (define fs (need-spec from fid "identify"))
       (unless (eq? (eq? kind 'flag) (flag-spec? fs))
         (error who "identify: ~s is not a ~a" fid kind))
       (when (and (eq? kind 'flag) (not (eq? fv 'any)))
         (error who "identify: a flag pattern takes no value" ))
       (claim-pat! (list kind fid fv))
       (define t (identify-arg-to r))
       (when t
         (define tid (car t))
         (define tv (cadr t))
         (define ts (need-spec from tid "identify"))
         (unless (eq? (flag-spec? fs) (flag-spec? ts))
           (error who "identify: ~s and ~s differ in kind" fid tid))
         (cond
           [(eq? fid tid)
            ;; Same id: only the bare-value elimination shape decreases the
            ;; measure (the bare-value count drops, everything above stays).
            (unless (and (eq? kind 'option) (eq? fv #f) (string? tv))
              (error who "identify: rewriting ~s to itself must give a bare option a value" fid))]
           [else
            (unless (< (id-rank from tid) (id-rank from fid))
              (error who "identify: ~s must rewrite to an earlier-declared id" fid))
            (unless (or (eq? tv 'copy) (string? tv))
              (error who "identify: bad replacement value for ~s" fid))]))]
      [else (error who "bad identify rule: ~s" r)]))

  ;; Any-value and specific-value patterns on the same option overlap.
  (for ([r (in-list identifies)] #:when (identify-arg? r))
    (when (eq? 'any (identify-arg-from-value r))
      (for ([r2 (in-list identifies)]
            #:when (and (identify-arg? r2)
                        (not (eq? r r2))
                        (eq? (identify-arg-from-id r) (identify-arg-from-id r2))))
        (error who "identify patterns overlap on ~s" (identify-arg-from-id r)))))

  ;; Witness law, validated on the values appearing literally in the
  ;; mapping (identify replacement values and added option values), plus #f
  ;; for optional-value sources.
  (define literal-values
    (append (for/list ([r (in-list identifies)]
                       #:when (and (identify-arg? r)
                                   (identify-arg-to r)
                                   (string? (cadr (identify-arg-to r)))))
              (cadr (identify-arg-to r)))
            (for*/list ([r (in-list identifies)]
                        #:when (identify-head? r)
                        [a (in-list (identify-head-adds r))]
                        #:when (eq? 'option (car a)))
              (caddr a))))
  (for ([(fid r) (in-hash rule-table)])
    (define fs (iface-find from fid))
    (for ([t (in-list (map-rule-targets r))] #:when (map-target-forward t))
      (define g (map-target-forward t))
      (define g* (map-target-witness t))
      (define candidates
        (if (and (option-spec? fs) (option-spec-optional-value? fs))
            (cons #f literal-values)
            literal-values))
      (for ([v (in-list candidates)])
        (define gv (with-handlers ([exn:fail? (lambda (e) #f)]) (g v)))
        (when (string? gv)
          (unless (equal? (g* gv) v)
            (error who "rule ~s: witness law fails on ~s" fid v))))))

  ;; Heads: every head surviving canonicalization must map, surjectively.
  (define erased-heads
    (for/list ([r (in-list identifies)] #:when (identify-head? r))
      (identify-head-from r)))
  (for ([n (in-list (command-interface-names from))]
        #:unless (member n erased-heads))
    (unless (assoc n heads)
      (error who "no target head for ~s" n)))
  (for ([p (in-list heads)])
    (unless (member (car p) (command-interface-names from))
      (error who "~s is not a head of the source interface" (car p)))
    (unless (member (cdr p) (command-interface-names to))
      (error who "~s is not a head of the target interface" (cdr p))))
  (let ([targets (map cdr heads)])
    (unless (= (length targets) (length (remove-duplicates targets)))
      (error who "two source heads map to one target head")))

  ;; Operands: slots aligned in declared order with matching arities.
  (define from-ops (command-interface-operands from))
  (define to-ops (command-interface-operands to))
  (unless (and (= (length operands) (length from-ops))
               (= (length operands) (length to-ops)))
    (error who "operand pairs must align both interfaces' slots"))
  (for ([p (in-list operands)] [fo (in-list from-ops)] [t (in-list to-ops)])
    (unless (eq? (car p) (operand-spec-id fo))
      (error who "operand ~s out of declared order" (car p)))
    (unless (eq? (cdr p) (operand-spec-id t))
      (error who "operand ~s out of declared order" (cdr p)))
    (unless (eq? (operand-spec-arity fo) (operand-spec-arity t))
      (error who "operand ~s: arities differ" (car p))))

  ;; An argument's original spelling may be kept only when every alias of
  ;; the source id is also an alias of the target id, so any surface -- or
  ;; the source-canonical respelling of a cluster survivor -- is a valid
  ;; target spelling.
  (define keep-ids (make-hasheq))
  (for ([(fid r) (in-hash rule-table)])
    (define ts* (map-rule-targets r))
    (when (and (= 1 (length ts*)) (not (map-target-forward (car ts*))))
      (define fs (iface-find from fid))
      (define ts (iface-find to (map-target-to-id (car ts*))))
      (when (for/and ([a (in-list (spec-aliases fs))])
              (member a (spec-aliases ts)))
        (hash-set! keep-ids fid #t))))

  (unless (or (not domain) (procedure? domain))
    (error who "#:domain must be a predicate over the invocation"))

  (command-mapping from to heads identifies rule-table adds keep-ids domain))

;; ---------------------------------------------------------------------------
;; Canonicalization (nf)

(define (arg-matches? a kind id value)
  (case kind
    [(flag) (and (flag-arg? a) (eq? id (flag-arg-id a)))]
    [(option) (and (option-arg? a) (eq? id (option-arg-id a))
                   (or (eq? value 'any)
                       (equal? value (option-arg-value a))))]))

(define (option-addable? iface inv id)
  (or (option-spec-repeatable? (iface-find iface id))
      (not (invocation-has-option? inv id))))

(define (apply-identify from inv r)
  ;; The rewritten invocation, or #f when the rule does not apply -- either
  ;; its pattern is absent or its result would be ill-formed.
  (cond
    [(identify-head? r)
     (and (equal? (identify-head-from r) (word-logical (invocation-head inv)))
          (for/and ([a (in-list (identify-head-adds r))])
            (or (eq? 'flag (car a)) (option-addable? from inv (cadr a))))
          (for/fold ([inv (invocation-set-head inv (identify-head-to r))])
                    ([a (in-list (identify-head-adds r))])
            (case (car a)
              [(flag) (invocation-add-flag inv (cadr a))]
              [(option) (invocation-add-option inv (cadr a) (caddr a))])))]
    [else
     (define kind (identify-arg-kind r))
     (define fid (identify-arg-from-id r))
     (define fv (identify-arg-from-value r))
     (define matches
       (filter (lambda (a) (arg-matches? a kind fid fv))
               (invocation-args inv)))
     (define t (identify-arg-to r))
     (and (pair? matches)
          (cond
            [(not t)
             (invocation-remove-args inv (lambda (a) (memq a matches)))]
            [else
             (define tid (car t))
             (define tv (cadr t))
             (and (or (eq? 'flag kind)
                      (eq? fid tid)
                      (and (option-addable? from inv tid)
                           (or (option-spec-repeatable? (iface-find from tid))
                               (= 1 (length matches)))))
                  (for/fold ([inv (invocation-remove-args
                                   inv (lambda (a) (memq a matches)))])
                            ([m (in-list matches)])
                    (case kind
                      [(flag) (invocation-add-flag inv tid)]
                      [(option)
                       (invocation-add-option
                        inv tid
                        (if (eq? tv 'copy) (option-arg-value m) tv))])))]))]))

(define (canonicalize m inv)
  ;; Lowest-index applicable rule, repeated to the (unique) normal form;
  ;; termination is the constructor's measure-decrease check.
  (let loop ([inv inv])
    (define inv*
      (for/or ([r (in-list (command-mapping-identifies m))])
        (apply-identify (command-mapping-from m) inv r)))
    (if inv* (loop inv*) inv)))

;; ---------------------------------------------------------------------------
;; The mapped translation

(define (arg-id a)
  (cond
    [(flag-arg? a) (flag-arg-id a)]
    [(option-arg? a) (option-arg-id a)]
    [else #f]))

(define (covered? m inv)
  ;; Every dash argument claimed by a rule whose guard admits the
  ;; invocation; operands and `--` pass, anything else rejects.
  (for/and ([a (in-list (invocation-args inv))])
    (cond
      [(or (operand-arg? a) (double-dash-arg? a)) #t]
      [(arg-id a)
       => (lambda (id)
            (define r (hash-ref (command-mapping-rules m) id #f))
            (and r
                 (let ([g (map-rule-guard r)])
                   (or (not g) (g inv)))))]
      [else #f])))

(define (target-canonical to id) (arg-spec-render-alias (iface-find to id)))

(define (emit-target inv to t source-arg)
  ;; Insert one synthesized target argument carrying an explicit
  ;; target-spelling surface, so rendering never consults the source spec.
  (define tid (map-target-to-id t))
  (define ts (iface-find to tid))
  (define alias (arg-spec-render-alias ts))
  (cond
    [(flag-spec? ts)
     (invocation-insert-arg inv (flag-arg tid (list (text->word alias))))]
    [else
     (define v0 (option-arg-value source-arg))
     (define g (map-target-forward t))
     (define g* (map-target-witness t))
     (define v (if g (g v0) v0))
     (and (or (not v) (string? v))
          ;; The witness equation is re-checked per translated value: the
          ;; definition-time check covers only the mapping's literal
          ;; values, so an unfaithful forward/witness pair rejects here
          ;; rather than producing a non-surjective translation.
          (or (not g) (not g*) (equal? (g* v) v0))
          (invocation-insert-arg
           inv (option-arg tid v (option-render-words alias v) 'separate)))]))

(define (apply-rules m inv)
  (define to (command-mapping-to m))
  (for/fold ([inv inv])
            ([(fid r) (in-hash (command-mapping-rules m))])
    (define targets (map-rule-targets r))
    (cond
      [(not inv) #f]
      [(hash-ref (command-mapping-keep-ids m) fid #f) inv]
      [(and (= 1 (length targets)) (not (map-target-forward (car targets))))
       (if (for/or ([a (in-list (invocation-args inv))]) (eq? fid (arg-id a)))
           (invocation-rename-arg
            inv fid (target-canonical to (map-target-to-id (car targets))))
           inv)]
      [else
       (define matches
         (filter (lambda (a) (eq? fid (arg-id a))) (invocation-args inv)))
       (if (null? matches)
           inv
           (for*/fold ([inv (invocation-remove-args
                             inv (lambda (a) (memq a matches)))])
                      ([a (in-list matches)]
                       [t (in-list targets)])
             (and inv (emit-target inv to t a))))])))

(define (apply-adds m inv)
  (define to (command-mapping-to m))
  (for/fold ([inv inv]) ([a (in-list (command-mapping-adds m))])
    (define g (add-rule-guard a))
    (cond
      [(and g (not (g inv))) inv]
      [else
       (define alias (target-canonical to (add-rule-id a)))
       (case (add-rule-kind a)
         [(flag)
          (invocation-insert-arg
           inv (flag-arg (add-rule-id a) (list (text->word alias))))]
         [(option)
          (invocation-insert-arg
           inv (option-arg (add-rule-id a) (add-rule-value a)
                           (option-render-words alias (add-rule-value a))
                           'separate))])])))

(define (mapping-forward m inv)
  ;; -> the translated invocation, or #f (reject). The domain predicate is
  ;; consulted first, on the raw invocation -- before canonicalization
  ;; erases the arguments it may need to see. The final step re-parses
  ;; the rendered words against the target interface, so target-side
  ;; well-formedness -- repeatability, operand arities and guards -- is
  ;; the target parser's own judgment.
  (define dom (command-mapping-domain m))
  (cond
    [(and dom (not (dom inv))) #f]
    [else (mapping-forward* m inv)]))

(define (mapping-forward* m inv)
  (define inv* (canonicalize m inv))
  (and (covered? m inv*)
       (let* ([inv* (apply-rules m inv*)]
              [inv* (and inv* (apply-adds m inv*))]
              [pair (and inv*
                         (assoc (word-logical (invocation-head inv*))
                                (command-mapping-heads m)))]
              [inv* (and pair (invocation-set-head inv* (cdr pair)))])
         (and inv*
              (invocation? (parse-invocation (command-mapping-to m)
                                             (invocation-words inv*)))
              inv*))))

(define (mapping-claimed-ids m)
  ;; The source ids the mapping's rules claim -- introspection for
  ;; spec-derived test generators, which weight their sampling toward the
  ;; mapping's domain. Ids erased by identify rules are not included.
  (hash-keys (command-mapping-rules m)))

(define ((mapping->transformer m) spec inv)
  ;; The transform-line callback shape.
  (and (eq? spec (command-mapping-from m))
       (mapping-forward m inv)))
