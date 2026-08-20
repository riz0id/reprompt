#lang racket/base

;; Host-side corpus generator for the differential fuzz tests: sample
;; random invocations of a transform's source command from its interface
;; spec (cli-spec's random-invocation interpretation), materialize each
;; draw's filesystem effects into its own corpus directory, and then use
;; the transform itself -- invoked from inside that directory, so
;; rewrite-time filesystem checks observe the same tree the commands
;; will run over -- as the sole domain and translation oracle. A refused
;; draw scraps its directory and redraws.
;;
;;   racket gen-corpus.rkt --transforms DIR --transform MODULE --id NAME
;;                         --count K --out DIR
;;
;; There is no seed option, deliberately: this is fuzzing, not generated
;; unit testing. The PRNG seeds from system entropy on every run; nothing
;; is recorded or replayable. Failures are diagnosed from the checker's
;; self-contained reports (both commands, both exit codes, output diff,
;; and the case's fixture tree), not by regeneration.
;;
;; Draws the transform refuses -- xform-unmatched, a source parse error,
;; a dropped subtree, or a raise from a #:value/#:by function (the
;; not-rewritable convention) -- make no claim and are discarded and
;; redrawn, so every manifest row is an equivalence case. A draw the
;; transform accepts with drop warnings IS a case: each (drop "reason")
;; is a semantic claim, and warned runs are exactly what falsifies it.
;; The attempt budget (200 x count) is a liveness bound only; exhausting
;; it means the transform's domain admits almost nothing its source spec
;; can express.
;;
;; Manifest (tab-separated; draws whose words contain TAB or newline are
;; discarded):
;;
;;   id <TAB> case-dir <TAB> source-command <TAB> target-command

(require racket/cmdline
         racket/file
         racket/random
         racket/string
         (prefix-in cli: cli-spec)
         cli-spec-transform)

;; ---------------------------------------------------------------------------
;; Arguments

(define transforms-dir (make-parameter #f))
(define transform-module (make-parameter #f))
(define transform-id (make-parameter #f))
(define the-count (make-parameter 200))
(define out-dir (make-parameter #f))

(command-line
 #:program "gen-corpus"
 #:once-each
 [("--transforms") dir "transformers source tree" (transforms-dir dir)]
 [("--transform") mod "transform module, relative to --transforms"
                  (transform-module mod)]
 [("--id") name "provided transformer id" (transform-id name)]
 [("--count") k "number of cases" (the-count (string->number k))]
 [("--out") dir "corpus output directory" (out-dir dir)])

(unless (and (transforms-dir) (transform-module) (transform-id) (out-dir))
  (eprintf "gen-corpus: --transforms, --transform, --id, --out are required\n")
  (exit 2))

;; ---------------------------------------------------------------------------
;; Seedless PRNG: fresh system entropy every run, nowhere recorded.

(define rng
  (let ([g (make-pseudo-random-generator)])
    (parameterize ([current-pseudo-random-generator g])
      (random-seed
       (add1 (modulo (integer-bytes->integer (crypto-random-bytes 4) #f #f)
                     2147483646))))
    g))

;; ---------------------------------------------------------------------------
;; The transform is the oracle.

(define xf
  (dynamic-require (list 'file (path->string
                                (build-path (transforms-dir)
                                            (transform-module))))
                   (string->symbol (transform-id))))

(unless (transformer? xf)
  (eprintf "gen-corpus: ~a is not a transformer\n" (transform-id))
  (exit 2))

(define source-spec (cli:command-name (transformer-source xf)))

;; → (cons head argv) when the transform accepts, #f otherwise. A raise
;; from a #:value/#:by function is the not-rewritable convention.
(define (translate argv)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define r (transform-argv xf argv))
    (and (xform-ok? r)
         (cons (symbol->string (cli:command-name (xform-ok-target r)))
               (xform-ok-argv r)))))

;; ---------------------------------------------------------------------------
;; Custom type generators: the sed script language. Mostly /RE/p print
;; programs (the shape sed->rg claims), a minority of other scripts so
;; the must-reject shapes stay exercised.

(define (gen-sed-script g)
  (define (esc s) (regexp-replace* #rx"/" s "\\\\/"))
  (define r (random g))
  (cond
    [(< r 0.70)
     (define-values (p w) (cli:random-regex g))
     (values (format "/~a/p" (esc p)) (list w))]
    [(< r 0.80) (values "s/a/b/" '())]
    [(< r 0.88)
     (define-values (p w) (cli:random-regex g))
     (values (format "/~a/d" (esc p)) (list w))]
    [(< r 0.94) (values "y/ab/cd/" '())]
    [else (values "2p" '())]))

(define custom-gens (hash 'sed-script gen-sed-script))

;; ---------------------------------------------------------------------------
;; Effects execution

(define (execute-effects! dir effects)
  (for ([e (in-list effects)])
    (case (car e)
      [(dir) (make-directory* (build-path dir (cadr e)))]
      [(file)
       (define p (build-path dir (cadr e)))
       (define-values (parent _name _dir?) (split-path p))
       (when (path? parent) (make-directory* parent))
       (call-with-output-file p
         (lambda (o) (write-string (caddr e) o))
         #:exists 'truncate/replace)])))

;; ---------------------------------------------------------------------------
;; Shell rendering

(define (shell-quote w)
  (if (and (positive? (string-length w))
           (regexp-match? #px"^[A-Za-z0-9_@%+=:,./-]+$" w))
      w
      (string-append "'" (regexp-replace* #rx"'" w "'\"'\"'") "'")))

(define (render-command head argv)
  (string-join (cons head (map shell-quote argv)) " "))

(define (bad-word? w)
  (or (regexp-match? #rx"\t" w) (regexp-match? #rx"\n" w)))

;; ---------------------------------------------------------------------------
;; Generation loop: every manifest row is an equivalence case.

(make-directory* (out-dir))

(define attempt-budget (* 200 (the-count)))
(define attempts 0)

(define rows
  (for/list ([i (in-range (the-count))])
    (define dir-name (format "case-~a" i))
    (define case-dir (build-path (out-dir) dir-name))
    (let retry ()
      (set! attempts (add1 attempts))
      (when (> attempts attempt-budget)
        (eprintf "gen-corpus: attempt budget exhausted -- the transform's domain admits almost nothing the source spec can express\n")
        (exit 1))
      (define-values (argv effects)
        (cli:random-invocation (transformer-source xf)
                               #:rng rng #:custom-gens custom-gens))
      (cond
        [(ormap bad-word? argv) (retry)]
        [else
         ;; Materialize the fixture tree BEFORE consulting the transform,
         ;; and translate from inside it: rewrite-time filesystem checks
         ;; (a #:value function calling directory-exists?, say) must
         ;; observe exactly the tree the two commands will run over.
         (when (directory-exists? case-dir)
           (delete-directory/files case-dir))
         (make-directory* case-dir)
         (define target
           (with-handlers
               ([exn:fail? (lambda (_) #f)]) ; colliding fixture paths (a
                                             ; path drawn as both file and
                                             ; directory)
             (execute-effects! case-dir effects)
             (parameterize ([current-directory
                             (path->complete-path case-dir)])
               (translate argv))))
         (cond
           [(not target)
            (delete-directory/files case-dir #:must-exist? #f)
            (retry)]
           [else
            (string-join
             (list (number->string i)
                   dir-name
                   (render-command (symbol->string source-spec) argv)
                   (render-command (car target) (cdr target)))
             "\t")])]))))

(void
 (call-with-output-file (build-path (out-dir) "cases.tsv")
   (lambda (o) (write-string (string-append (string-join rows "\n") "\n") o))
   #:exists 'truncate/replace))

(eprintf "gen-corpus: ~a cases for ~a (~a draws), out ~a\n"
         (the-count) (transform-id) attempts (out-dir))
