#lang racket/base
;; Edit and render invocations.
;;
;; All edits are functional. Fidelity is surface-first: an argument that
;; still carries its source words renders them verbatim (a surface shared by
;; several arguments -- a `-rn` cluster -- is emitted exactly once), and only
;; arguments synthesized or touched by an edit render canonically, as the
;; spec's first long alias (else first short, else first literal), with a
;; long option's value `=`-attached and quoted when needed. Removing one
;; member of a cluster strips the shared surface from its siblings, so the
;; survivors re-render canonically instead of resurrecting the removed flag.
;; New dash arguments are inserted before any `--` or operand -- after `--`
;; they would be read back as operands.
(require racket/list
         "words.rkt"
         "spec.rkt"
         "parse.rkt")

(provide invocation-set-head
         invocation-add-flag
         invocation-remove-flag
         invocation-add-option
         invocation-remove-option
         invocation-set-option
         invocation-rename-arg
         invocation-words
         render-invocation
         (rename-out [remove-if invocation-remove-args]
                     [insert-dash-arg invocation-insert-arg]
                     [option-words option-render-words]))

(define (arg-surface a)
  (cond
    [(flag-arg? a) (flag-arg-surface a)]
    [(option-arg? a) (option-arg-surface a)]
    [(operand-arg? a) (operand-arg-surface a)]
    [(double-dash-arg? a) (double-dash-arg-surface a)]
    [(passthrough-arg? a) (passthrough-arg-surface a)]
    [(subcommand-arg? a) (subcommand-arg-surface a)]))

(define (strip-surface a)
  (cond
    [(flag-arg? a) (struct-copy flag-arg a [surface #f])]
    [(option-arg? a) (struct-copy option-arg a [surface #f])]
    [else a]))

(define (arg-id a)
  (cond
    [(flag-arg? a) (flag-arg-id a)]
    [(option-arg? a) (option-arg-id a)]
    [else #f]))

(define (long-alias? alias)
  (and (> (string-length alias) 2)
       (char=? #\- (string-ref alias 0))
       (char=? #\- (string-ref alias 1))))

(define (option-words alias value)
  ;; Canonical words for an option: `--alias=value` as one word for a long
  ;; alias, `alias value` otherwise; the bare alias when there is no value.
  (cond
    [(not value) (list (text->word alias))]
    [(long-alias? alias)
     (define vw (text->word value))
     (list (word (string-append alias "=" (word-raw vw))
                 (string-append alias "=" value)
                 (word-quoted? vw)))]
    [else (list (text->word alias) (text->word value))]))

(define (id-spec inv id)
  (define s (invocation-find-spec inv id))
  (unless s (error 'cli "no flag or option ~s in the ~a interface"
                   id (car (command-interface-names (invocation-spec inv)))))
  s)

(define (synthesize inv a)
  (cond
    [(flag-arg? a)
     (list (text->word (arg-spec-render-alias (id-spec inv (flag-arg-id a)))))]
    [(option-arg? a)
     (option-words (arg-spec-render-alias (id-spec inv (option-arg-id a)))
                   (option-arg-value a))]
    [(double-dash-arg? a) (list (word "--" "--" #f))]
    [(subcommand-arg? a) (list (text->word (subcommand-arg-name a)))]
    [else (error 'cli "cannot synthesize ~s" a)]))

(define (invocation-words inv)
  ;; The invocation as words, each shared surface emitted once.
  (define seen (make-hasheq))
  (apply append
         (list (invocation-head inv))
         (for/list ([a (in-list (invocation-args inv))])
           (define surf (arg-surface a))
           (cond
             [(not surf) (synthesize inv a)]
             [(hash-ref seen surf #f) '()]
             [else (hash-set! seen surf #t) surf]))))

(define (render-invocation inv)
  (render-words (invocation-words inv)))

(define (invocation-set-head inv name)
  (struct-copy invocation inv [head (text->word name)]))

(define (insert-dash-arg inv a)
  ;; Before any `--` or operand, after flags/options/subcommand words.
  (define-values (before after)
    (splitf-at (invocation-args inv)
               (lambda (x) (not (or (double-dash-arg? x) (operand-arg? x))))))
  (struct-copy invocation inv [args (append before (list a) after)]))

(define (invocation-add-flag inv id)
  (unless (flag-spec? (id-spec inv id))
    (error 'invocation-add-flag "~s is not a flag" id))
  (insert-dash-arg inv (flag-arg id #f)))

(define (remove-if inv pred)
  ;; Drop matching args; siblings that shared a removed surface re-render
  ;; canonically so the removed argument's text cannot survive in theirs.
  (define args (invocation-args inv))
  (define removed-surfaces
    (for/list ([a (in-list args)]
               #:when (and (pred a) (arg-surface a)))
      (arg-surface a)))
  (struct-copy invocation inv
               [args (for/list ([a (in-list args)] #:unless (pred a))
                       (if (memq (arg-surface a) removed-surfaces)
                           (strip-surface a)
                           a))]))

(define (invocation-remove-flag inv id)
  (remove-if inv (lambda (a) (and (flag-arg? a) (eq? id (flag-arg-id a))))))

(define (invocation-add-option inv id value)
  (define s (id-spec inv id))
  (unless (option-spec? s)
    (error 'invocation-add-option "~s is not an option" id))
  (insert-dash-arg inv (option-arg id value #f 'separate)))

(define (invocation-remove-option inv id)
  (remove-if inv (lambda (a) (and (option-arg? a) (eq? id (option-arg-id a))))))

(define (invocation-set-option inv id value)
  ;; Replace every occurrence with a single canonical one, or add it.
  (invocation-add-option (invocation-remove-option inv id) id value))

(define (invocation-rename-arg inv id alias)
  ;; Re-spell every occurrence of a flag or option with the given alias.
  ;; Cluster siblings that shared a renamed surface re-render canonically so
  ;; the old spelling cannot survive in theirs.
  (id-spec inv id)
  (define (target? a) (eq? id (arg-id a)))
  (define renamed-surfaces
    (for/list ([a (in-list (invocation-args inv))]
               #:when (and (target? a) (arg-surface a)))
      (arg-surface a)))
  (struct-copy invocation inv
               [args (for/list ([a (in-list (invocation-args inv))])
                       (cond
                         [(and (flag-arg? a) (target? a))
                          (flag-arg id (list (text->word alias)))]
                         [(and (option-arg? a) (target? a))
                          (option-arg id (option-arg-value a)
                                      (option-words alias (option-arg-value a))
                                      (option-arg-style a))]
                         [(memq (arg-surface a) renamed-surfaces)
                          (strip-surface a)]
                         [else a]))]))
