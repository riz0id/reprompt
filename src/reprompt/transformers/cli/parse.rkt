#lang racket/base
;; Classify a stage's words against a command interface.
;;
;; A single left-to-right pass over the words after the command head, matching
;; each word by its logical text: literal aliases first (find's `-name` must
;; never be unbundled as `-n -a -m -e`), then `--`, long forms split at the
;; first `=`, short clusters character by character, and everything else as an
;; operand. Operand ids are assigned afterwards, once the flags and options
;; that operand guards may consult are known; a single 'many operand absorbs
;; the surplus, which is what back-anchors `mv SRC... DEST`'s final slot.
;;
;; Every parsed argument carries its `surface`: the source words it came
;; from, shared between arguments born of the same word (a `-rn` cluster
;; yields two flag-args with one shared surface) so rendering can emit the
;; original text exactly once. A synthesized argument has surface #f.
;;
;; The default unknown policy is 'reject: misreading an argument would
;; rewrite a user's command wrongly, while a rejection only costs the
;; rewrite. 'permissive passes through nothing but provably self-contained
;; `--x=v` words -- an unknown `-x` or bare `--x` might consume the word
;; after it, which is exactly the ambiguity that corrupts commands.
(require "words.rkt"
         "spec.rkt")

(provide (struct-out invocation)
         (struct-out flag-arg)
         (struct-out option-arg)
         (struct-out operand-arg)
         (struct-out double-dash-arg)
         (struct-out passthrough-arg)
         (struct-out subcommand-arg)
         parse-invocation
         invocation-has-flag?
         invocation-has-option?
         invocation-flag-count
         invocation-option-values
         invocation-operands
         invocation-subcommand-name
         invocation-find-spec)

;; head: word; sub: subcommand-spec | #f; args: in source order
(struct invocation (spec head sub args) #:transparent)
;; surface: (listof word) | #f -- #f means synthesized by an edit
(struct flag-arg (id surface) #:transparent)
;; value: string | #f; style: 'separate | 'attached-equals | 'attached-short | 'bare
(struct option-arg (id value surface style) #:transparent)
(struct operand-arg (id surface) #:transparent)
(struct double-dash-arg (surface) #:transparent)
(struct passthrough-arg (surface) #:transparent)
(struct subcommand-arg (name surface) #:transparent)

(define (lookup finder iface sub key)
  ;; Subcommand interface first, then the enclosing one.
  (or (and sub (finder (subcommand-spec-interface sub) key))
      (finder iface key)))

(define (parse-cluster w iface sub next)
  ;; One `-xyz` word -> (values consumed-next? args) | reject
  (define l (word-logical w))
  (let loop ([i 1] [flag-ids '()])
    (define (flag-args-for surface)
      (for/list ([id (in-list (reverse flag-ids))])
        (flag-arg id surface)))
    (cond
      [(>= i (string-length l))
       (define surface (list w))
       (values #f (flag-args-for surface))]
      [else
       (define s (lookup spec-find-short iface sub (string-ref l i)))
       (cond
         [(flag-spec? s) (loop (add1 i) (cons (flag-spec-id s) flag-ids))]
         [(option-spec? s)
          (define id (option-spec-id s))
          (define attached (substring l (add1 i)))
          (cond
            [(positive? (string-length attached))
             (define surface (list w))
             (values #f (append (flag-args-for surface)
                                (list (option-arg id attached surface 'attached-short))))]
            [(option-spec-optional-value? s)
             (define surface (list w))
             (values #f (append (flag-args-for surface)
                                (list (option-arg id #f surface 'bare))))]
            [(option-spec-attached-only? s)
             (reject (format "option ~a takes an attached value" (string #\- (string-ref l i))))]
            [next
             (define surface (list w next))
             (values #t (append (flag-args-for surface)
                                (list (option-arg id (word-logical next) surface 'separate))))]
            [else (reject (format "option -~a needs a value" (string-ref l i)))])]
         [else (reject (format "unknown option -~a" (string-ref l i)))])])))

(define (parse-long w iface sub next unknown)
  ;; One `--xxx[=v]` word -> (values consumed-next? args) | reject
  (define l (word-logical w))
  (define eq-pos (for/first ([i (in-naturals)]
                             [c (in-string l)]
                             #:when (char=? c #\=))
                   i))
  (define name (if eq-pos (substring l 0 eq-pos) l))
  (define value (and eq-pos (substring l (add1 eq-pos))))
  (define s (lookup spec-find-long iface sub name))
  (cond
    [(and s value)
     (if (option-spec? s)
         (values #f (list (option-arg (option-spec-id s) value (list w) 'attached-equals)))
         (reject (format "flag ~a does not take a value" name)))]
    [(flag-spec? s) (values #f (list (flag-arg (flag-spec-id s) (list w))))]
    [(option-spec? s)
     (cond
       [(option-spec-optional-value? s)
        (values #f (list (option-arg (option-spec-id s) #f (list w) 'bare)))]
       [next
        (values #t (list (option-arg (option-spec-id s) (word-logical next)
                                     (list w next) 'separate)))]
       [else (reject (format "option ~a needs a value" name))])]
    [(and value (eq? unknown 'permissive))
     ;; --x=v is self-contained, so passing it through cannot misparse.
     (values #f (list (passthrough-arg (list w))))]
    [else (reject (format "unknown option ~a" l))]))

(define (parse-literal s w next)
  ;; A whole-word literal alias -> (values consumed-next? args) | reject
  (cond
    [(flag-spec? s) (values #f (list (flag-arg (flag-spec-id s) (list w))))]
    [(option-spec-optional-value? s)
     (values #f (list (option-arg (option-spec-id s) #f (list w) 'bare)))]
    [next
     (values #t (list (option-arg (option-spec-id s) (word-logical next)
                                  (list w next) 'separate)))]
    [else (reject (format "option ~a needs a value" (word-logical w)))]))

(define (assign-operands specs pending)
  ;; Pending operand-args (id #f, source order) -> id'd args | reject.
  ;; A 'one slot always gets a word, 'optional takes from the surplus,
  ;; 'many absorbs the rest of it.
  (define n (length pending))
  (define total-min
    (for/sum ([s (in-list specs)])
      (if (eq? 'one (operand-spec-arity s)) 1 0)))
  (cond
    [(< n total-min) (reject "missing operand")]
    [else
     (let loop ([specs specs] [pending pending] [surplus (- n total-min)] [acc '()])
       (cond
         [(null? specs)
          (if (null? pending)
              (reverse acc)
              (reject (format "unexpected operand: ~a"
                              (word-logical (car (operand-arg-surface (car pending)))))))]
         [else
          (define s (car specs))
          (define id (operand-spec-id s))
          (define (take-one surplus*)
            (loop (cdr specs) (cdr pending) surplus*
                  (cons (operand-arg id (operand-arg-surface (car pending))) acc)))
          (case (operand-spec-arity s)
            [(one) (take-one surplus)]
            [(optional)
             (if (positive? surplus) (take-one (sub1 surplus)) (loop (cdr specs) pending surplus acc))]
            [(many)
             (let absorb ([k surplus] [pending pending] [acc acc])
               (if (zero? k)
                   (loop (cdr specs) pending 0 acc)
                   (absorb (sub1 k) (cdr pending)
                           (cons (operand-arg id (operand-arg-surface (car pending))) acc))))])]))]))

(define (find-option-spec iface sub id)
  (define (search i)
    (for/or ([s (in-list (command-interface-options i))])
      (and (eq? id (option-spec-id s)) s)))
  (or (and sub (search (subcommand-spec-interface sub)))
      (search iface)))

(define (enum-violation ordered iface sub)
  ;; The id of an option whose supplied value falls outside its spec's
  ;; enumerated values, or #f.
  (for/or ([a (in-list ordered)])
    (and (option-arg? a)
         (option-arg-value a)
         (let ([s (find-option-spec iface sub (option-arg-id a))])
           (and s (option-spec-values s)
                (not (member (option-arg-value a) (option-spec-values s)))
                (option-arg-id a))))))

(define (finish iface head sub args)
  ;; Assign ids to pending operands under the operand guards and rebuild the
  ;; argument list in source order.
  (define ordered (reverse args))
  (define enum-bad (enum-violation ordered iface sub))
  (if enum-bad
      (reject (format "invalid value for option ~a" enum-bad))
      (finish* iface head sub ordered)))

(define (finish* iface head sub ordered)
  (define provisional (invocation iface head sub ordered))
  (define operand-specs
    (for/list ([s (in-list (command-interface-operands
                            (if sub (subcommand-spec-interface sub) iface)))]
               #:when (let ([guard (operand-spec-guard s)])
                        (or (not guard) (guard provisional))))
      s))
  (define pending (for/list ([a (in-list ordered)]
                             #:when (and (operand-arg? a) (not (operand-arg-id a))))
                    a))
  (define assigned (assign-operands operand-specs pending))
  (cond
    [(reject? assigned) assigned]
    [else
     (let loop ([args ordered] [assigned assigned] [acc '()])
       (cond
         [(null? args) (invocation iface head sub (reverse acc))]
         [(and (operand-arg? (car args)) (not (operand-arg-id (car args))))
          (loop (cdr args) (cdr assigned) (cons (car assigned) acc))]
         [else (loop (cdr args) assigned (cons (car args) acc))]))]))

(define (parse-invocation iface ws)
  ;; (listof word), head first -> invocation | reject
  (cond
    [(null? ws) (reject "empty command")]
    [(not (member (word-logical (car ws)) (command-interface-names iface)))
     (reject (format "~a is not a ~a command"
                     (word-logical (car ws))
                     (car (command-interface-names iface))))]
    [else
     (define head (car ws))
     (define unknown (command-interface-unknown-policy iface))
     (let loop ([ws (cdr ws)] [args '()] [sub #f] [eoo #f])
       (cond
         [(null? ws) (finish iface head sub args)]
         [else
          (define w (car ws))
          (define l (word-logical w))
          (define next (and (pair? (cdr ws)) (cadr ws)))
          (define (operand-word)
            (cond
              [(and (not sub) (pair? (command-interface-subcommands iface)))
               (define sc (spec-find-subcommand iface l))
               (if sc
                   (loop (cdr ws) (cons (subcommand-arg l (list w)) args) sc eoo)
                   (reject (format "unknown subcommand: ~a" l)))]
              [else (loop (cdr ws) (cons (operand-arg #f (list w)) args) sub eoo)]))
          (define (classified result-consumed? result-args)
            (loop (if result-consumed? (cddr ws) (cdr ws))
                  (append (reverse result-args) args)
                  sub eoo))
          (define literal (lookup spec-find-literal iface sub l))
          (cond
            [(member l '("|" "||" "&&" "&"))
             ;; Stage splitting happens in line.rkt; a separator here means
             ;; the caller handed over an unsplit line.
             (reject (format "shell separator ~a among arguments" l))]
            [eoo (operand-word)]
            [literal
             (call-with-values (lambda () (parse-literal literal w next))
                               (lambda vs
                                 (if (reject? (car vs))
                                     (car vs)
                                     (apply classified vs))))]
            [(equal? l "--")
             (loop (cdr ws) (cons (double-dash-arg (list w)) args) sub #t)]
            [(and (> (string-length l) 2)
                  (char=? #\- (string-ref l 0))
                  (char=? #\- (string-ref l 1)))
             (call-with-values (lambda () (parse-long w iface sub next unknown))
                               (lambda vs
                                 (if (reject? (car vs))
                                     (car vs)
                                     (apply classified vs))))]
            [(and (> (string-length l) 1)
                  (char=? #\- (string-ref l 0)))
             (call-with-values (lambda () (parse-cluster w iface sub next))
                               (lambda vs
                                 (if (reject? (car vs))
                                     (car vs)
                                     (apply classified vs))))]
            [else (operand-word)])]))]))

(define (invocation-has-flag? inv id)
  (for/or ([a (in-list (invocation-args inv))])
    (and (flag-arg? a) (eq? id (flag-arg-id a)))))

(define (invocation-has-option? inv id)
  (for/or ([a (in-list (invocation-args inv))])
    (and (option-arg? a) (eq? id (option-arg-id a)))))

(define (invocation-flag-count inv id)
  (for/sum ([a (in-list (invocation-args inv))])
    (if (and (flag-arg? a) (eq? id (flag-arg-id a))) 1 0)))

(define (invocation-option-values inv id)
  ;; Values in source order; #f marks a valueless optional-value occurrence.
  (for/list ([a (in-list (invocation-args inv))]
             #:when (and (option-arg? a) (eq? id (option-arg-id a))))
    (option-arg-value a)))

(define (invocation-operands inv id)
  (for/list ([a (in-list (invocation-args inv))]
             #:when (and (operand-arg? a) (eq? id (operand-arg-id a))))
    (word-logical (car (operand-arg-surface a)))))

(define (invocation-subcommand-name inv)
  (and (invocation-sub inv)
       (subcommand-spec-name (invocation-sub inv))))

(define (invocation-find-spec inv id)
  ;; The flag or option spec an id names, in the active subcommand's
  ;; interface or the enclosing one.
  (define (search iface)
    (for/or ([s (in-list (append (command-interface-flags iface)
                                 (command-interface-options iface)))])
      (and (eq? id (arg-spec-id s)) s)))
  (or (and (invocation-sub inv)
           (search (subcommand-spec-interface (invocation-sub inv))))
      (search (invocation-spec inv))))
