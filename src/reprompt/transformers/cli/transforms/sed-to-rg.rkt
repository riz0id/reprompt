#lang racket/base
;; sed -n '/pattern/p' -> rg, over the bundled specs (specs/sed.rkt as
;; source, specs/rg.rkt as target). The claimed domain is the
;; print-matching-lines idiom only: quiet mode with a single bare
;; /regexp/p script, no -e/-f/-i (guards see parsed flags, not
;; positional values), and no -z -- sed -z and rg --null-data frame
;; their NUL-separated output differently at the byte level, so those
;; invocations stay sed. The guard also requires at least one file
;; operand: a file-less sed reads stdin while a path-less rg searches
;; the working tree.
;;
;; Two rewrite-time checks narrow the domain further, both through the
;; raise-means-not-rewritable convention:
;;   - script->pattern admits only /regexp/p print programs whose
;;     regexp is dialect-neutral (identical meaning in GNU BRE, GNU
;;     ERE, POSIX mode, and rg's engine) -- patterns cross verbatim
;;     with no dialect translation, so anything either side reads
;;     differently (BRE-specific escapes, unescaped + ? { } ( ) |,
;;     mid-pattern anchors, class escapes like \d) raises instead.
;;   - refuse-directory-operands stats each file operand when the
;;     rewrite runs: sed read-errors on a directory where rg recurses
;;     into it, and directory-ness is a runtime fact of the filesystem,
;;     not of the path's spelling.
;; Should cli-spec-transform grow an (arg NAME = ...) value guard, the
;; shape check belongs there instead.
(require cli-spec-transform)
(require (for-transform "../specs/sed.rkt" "../specs/rg.rkt"))

(provide sed->rg)

;; Admission check for patterns that cross verbatim: every construct
;; must mean the same thing in GNU BRE, GNU ERE, POSIX mode, and rg's
;; engine. Raises (not rewritable) at the first construct that does not.
(define safe-escapes (string->list ".*[]^$\\/"))

(define (check-dialect-neutral pat)
  (define (bad why)
    (error 'sed->rg
           "pattern is not dialect-neutral (~a), meaning would change under rg: ~a"
           why pat))
  (define n (string-length pat))
  (when (zero? n)
    (bad "the empty pattern reuses sed's last regex"))
  ;; starrable? = the previous construct is an atom a * may repeat in
  ;; every dialect (an ordinary char, ., an allowed escape, or a class)
  (let loop ([i 0] [starrable? #f])
    (when (< i n)
      (define c (string-ref pat i))
      (case c
        [(#\+ #\? #\{ #\} #\( #\) #\|)
         (bad (format "unescaped ~a is literal in BRE, special to rg" c))]
        [(#\\)
         (when (= (add1 i) n) (bad "trailing backslash"))
         (define e (string-ref pat (add1 i)))
         (unless (memv e safe-escapes)
           (bad (format "escape \\~a" e)))
         (loop (+ i 2) #t)]
        [(#\^)
         (unless (zero? i)
           (bad "mid-pattern ^ is literal in BRE, an anchor to rg"))
         (loop (add1 i) #f)]
        [(#\$)
         (unless (= i (sub1 n))
           (bad "mid-pattern $ is literal in BRE, an anchor to rg"))
         (loop (add1 i) #f)]
        [(#\*)
         (unless starrable?
           (bad "* with nothing to repeat is literal in BRE, an error to rg"))
         (loop (add1 i) #f)]
        [(#\[)
         (loop (scan-bracket pat (add1 i) n bad) #t)]
        [else (loop (add1 i) #t)]))))

;; Scan a bracket expression starting just past the [; returns the index
;; just past the closing ]. POSIX rules: ] is a member when it comes
;; first (possibly after ^); [:name:] classes mean the same in both
;; dialects; backslash is a literal member in POSIX but an escape to rg,
;; and rg does not support the [= =] / [. .] collating forms, so those
;; raise.
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

;; "/pat/p" -> "pat". The address body is any run of characters in
;; which / appears only escaped; \/ unescapes to / before the dialect
;; check (sed reads the escape, rg must never see it), then only
;; dialect-neutral patterns cross.
(define (script->pattern s)
  (define m (regexp-match #px"^/((?:[^/\\\\]|\\\\.)*)/p$" s))
  (unless m
    (error 'sed->rg "script is not a /regexp/p print program: ~a" s))
  (define pat (regexp-replace* #px"\\\\/" (cadr m) "/"))
  (check-dialect-neutral pat)
  pat)

;; sed read-errors on a directory operand where rg recurses into it
;; (honoring ignore rules) and prints matches sed never sees. Checked
;; against the filesystem at the moment the rewrite runs.
(define (refuse-directory-operands paths)
  (for ([p (in-list paths)])
    (when (directory-exists? p)
      (error 'sed->rg
             "operand is a directory; sed errors where rg recurses: ~a" p)))
  paths)

(define-transformer sed->rg
  #:source sed-cli
  #:target rg-cli
  #:when (and (flag quiet)
              (arg files)
              (not (flag expression))
              (not (flag script-file))
              (not (flag in-place))
              (not (flag null-data)))

  ;; sed prints bare matched lines; rg prefixes `file:` whenever it is
  ;; given more than one path, so every rewrite pins rg to sed's
  ;; bare-line output shape
  (emit (flag 'no-filename))

  (flag extended-regexp
        => (drop "admitted patterns are dialect-neutral; -E changes nothing"))
  (flag separate
        => (drop "sed -s restarts line numbering per file; no rg line-cycle equivalent"))
  (flag unbuffered => (drop "rg manages its own output buffering"))
  (flag posix
        => (drop "admitted patterns are dialect-neutral; POSIX mode changes nothing"))
  (arg script => (arg 'pattern) #:value script->pattern)
  (arg files => (arg 'paths) #:value refuse-directory-operands))
