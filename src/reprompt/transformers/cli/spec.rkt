#lang racket/base
;; The command-interface model: what a command's CLI looks like.
;;
;; An interface declares boolean flags, options that carry a value, positional
;; operands, and (for commands like systemctl or launchctl) subcommands with
;; interfaces of their own. Aliases are classified by shape: `-x` is a short
;; alias (clusterable, may take an attached value), `--xxx` a long alias
;; (value separate or `=`-attached), and anything else -- find's `-name`,
;; `-print`, `!` -- a literal alias matched only as a whole word, checked
;; before any short-cluster decomposition.
;;
;; Specs are authored at development time, so constructor validation failures
;; (duplicate ids, alias collisions, malformed aliases) raise errors rather
;; than returning reject values.
(require racket/list)

(provide (struct-out command-interface)
         (struct-out flag-spec)
         (struct-out option-spec)
         (struct-out operand-spec)
         (struct-out subcommand-spec)
         make-flag
         make-option
         make-operand
         make-subcommand
         make-command-interface
         make-spec-registry
         registry-lookup
         spec-find-long
         spec-find-short
         spec-find-literal
         spec-find-subcommand
         arg-spec-id
         arg-spec-render-alias)

;; unknown-policy: 'reject | 'permissive
(struct command-interface (names flags options operands subcommands unknown-policy)
  #:transparent)
;; shorts: single-dash single-char aliases ("-r"); longs: "--recursive";
;; literals: whole-word aliases of any other shape ("-print", "!")
(struct flag-spec (id shorts longs literals) #:transparent)
;; optional-value?: the option may appear without a value (=-attached or
;; attached-only forms only -- it never consumes the next word);
;; attached-only?: a short alias's value is only ever attached (sed -i.bak)
(struct option-spec (id shorts longs literals repeatable? optional-value? attached-only?)
  #:transparent)
;; arity: 'one | 'optional | 'many; guard: #f or a predicate over the
;; invocation-so-far deciding whether the slot is active
(struct operand-spec (id arity guard) #:transparent)
(struct subcommand-spec (name interface) #:transparent)

(define (classify-alias who a)
  (cond
    [(regexp-match? #px"^-[^-=\\s]$" a) 'short]
    [(regexp-match? #px"^--[^=\\s]+$" a) 'long]
    [(and (positive? (string-length a))
          (not (regexp-match? #px"[=\\s]" a)))
     'literal]
    [else (error who "malformed alias: ~s" a)]))

(define (partition-aliases who aliases)
  (let loop ([as aliases] [shorts '()] [longs '()] [literals '()])
    (cond
      [(null? as)
       (values (reverse shorts) (reverse longs) (reverse literals))]
      [else
       (define a (car as))
       (case (classify-alias who a)
         [(short) (loop (cdr as) (cons a shorts) longs literals)]
         [(long) (loop (cdr as) shorts (cons a longs) literals)]
         [(literal) (loop (cdr as) shorts longs (cons a literals))])])))

(define (make-flag id aliases)
  (define-values (shorts longs literals) (partition-aliases 'make-flag aliases))
  (flag-spec id shorts longs literals))

(define (make-option id aliases
                     #:repeatable? [repeatable? #f]
                     #:optional-value? [optional-value? #f]
                     #:attached-only? [attached-only? #f])
  (define-values (shorts longs literals) (partition-aliases 'make-option aliases))
  (when (and optional-value? (null? longs) (not attached-only?))
    (error 'make-option
           "option ~a: an optional value needs a long alias or #:attached-only?"
           id))
  (option-spec id shorts longs literals repeatable? optional-value? attached-only?))

(define (make-operand id arity [guard #f])
  (unless (memq arity '(one optional many))
    (error 'make-operand "operand ~a: bad arity ~s" id arity))
  (operand-spec id arity guard))

(define (make-subcommand name interface)
  (subcommand-spec name interface))

(define (check-duplicates who what items)
  (let loop ([items items] [seen '()])
    (cond
      [(null? items) (void)]
      [(member (car items) seen)
       (error who "duplicate ~a: ~s" what (car items))]
      [else (loop (cdr items) (cons (car items) seen))])))

(define (make-command-interface #:names names
                                #:flags [flags '()]
                                #:options [options '()]
                                #:operands [operands '()]
                                #:subcommands [subcommands '()]
                                #:unknown [unknown 'reject])
  (define who 'make-command-interface)
  (unless (memq unknown '(reject permissive))
    (error who "bad unknown policy: ~s" unknown))
  (when (and (pair? subcommands) (pair? operands))
    (error who "an interface with subcommands cannot also take operands"))
  (unless (<= (for/sum ([op (in-list operands)])
                (if (eq? 'many (operand-spec-arity op)) 1 0))
              1)
    (error who "more than one operand with arity 'many"))
  (define dash-specs (append flags options))
  (check-duplicates who "id"
                    (append (map arg-spec-id dash-specs)
                            (map operand-spec-id operands)))
  (check-duplicates who "short alias" (append-map spec-shorts dash-specs))
  (check-duplicates who "long alias" (append-map spec-longs dash-specs))
  (check-duplicates who "literal alias" (append-map spec-literals dash-specs))
  (check-duplicates who "subcommand" (map subcommand-spec-name subcommands))
  (command-interface names flags options operands subcommands unknown))

(define (spec-shorts s)
  (if (flag-spec? s) (flag-spec-shorts s) (option-spec-shorts s)))
(define (spec-longs s)
  (if (flag-spec? s) (flag-spec-longs s) (option-spec-longs s)))
(define (spec-literals s)
  (if (flag-spec? s) (flag-spec-literals s) (option-spec-literals s)))

(define (arg-spec-id s)
  (if (flag-spec? s) (flag-spec-id s) (option-spec-id s)))

(define (arg-spec-render-alias s)
  ;; Canonical spelling for a synthesized argument: first long, else first
  ;; short, else first literal alias.
  (define longs (spec-longs s))
  (define shorts (spec-shorts s))
  (define literals (spec-literals s))
  (cond
    [(pair? longs) (car longs)]
    [(pair? shorts) (car shorts)]
    [(pair? literals) (car literals)]
    [else (error 'arg-spec-render-alias "spec ~a has no aliases" (arg-spec-id s))]))

(define (find-by iface accessor alias)
  (for/or ([s (in-list (append (command-interface-flags iface)
                               (command-interface-options iface)))])
    (and (member alias (accessor s)) s)))

(define (spec-find-long iface name)
  ;; name: the full "--xxx" spelling, without any =-attached value.
  (find-by iface spec-longs name))

(define (spec-find-short iface c)
  ;; c: the character after the dash in a cluster.
  (find-by iface spec-shorts (string #\- c)))

(define (spec-find-literal iface w)
  (find-by iface spec-literals w))

(define (spec-find-subcommand iface name)
  (for/or ([sc (in-list (command-interface-subcommands iface))])
    (and (equal? name (subcommand-spec-name sc)) sc)))

(define (make-spec-registry specs)
  ;; Command name -> interface; a name claimed twice is an authoring error.
  (define table (make-hash))
  (for* ([spec (in-list specs)]
         [name (in-list (command-interface-names spec))])
    (when (hash-ref table name #f)
      (error 'make-spec-registry "duplicate command name: ~s" name))
    (hash-set! table name spec))
  table)

(define (registry-lookup registry head)
  (and head (hash-ref registry head #f)))
