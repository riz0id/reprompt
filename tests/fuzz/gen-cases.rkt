#lang racket/base
;; Fuzz-case generator for the grep->rg command mapping: the random half of
;; the extensional-equivalence check. It generates random file corpora and
;; random grep/egrep/fgrep command lines whose regex dialect lies inside
;; the mapping's declared domain, translates each command in-process
;; through grep->rg, and emits a tab-separated manifest that
;; check-cases.sh executes and compares:
;;
;;   id <TAB> corpus-dir <TAB> sortable <TAB> grep-command <TAB> rg-command|REJECT
;;
;; sortable=1 marks multi-file and recursive cases: rg parallelizes across
;; files, so only the sorted line multiset is deterministic there. Context
;; options (-A/-B/-C) are generated only for single-file cases, where the
;; oracle compares byte-for-byte. A fraction of cases are deliberately
;; outside the mapping's domain (-z, -G, --exclude, ...) and must not
;; translate. Generation aborts if the generator's domain model and the
;; mapping's disagree in either direction — an in-domain command that
;; rejects, or an out-of-domain command that translates, is a bug before
;; any process runs.
;;
;; Every run draws a fresh seed from system randomness; the seed is
;; printed and recorded in OUT/SEED, and passing it back via --seed
;; reproduces the identical corpora and manifest, so every oracle failure
;; is reproducible by seed + case id.
;;
;; usage: racket gen-cases.rkt --transformers DIR --out DIR
;;                             [--seed N] [--count K]

(require racket/cmdline
         racket/file
         racket/list
         racket/random
         racket/string)

(define transformers-dir (make-parameter #f))
(define the-seed (make-parameter #f))
(define the-count (make-parameter 300))
(define out-dir (make-parameter #f))

(command-line
 #:program "gen-cases"
 #:once-each
 [("--transformers") dir "transformer source directory (src/reprompt/transformers)"
                     (transformers-dir dir)]
 [("--seed") n "PRNG seed (default: drawn from system randomness)"
             (the-seed (string->number n))]
 [("--count") k "number of cases" (the-count (string->number k))]
 [("--out") dir "output directory" (out-dir dir)])

(unless (and (transformers-dir) (out-dir))
  (eprintf "usage: gen-cases.rkt --transformers DIR --out DIR [--seed N] [--count K]\n")
  (exit 2))

;; ---------------------------------------------------------------------------
;; The mapping, loaded from the transformer tree under test

(define tdir (path->complete-path (transformers-dir)))
(define (cli mod sym) (dynamic-require (build-path tdir "cli" mod) sym))
(define transform-line (cli "main.rkt" 'transform-line))
(define make-spec-registry (cli "main.rkt" 'make-spec-registry))
(define mapping->transformer (cli "main.rkt" 'mapping->transformer))
(define text->word (cli "words.rkt" 'text->word))
(define word-raw (cli "words.rkt" 'word-raw))
(define grep-cli
  (dynamic-require (build-path tdir "cli" "specs" "grep.rkt") 'grep-cli))
(define grep->rg
  (dynamic-require (build-path tdir "cli" "mappings" "grep-rg.rkt") 'grep->rg))

(define translate
  (let ([registry (make-spec-registry (list grep-cli))]
        [xf (mapping->transformer grep->rg)])
    (lambda (cmd) (transform-line cmd registry xf))))

;; A generated argument is rendered exactly as the transformer will re-read
;; it: through the library's own word quoting.
(define (shell-word s) (word-raw (text->word s)))

(define seed-value
  (or (the-seed)
      (integer-bytes->integer (crypto-random-bytes 4) #f #f)))
(random-seed (modulo seed-value 2147483647))

(define (pick lst) (list-ref lst (random (length lst))))
(define (chance pct) (< (random 100) pct))
(define (rand-int lo hi) (+ lo (random (add1 (- hi lo)))))

;; ---------------------------------------------------------------------------
;; Corpora: plain-ASCII files, no hidden files, no VCS metadata, no NUL
;; bytes -- the fragment where grep's and rg's default file selection
;; agree, so every mismatch indicts the mapping or the oracle.

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

(define n-corpora 6)

;; -> vector of (cons dir-name root-file-names)
(define (generate-corpora!)
  (for/vector ([i (in-range n-corpora)])
    (define dir-name (format "corpus-~a" i))
    (define dir (build-path (out-dir) dir-name))
    (make-directory* dir)
    (define roots
      (for/list ([j (in-range (rand-int 1 4))])
        (format "~a~a.~a" (pick '("data" "log" "note" "src")) j (pick exts))))
    (for ([f (in-list roots)])
      (write-text (build-path dir f)
                  (if (chance 8) "" (file-content))))
    (for ([k (in-range (rand-int 0 2))])
      (define sub (build-path dir (format "sub~a" k)))
      (make-directory* sub)
      (for ([j (in-range (rand-int 1 2))])
        (write-text (build-path sub (format "deep~a.~a" j (pick exts)))
                    (file-content))))
    ;; Hidden file and .gitignore: grep -r reads both; the mapping's
    ;; (split recursive (hidden no-ignore)) makes rg read both too. The
    ;; .gitignore names real files, so a translation that forgot
    ;; --no-ignore would visibly skip them.
    (write-text (build-path dir ".hidden0.txt") (file-content))
    (write-text (build-path dir ".gitignore") "*.md\nsub0/\n")
    ;; Fixed-string pattern file for -F -f cases.
    (write-text (build-path dir "pats")
                (string-append
                 (string-join (for/list ([_ (in-range (rand-int 2 3))])
                                (pick stems))
                              "\n")
                 "\n"))
    (cons dir-name roots)))

;; ---------------------------------------------------------------------------
;; Patterns, per regex dialect the command selects

(define (bre-pattern)
  ;; The BRE/ERE-neutral fragment: no + ? | ( ) { } \, no leading *.
  (define s (pick stems))
  (case (random 7)
    [(0) s]
    [(1) (string-append "^" s)]
    [(2) (string-append s "$")]
    [(3) (string-append (substring s 0 1) "." (substring s 2))]
    [(4) (string-append s ".*" (pick stems))]
    [(5) (string-append "[" (substring s 0 2) "]" (substring s 1))]
    [(6) (if (chance 30) "" (string-append s "*"))]))

(define (ere-pattern)
  (define s (pick stems))
  (case (random 5)
    [(0) (bre-pattern)]
    [(1) (string-append s "|" (pick stems))]
    [(2) (string-append "(" s ")" (pick '("+" "?" "")))]
    [(3) (string-append (substring s 0 2) "+" (substring s 2))]
    [(4) (string-append "(" s "|" (pick stems) ")$")]))

(define (fixed-pattern)
  (define s (pick stems))
  (if (chance 40)
      (string-append (substring s 0 2) (pick '("." "+" "?" "|" "(" ")")) (substring s 2))
      s))

(define (pcre-pattern)
  (case (random 3)
    [(0) (pick stems)]
    [(1) "[0-9]+"]
    [(2) (string-append (pick stems) "[a-z]?")]))

;; ---------------------------------------------------------------------------
;; Command assembly

(define flag-aliases
  '((line-number "-n" "--line-number")
    (ignore-case "-i" "--ignore-case")
    (invert "-v" "--invert-match")
    (word-regexp "-w" "--word-regexp")
    (line-regexp "-x" "--line-regexp")
    (count "-c" "--count")
    (files-with-matches "-l" "--files-with-matches")
    (only-matching "-o" "--only-matching")
    (quiet "-q" "--quiet" "--silent")
    (no-messages "-s" "--no-messages")
    (with-filename "-H" "--with-filename")
    (no-filename "-h" "--no-filename")
    (text "-a" "--text")
    (byte-offset "-b" "--byte-offset")))

;; grep resolves combinations of these by fixed precedence, rg last-wins,
;; so the mapping's domain admits at most one per command.
(define output-mode-ids '(count files-with-matches only-matching))

(define (flag-spelling id) (pick (cdr (assq id flag-aliases))))

(define (short? w)
  (and (= 2 (string-length w)) (char=? #\- (string-ref w 0))
       (not (char=? #\- (string-ref w 1)))))

(define (cluster-shorts words)
  ;; Occasionally merge a run of short flags into one -xyz cluster word.
  (let loop ([ws words] [acc '()])
    (cond
      [(null? ws) (reverse acc)]
      [(and (pair? (cdr ws)) (short? (car ws)) (short? (cadr ws)) (chance 30))
       (loop (cddr ws)
             (cons (string-append (car ws) (substring (cadr ws) 1)) acc))]
      [else (loop (cdr ws) (cons (car ws) acc))])))

(define (option-words short long value)
  ;; One option occurrence in a random concrete spelling.
  (case (random 4)
    [(0) (list short value)]
    [(1) (list (string-append short value))]
    [(2) (list long value)]
    [(3) (list (string-append long "=" value))]))

(define (context-option-words)
  (define-values (short long)
    (case (random 4)
      [(0) (values "-A" "--after-context")]
      [(1) (values "-B" "--before-context")]
      [(2) (values "-C" "--context")]
      [(3) (values "-m" "--max-count")]))
  (option-words short long (number->string (rand-int 1 4))))

(define (color-words)
  (pick '(("--color") ("--colour") ("--color=auto") ("--color=never")
          ("--colour=never"))))

(define out-of-domain-words
  '(("-z") ("-G") ("-I") ("--label=x") ("-d" "skip") ("--exclude=*.o")
    ("-D" "read") ("-L") ("--files-without-match")
    ("-R") ("--dereference-recursive")))

;; -> (values command-string sortable? expect-translate?)
(define (gen-case corp)
  (define roots (cdr corp))
  (define mode
    (let ([r (random 100)])
      (cond [(< r 40) 'plain]
            [(< r 60) 'ere]
            [(< r 75) 'fixed]
            [(< r 88) 'pcre]
            [else 'outdomain])))
  (define base-mode (if (eq? mode 'outdomain) 'plain mode))

  ;; Head, plus the dialect flag when the head does not imply the dialect.
  (define-values (head dialect-words)
    (case base-mode
      [(plain) (values "grep" '())]
      [(ere) (if (chance 50)
                 (values "egrep" '())
                 (values "grep" (list (pick '("-E" "--extended-regexp")))))]
      [(fixed) (if (chance 50)
                   (values "fgrep" '())
                   (values "grep" (list (pick '("-F" "--fixed-strings")))))]
      [(pcre) (values "grep" (list (pick '("-P" "--perl-regexp"))))]))

  ;; Flags first: the choice of output mode constrains patterns and
  ;; context below (grep and rg agree on -o only away from -v, context,
  ;; and nullable patterns).
  (define flag-ids
    (let* ([ids (remove* output-mode-ids (map car flag-aliases))]
           [k (rand-int 0 3)]
           [sel (take (shuffle ids) k)]
           [sel (if (chance 40) (cons (pick output-mode-ids) sel) sel)]
           [sel (if (and (pair? sel) (chance 10)) (cons (car sel) sel) sel)])
      sel))
  (define only-matching? (memq 'only-matching flag-ids))
  (define flag-ids*
    (let* ([ids (if only-matching? (remove* '(invert) flag-ids) flag-ids)]
           [ids (if (and (memq 'word-regexp ids) (memq 'line-regexp ids))
                    (remove* (list (pick '(word-regexp line-regexp))) ids)
                    ids)])
      ids))
  (define invert? (memq 'invert flag-ids*))
  (define flags (map flag-spelling flag-ids*))

  (define (make-pattern)
    (define p
      (case base-mode
        [(plain) (bre-pattern)]
        [(ere) (ere-pattern)]
        [(fixed) (fixed-pattern)]
        [(pcre) (pcre-pattern)]))
    (if (or (and (or only-matching? invert?) (zero? (string-length p)))
            (and only-matching?
                 (not (eq? base-mode 'fixed))
                 (regexp-match? #rx"[*?]" p)))
        (make-pattern)
        p))

  ;; Operand shape first: it constrains context options and -f.
  (define shape
    (let ([r (random 100)])
      (cond [(< r 35) 'single] [(< r 75) 'multi] [else 'recursive])))
  (define files
    (case shape
      [(single) (list (pick roots))]
      [(multi) (take (shuffle roots) (rand-int 1 (length roots)))]
      [(recursive) '(".")]))
  (define sortable? (or (eq? shape 'recursive) (> (length files) 1)))

  ;; Pattern conveyance: operand, -e, or -f. Pattern files translate only
  ;; under -F (fixed strings mean the same thing whatever the file holds),
  ;; and GNU grep's -P accepts a single pattern only.
  (define conveyance
    (cond
      [(and (eq? base-mode 'fixed) (chance 12)) 'file]
      [(chance 25) 'e]
      [else 'operand]))
  ;; Dash arguments are built as word groups (an option and its separate
  ;; value stay adjacent), shuffled at the group level, then flattened.
  (define pattern-groups
    (case conveyance
      [(operand) '()]
      [(e) (for/list ([_ (in-range (if (eq? base-mode 'pcre)
                                       1
                                       (rand-int 1 2)))])
             (define p (shell-word (make-pattern)))
             (if (chance 50)
                 (list "-e" p)
                 (list (string-append "--regexp=" p))))]
      [(file) (list (list (pick '("-f" "--file")) "pats"))]))
  (define operand-pattern
    (if (eq? conveyance 'operand) (list (shell-word (make-pattern))) '()))

  (define ctx (if (and (eq? shape 'single) (not only-matching?) (chance 25))
                  (list (context-option-words))
                  '()))
  (define incl (if (and (eq? shape 'recursive) (chance 30))
                   (list (list (string-append "--include=*." (pick exts))))
                   '()))
  (define color (if (chance 10) (list (color-words)) '()))
  (define recursive-groups
    (if (eq? shape 'recursive) (list (list (pick '("-r" "--recursive")))) '()))

  (define groups
    (append (map list dialect-words) (map list flags)
            ctx incl color recursive-groups pattern-groups))
  (define dash-words (cluster-shorts (append* (shuffle groups))))
  (define ood (if (eq? mode 'outdomain) (pick out-of-domain-words) '()))
  (define dashes (append dash-words ood))

  ;; Occasionally end-of-options, occasionally a flag after the operands.
  (define eoo (if (chance 5) '("--") '()))
  (define tail-flag
    ;; Flags that conflict with nothing: safe to append after operands
    ;; without re-checking the combination constraints above.
    (if (and (null? eoo) (chance 10) (pair? dash-words))
        (list (flag-spelling
               (pick '(line-number ignore-case no-messages with-filename
                       no-filename text byte-offset quiet))))
        '()))
  (define words
    (append (list head) dashes eoo operand-pattern
            (map shell-word files) tail-flag))
  (values (string-join words " ") (if sortable? 1 0)
          (not (eq? mode 'outdomain))))

;; ---------------------------------------------------------------------------
;; Drive

(make-directory* (out-dir))
(define corpora (generate-corpora!))
(write-text (build-path (out-dir) "SEED") (format "~a\n" seed-value))

(define rows
  (for/list ([i (in-range (the-count))])
    (define corp (vector-ref corpora (random n-corpora)))
    (define-values (cmd sortable expect?) (gen-case corp))
    (define rg (translate cmd))
    (when (and expect? (not rg))
      (error 'gen-cases
             "in-domain command rejected by the mapping (case ~a): ~a" i cmd))
    (when (and (not expect?) rg)
      (error 'gen-cases
             "out-of-domain command translated (case ~a): ~a -> ~a" i cmd rg))
    (string-join (list (number->string i) (car corp)
                       (number->string sortable) cmd (or rg "REJECT"))
                 "\t")))

(write-text (build-path (out-dir) "cases.tsv")
            (string-append (string-join rows "\n") "\n"))

(define n-reject (for/sum ([r (in-list rows)])
                   (if (string-suffix? r "\tREJECT") 1 0)))
(eprintf "gen-cases: ~a cases (~a translated, ~a rejected), seed ~a, out ~a\n"
         (the-count) (- (the-count) n-reject) n-reject seed-value (out-dir))
