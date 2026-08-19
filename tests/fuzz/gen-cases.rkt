#lang racket/base
;; Spec-derived fuzz-case generator: the random half of the
;; extensional-equivalence check for one command mapping.
;;
;; Everything generated here derives from two artifacts loaded out of the
;; transformer tree under test: the mapping named by --mapping/--id, and
;; the source command interface that mapping declares
;; (command-mapping-from) -- its head names, its flag and option ids with
;; their declared aliases, repeatability, optional-value and
;; attached-only behavior. The mapping itself is the domain oracle: a
;; generated command line that translates becomes an equivalence row, one
;; that does not is discarded and redrawn, so every manifest row is an
;; equivalence case and no generator-side domain model exists to disagree
;; with the mapping. Sampling is weighted toward the mapping's claimed
;; ids so most draws land in the domain. Argument values come from a
;; universal, id-blind pool -- the generator never knows which id means
;; what -- and files exist only as effects of generating file paths (see
;; below); there is no pre-built corpus.
;;
;; The PRNG is seeded from system randomness on every run; no seed is
;; accepted, printed, or recorded -- failures are reproduced from the
;; oracle's self-contained reports, never from a seed.
;;
;; Manifest (tab-separated; generated text never contains TAB):
;;
;;   id <TAB> corpus-dir <TAB> source-command <TAB> target-command
;;
;; usage: racket gen-cases.rkt --transformers DIR --mapping MODULE
;;                             --id NAME --out DIR [--count K]

(require racket/cmdline
         racket/file
         racket/list
         racket/random
         racket/string)

(define transformers-dir (make-parameter #f))
(define mapping-module (make-parameter #f))
(define mapping-id (make-parameter #f))
(define the-count (make-parameter 500))
(define out-dir (make-parameter #f))

(command-line
 #:program "gen-cases"
 #:once-each
 [("--transformers") dir "transformer source directory (src/reprompt/transformers)"
                     (transformers-dir dir)]
 [("--mapping") mod "mapping module, relative to the transformer directory"
                (mapping-module mod)]
 [("--id") name "the mapping's provided identifier"
           (mapping-id (string->symbol name))]
 [("--count") k "number of cases" (the-count (string->number k))]
 [("--out") dir "output directory" (out-dir dir)])

(unless (and (transformers-dir) (mapping-module) (mapping-id) (out-dir))
  (eprintf "usage: gen-cases.rkt --transformers DIR --mapping MODULE --id NAME --out DIR [--count K]\n")
  (exit 2))

;; ---------------------------------------------------------------------------
;; The mapping and its source interface, loaded from the tree under test

(define tdir (path->complete-path (transformers-dir)))
(define (cli sym) (dynamic-require (build-path tdir "cli" "main.rkt") sym))

(define transform-line (cli 'transform-line))
(define make-spec-registry (cli 'make-spec-registry))
(define mapping->transformer (cli 'mapping->transformer))
(define command-mapping-from (cli 'command-mapping-from))
(define mapping-claimed-ids (cli 'mapping-claimed-ids))
(define text->word (cli 'text->word))
(define word-raw (cli 'word-raw))
(define command-interface-names (cli 'command-interface-names))
(define command-interface-flags (cli 'command-interface-flags))
(define command-interface-options (cli 'command-interface-options))
(define flag-spec? (cli 'flag-spec?))
(define flag-spec-id (cli 'flag-spec-id))
(define flag-spec-shorts (cli 'flag-spec-shorts))
(define flag-spec-longs (cli 'flag-spec-longs))
(define flag-spec-literals (cli 'flag-spec-literals))
(define option-spec-id (cli 'option-spec-id))
(define option-spec-shorts (cli 'option-spec-shorts))
(define option-spec-longs (cli 'option-spec-longs))
(define option-spec-literals (cli 'option-spec-literals))
(define option-spec-repeatable? (cli 'option-spec-repeatable?))
(define option-spec-optional-value? (cli 'option-spec-optional-value?))
(define option-spec-attached-only? (cli 'option-spec-attached-only?))
(define option-spec-values (cli 'option-spec-values))

(define the-mapping
  (dynamic-require (build-path tdir (mapping-module)) (mapping-id)))
(define source-spec (command-mapping-from the-mapping))
(define claimed (mapping-claimed-ids the-mapping))

(define translate
  (let ([registry (make-spec-registry (list source-spec))]
        [xf (mapping->transformer the-mapping)])
    (lambda (cmd) (transform-line cmd registry xf))))

;; A generated argument is rendered exactly as the transformer will re-read
;; it: through the library's own word quoting.
(define (shell-word s) (word-raw (text->word s)))

(random-seed (modulo (integer-bytes->integer (crypto-random-bytes 4) #f #f)
                     2147483647))

(define (pick lst) (list-ref lst (random (length lst))))
(define (chance pct) (< (random 100) pct))
(define (rand-int lo hi) (+ lo (random (add1 (- hi lo)))))

;; ---------------------------------------------------------------------------
;; Files exist only as effects of generating file paths. Each case has
;; its own working directory, empty until the case's argument values
;; happen to draw paths: drawing a file path usually creates a random
;; plain-ASCII file (no NUL, no TAB) at that path -- and sometimes
;; leaves it dangling, because error cases are equivalence cases too --
;; while drawing a directory path creates the directory populated with
;; random files. Hidden files and .gitignore appear the same way, as
;; randomly drawn dotfile names, never as fixtures.

(define stems
  '("foo" "bar42" "Xyz" "hello" "n0te" "alpha" "omega9" "TODO" "wip" "kernel"))
(define noise-chars " abcdefgHIJKmnop0123456789.*[]^$/:,_-=@%~+?|()")
(define exts '("txt" "md" "c"))

(define (noise-line)
  (build-string (rand-int 0 50)
                (lambda (_)
                  (string-ref noise-chars (random (string-length noise-chars))))))

(define (planted-line)
  (string-append (noise-line) (pick stems) (noise-line)))

(define (file-content)
  (define lines
    (for/list ([_ (in-range (rand-int 0 60))])
      (if (chance 35) (planted-line) (noise-line))))
  (if (null? lines) "" (string-append (string-join lines "\n") "\n")))

(define (write-text path content)
  (call-with-output-file path #:exists 'truncate
    (lambda (out) (display content out))))

(define dot-names '(".hidden" ".gitignore" ".cfg"))

(define (fresh-name)
  (if (chance 12)
      (pick dot-names)
      (format "~a~a~a" (pick '("data" "log" "note" "src" "deep"))
              (random 10)
              (if (chance 80) (string-append "." (pick exts)) ""))))

(define (gen-path)
  (define r (random 100))
  (cond
    [(< r 8) "."]
    [(< r 16) (string-append "sub" (number->string (random 3)) "/")]
    [(< r 70) (fresh-name)]
    [else (string-append "sub" (number->string (random 3)) "/" (fresh-name))]))

(define (populate-dir! dir)
  (make-directory* dir)
  (for ([_ (in-range (rand-int 1 3))])
    (write-text (build-path dir (fresh-name))
                (if (chance 10) "" (file-content)))))

(define (materialize! case-dir p)
  ;; The effect of having generated the path p: usually create what it
  ;; names; sometimes leave it dangling.
  (when (chance 80)
    (cond
      [(equal? p ".") (populate-dir! case-dir)]
      [(regexp-match? #rx"/$" p) (populate-dir! (build-path case-dir p))]
      [else
       (define full (build-path case-dir p))
       (define-values (base _name _dir?) (split-path full))
       (when (path? base) (make-directory* base))
       (write-text full (if (chance 10) "" (file-content)))])))

(define (path-value case-dir)
  (define p (gen-path))
  (materialize! case-dir p)
  p)

;; ---------------------------------------------------------------------------
;; Universal value pool -- blind to which id receives a value. A
;; pattern-shaped string handed to a numeric option just produces an
;; error case, and error cases are equivalence cases too (both tools
;; must fail alike).

(define (decorated-stem)
  (define s (pick stems))
  (define t (pick stems))
  (case (random 8)
    [(0) (string-append "^" s)]
    [(1) (string-append s "$")]
    [(2) (string-append s ".*" t)]
    [(3) (string-append "[" (substring s 0 2) "]" (substring s 1))]
    [(4) (string-append s "+")]
    [(5) (string-append s "|" t)]
    [(6) (string-append "(" s ")" (pick '("" "?" "+")))]
    [(7) (string-append (substring s 0 1) "." (substring s 2))]))

(define value-words '("auto" "never" "read" "skip"))

(define (pool-value case-dir)
  (define r (random 100))
  (cond
    [(< r 25) (pick stems)]
    [(< r 45) (decorated-stem)]
    [(< r 60) (number->string (rand-int 0 5))]
    [(< r 70) (string-append "*." (pick exts))]
    [(< r 88) (path-value case-dir)]
    [(< r 96) (pick value-words)]
    [else ""]))

(define (operand-value case-dir)
  (define r (random 100))
  (cond
    [(< r 55) (path-value case-dir)]
    [(< r 75) (pick stems)]
    [(< r 92) (decorated-stem)]
    [else (pick value-words)]))

;; ---------------------------------------------------------------------------
;; Spelling sampler, driven entirely by the interface spec's declared
;; aliases and option behavior.

(define (flag-aliases fs)
  (append (flag-spec-shorts fs) (flag-spec-longs fs) (flag-spec-literals fs)))

(define (gen-flag-group fs)
  (list (pick (flag-aliases fs))))

(define (gen-option-group os case-dir)
  (define shorts (option-spec-shorts os))
  (define longs (option-spec-longs os))
  (define lits (option-spec-literals os))
  (define opt? (option-spec-optional-value? os))
  (define enum (option-spec-values os))
  ;; An enumerated option mostly receives one of its declared values;
  ;; anything else exercises the invalid-value reject path.
  (define v (if (and enum (chance 85)) (pick enum) (pool-value case-dir)))
  (cond
    ;; Optional value, sometimes omitted entirely.
    [(and opt? (chance 30))
     (list (pick (append shorts longs lits)))]
    ;; Attached-only: the value rides the alias.
    [(option-spec-attached-only? os)
     (if (pair? shorts)
         (list (shell-word (string-append (pick shorts) v)))
         (list (shell-word (string-append (pick longs) "=" v))))]
    [else
     ;; Forms the spec admits: an optional-value option never consumes a
     ;; separate word, so its value must be =-attached or short-attached.
     (define forms
       (append
        (if (and (pair? shorts) (not opt?)) '(short-separate) '())
        (if (and (pair? shorts) (positive? (string-length v))) '(short-attached) '())
        (if (and (pair? longs) (not opt?)) '(long-separate) '())
        (if (pair? longs) '(long-equals) '())
        (if (and (pair? lits) (not opt?)) '(literal-separate) '())))
     (if (null? forms)
         (list (pick (append shorts longs lits)))
         (case (pick forms)
           [(short-separate) (list (pick shorts) (shell-word v))]
           [(short-attached) (list (shell-word (string-append (pick shorts) v)))]
           [(long-separate) (list (pick longs) (shell-word v))]
           [(long-equals) (list (shell-word (string-append (pick longs) "=" v)))]
           [(literal-separate) (list (pick lits) (shell-word v))]))]))

(define (short? w)
  (and (= 2 (string-length w)) (char=? #\- (string-ref w 0))
       (not (char=? #\- (string-ref w 1)))))

(define (cluster-shorts words)
  ;; Occasionally merge adjacent short words into one -xy cluster; the
  ;; parser decomposes clusters, so this only varies concrete spelling.
  (let loop ([ws words] [acc '()])
    (cond
      [(null? ws) (reverse acc)]
      [(and (pair? (cdr ws)) (short? (car ws)) (short? (cadr ws)) (chance 25))
       (loop (cddr ws)
             (cons (string-append (car ws) (substring (cadr ws) 1)) acc))]
      [else (loop (cdr ws) (cons (car ws) acc))])))

;; ---------------------------------------------------------------------------
;; Case assembly

(define all-dash-specs
  (append (command-interface-flags source-spec)
          (command-interface-options source-spec)))
(define (dash-spec-id sp)
  (if (flag-spec? sp) (flag-spec-id sp) (option-spec-id sp)))
(define claimed-dash-specs
  (filter (lambda (sp) (memq (dash-spec-id sp) claimed)) all-dash-specs))

(define (draw-dash-spec)
  (if (and (pair? claimed-dash-specs) (chance 80))
      (pick claimed-dash-specs)
      (pick all-dash-specs)))

(define (gen-dash-groups case-dir)
  ;; k draws; a non-repeatable option appears at most once, flags and
  ;; repeatable options may occasionally duplicate.
  (define k (rand-int 0 4))
  (let loop ([n k] [seen '()] [groups '()])
    (if (zero? n)
        (reverse groups)
        (let* ([sp (draw-dash-spec)]
               [id (dash-spec-id sp)]
               [dup? (memq id seen)]
               [allowed?
                (cond
                  [(not dup?) #t]
                  [(flag-spec? sp) (chance 10)]
                  [(option-spec-repeatable? sp) (chance 30)]
                  [else #f])])
          (if allowed?
              (loop (sub1 n) (cons id seen)
                    (cons (if (flag-spec? sp)
                              (gen-flag-group sp)
                              (gen-option-group sp case-dir))
                          groups))
              (loop (sub1 n) seen groups))))))

(define (gen-case case-dir)
  (define head (pick (command-interface-names source-spec)))
  (define dash-words
    (cluster-shorts (append* (shuffle (gen-dash-groups case-dir)))))
  (define n-operands
    (let ([r (random 100)])
      (cond [(< r 10) 0] [(< r 45) 1] [(< r 80) 2] [else 3])))
  (define operands
    (for/list ([_ (in-range n-operands)])
      (shell-word (operand-value case-dir))))
  (define eoo (if (chance 5) '("--") '()))
  (define tail-group
    (if (and (null? eoo) (chance 8) (pair? operands))
        (let ([sp (draw-dash-spec)])
          (if (flag-spec? sp)
              (gen-flag-group sp)
              (gen-option-group sp case-dir)))
        '()))
  (string-join (append (list head) dash-words eoo operands tail-group) " "))

;; ---------------------------------------------------------------------------
;; Drive

(make-directory* (out-dir))

;; Every manifest row is an equivalence case: draws the mapping rejects
;; are discarded and redrawn. The attempt budget is a liveness bound
;; only -- exhausting it means the domain admits almost nothing the
;; interface can express.
(define attempt-budget (* (the-count) 200))
(define attempts 0)

(define rows
  (for/list ([i (in-range (the-count))])
    (define dir-name (format "case-~a" i))
    (define case-dir (build-path (out-dir) dir-name))
    (make-directory* case-dir)
    (let retry ()
      (set! attempts (add1 attempts))
      (when (> attempts attempt-budget)
        (eprintf "gen-cases: attempt budget exhausted -- the mapping's domain admits too few generated commands\n")
        (exit 1))
      (define cmd (gen-case case-dir))
      (define rg (translate cmd))
      (if rg
          (string-join (list (number->string i) dir-name cmd rg) "\t")
          (retry)))))

(write-text (build-path (out-dir) "cases.tsv")
            (string-append (string-join rows "\n") "\n"))

(eprintf "gen-cases: ~a cases for ~a (~a draws), out ~a\n"
         (the-count) (mapping-id) attempts (out-dir))
