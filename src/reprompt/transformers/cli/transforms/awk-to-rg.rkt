#lang racket/base
;; awk '/pattern/' -> rg, over the bundled specs (specs/awk.rkt as
;; source, specs/rg.rkt as target). The claimed domain is the
;; print-matching-lines idiom only: a program that is exactly /regexp/
;; (default action: print the record) or its explicit forms
;; /regexp/ {print} and /regexp/ {print $0}, with no -f (the program
;; text must be visible to the shape check) and no -v (an assignment can
;; set RS/ORS/FS and change record framing wholesale, so those
;; invocations stay awk). The guard also requires at least one file
;; operand: a file-less awk reads stdin while a path-less rg searches
;; the working tree.
;;
;; Two rewrite-time checks narrow the domain further, both through the
;; raise-means-not-rewritable convention:
;;   - program->pattern admits only the shapes above, and only when the
;;     regexp is ERE-neutral (identical meaning in gawk's ERE and rg's
;;     engine) -- patterns cross verbatim with no dialect translation.
;;     awk's ERE shares rg's quantifiers, alternation, and grouping, so
;;     the admitted subset is much wider than sed->rg's BRE one; what
;;     raises is the divergent tail (letter escapes like \d -- and \b,
;;     word-boundary to rg but backspace to gawk -- malformed intervals,
;;     mid-pattern anchors, brackets rg reads differently).
;;   - refuse-non-file-operands requires every operand to be an existing
;;     regular file when the rewrite runs: gawk fatally aborts
;;     mid-stream on an unopenable operand (directory or missing file),
;;     truncating output, where rg recurses into directories and skips
;;     missing files while continuing. This also refuses `-` (stdin) and
;;     var=value assignment words, which awk reads specially and rg
;;     would treat as file names.
(require cli-spec-transform)
(require (for-transform "../specs/awk.rkt" "../specs/rg.rkt"))

(provide awk->rg)

;; Admission check for patterns that cross verbatim: every construct
;; must mean the same thing in gawk ERE and rg's engine. Raises (not
;; rewritable) at the first construct that does not.
(define safe-escapes (string->list ".*+?()[]{}|^$\\/"))

(define (check-ere-neutral pat)
  (define (bad why)
    (error 'awk->rg
           "pattern is not ERE-neutral (~a), meaning would change under rg: ~a"
           why pat))
  (define n (string-length pat))
  (when (zero? n) (bad "empty pattern"))
  ;; atom? = the previous construct is something a quantifier may repeat
  ;; in both dialects (an ordinary char, ., an allowed escape, a bracket
  ;; expression, or a closed group)
  (let loop ([i 0] [atom? #f] [depth 0])
    (cond
      [(>= i n)
       (unless (zero? depth) (bad "unbalanced ("))]
      [else
       (define c (string-ref pat i))
       (case c
         [(#\* #\+ #\?)
          (unless atom?
            (bad (format "~a with nothing to repeat" c)))
          (loop (add1 i) #f depth)]
         [(#\{)
          (unless atom? (bad "interval with nothing to repeat"))
          (loop (scan-interval pat (add1 i) n bad) #f depth)]
         [(#\})
          (bad "} outside an interval")]
         [(#\()
          (loop (add1 i) #f (add1 depth))]
         [(#\))
          (when (zero? depth) (bad "unbalanced )"))
          (loop (add1 i) #t (sub1 depth))]
         [(#\|)
          (loop (add1 i) #f depth)]
         [(#\^)
          (unless (or (zero? i)
                      (memv (string-ref pat (sub1 i)) '(#\( #\|)))
            (bad "mid-pattern ^ is a POSIX-undefined corner"))
          (loop (add1 i) #f depth)]
         [(#\$)
          (unless (or (= i (sub1 n))
                      (memv (string-ref pat (add1 i)) '(#\) #\|)))
            (bad "mid-pattern $ is a POSIX-undefined corner"))
          (loop (add1 i) #f depth)]
         [(#\\)
          (when (= (add1 i) n) (bad "trailing backslash"))
          (define e (string-ref pat (add1 i)))
          (unless (memv e safe-escapes)
            (bad (format "escape \\~a" e)))
          (loop (+ i 2) #t depth)]
         [(#\[)
          (loop (scan-bracket pat (add1 i) n bad) #t depth)]
         [else (loop (add1 i) #t depth)])])))

;; Scan an interval quantifier starting just past the {; returns the
;; index just past the closing }. Only well-formed {n} / {n,} / {n,m}
;; pass -- anything else is gawk-version-dependent literal text but an
;; rg error.
(define (scan-interval pat i n bad)
  (define (digits j)
    (let loop ([k j])
      (if (and (< k n) (char-numeric? (string-ref pat k))) (loop (add1 k)) k)))
  (define after-lo (digits i))
  (when (= after-lo i) (bad "malformed interval"))
  (define after-sep
    (if (and (< after-lo n) (char=? (string-ref pat after-lo) #\,))
        (digits (add1 after-lo))
        after-lo))
  (unless (and (< after-sep n) (char=? (string-ref pat after-sep) #\}))
    (bad "malformed interval"))
  (add1 after-sep))

;; Scan a bracket expression starting just past the [; returns the index
;; just past the closing ]. POSIX rules: ] is a member when it comes
;; first (possibly after ^); [:name:] classes mean the same in both
;; dialects; backslash is a literal member in POSIX but an escape to rg
;; (and gawk allows escapes here, another divergence), and rg does not
;; support the [= =] / [. .] collating forms, so those raise.
(define (scan-bracket pat i n bad)
  (define start
    (if (and (< i n) (char=? (string-ref pat i) #\^)) (add1 i) i))
  (define first-member
    (if (and (< start n) (char=? (string-ref pat start) #\])) (add1 start) start))
  (let loop ([j first-member])
    (when (>= j n) (bad "unterminated bracket expression"))
    (define c (string-ref pat j))
    (cond
      [(char=? c #\]) (add1 j)]
      [(char=? c #\\) (bad "backslash inside a bracket expression")]
      [(and (char=? c #\[) (< (add1 j) n)
            (memv (string-ref pat (add1 j)) '(#\= #\.)))
       (bad "collating form inside a bracket expression")]
      [(and (char=? c #\[) (< (add1 j) n)
            (char=? (string-ref pat (add1 j)) #\:))
       (let scan-class ([k (+ j 2)])
         (cond [(>= (add1 k) n) (bad "unterminated [: :] class")]
               [(and (char=? (string-ref pat k) #\:)
                     (char=? (string-ref pat (add1 k)) #\]))
                (loop (+ k 2))]
               [else (scan-class (add1 k))]))]
      [else (loop (add1 j))])))

;; "/pat/", "/pat/ {print}", "/pat/ {print $0}" -> "pat", whitespace-
;; tolerant. The regexp body is any run of characters in which / appears
;; only escaped; \/ unescapes to / before the dialect check (awk reads
;; the escape, rg must never see it), then only ERE-neutral patterns
;; cross.
(define (program->pattern s)
  (define m
    (regexp-match
     #px"^\\s*/((?:[^/\\\\]|\\\\.)*)/(?:\\s*\\{\\s*print(?:\\s+\\$0)?\\s*\\})?\\s*$"
     s))
  (unless m
    (error 'awk->rg "program is not a print-matching-lines rule: ~a" s))
  (define pat (regexp-replace* #px"\\\\/" (cadr m) "/"))
  (check-ere-neutral pat)
  pat)

;; gawk fatally aborts mid-stream on any operand it cannot open --
;; directory or missing file -- truncating output at that point, where
;; rg recurses into directories (honoring ignore rules) and skips
;; missing files while continuing. Checked against the filesystem at the
;; moment the rewrite runs.
(define (refuse-non-file-operands paths)
  (for ([p (in-list paths)])
    (cond
      [(file-exists? p) (void)]
      [(directory-exists? p)
       (error 'awk->rg
              "operand is a directory; gawk errors where rg recurses: ~a" p)]
      [else
       (error 'awk->rg
              "operand is not an existing file; gawk fatally aborts where rg continues: ~a"
              p)]))
  paths)

(define-transformer awk->rg
  #:source awk-cli
  #:target rg-cli
  #:when (and (arg files)
              (not (flag program-file))
              (not (flag assign)))

  ;; awk prints bare matched records; rg prefixes `file:` whenever it is
  ;; given more than one path, so every rewrite pins rg to awk's
  ;; bare-line output shape
  (emit (flag 'no-filename))

  (flag field-separator
        => (drop "an admitted program has no actions and reads no fields; -F never changes $0"))
  (arg program => (arg 'pattern) #:value program->pattern)
  (arg files => (arg 'paths) #:value refuse-non-file-operands))
