#lang racket/base
;; grep(1) -> rg(1), as a command mapping.
;;
;; The identify rules declare the source-side equivalences the translation
;; is allowed to collapse: an fgrep/egrep head is grep with -F/-E, --colour
;; is --color, a bare --color means --color=auto, and -E is erased because
;; the extended grammar is rg's default. -r is not erased: grep -r filters
;; nothing, while bare rg skips hidden files and honors .gitignore, so
;; recursive splits into rg's --hidden --no-ignore. Every remaining
;; argument is claimed by exactly one rule; grep spellings shared by rg
;; keep their original surface, spellings rg lacks (-h, -s, --silent,
;; --perl-regexp, --include) re-render as the rg alias. Anything
;; unclaimed -- -d, -D, --exclude, -z, -G, -I, -L, -R and friends --
;; rejects the stage, so those greps run unmodified. (-R stays unclaimed
;; because it would have to emit follow plus hidden/no-ignore,
;; overlapping the recursive clause's emissions, which the
;; disjoint-emissions check forbids.)

(require "../main.rkt"
         "../specs/grep.rkt"
         "../specs/rg.rkt")

(provide grep->rg)

;; Domain guard, in two parts, both fuzz-derived.
;;
;; Regex dialect: grep without -E/-F/-P reads its pattern as a POSIX
;; *basic* regex, while rg's default grammar is extended-like, so a plain
;; grep translates faithfully only when its patterns lie in the fragment
;; BRE and ERE interpret identically: no + ? | ( ) { } or backslash, and
;; no leading * (literal in BRE). With -E the two grammars agree on
;; everything but braces and escapes; with -F the pattern language is
;; identical (fixed strings); with -P both sides are PCRE2, but GNU grep's
;; -P accepts only a single pattern, so PCRE mode admits exactly one -e or
;; one pattern operand. A -f pattern file is unreadable at transform time,
;; so it is claimed only in -F mode, where any file content means the same
;; thing to both tools. Mixed dialect selectors (grep's last-one-wins) are
;; out of the domain entirely.
;;
;; Output modes: grep resolves combinations of -c/-l/-o by fixed
;; precedence while rg resolves them last-one-wins, so at most one of
;; them may appear. (-L is not claimed at all: GNU grep's exit status
;; under -L reflects whether a match was found, rg's whether a file was
;; listed -- extensionally irreconcilable.)

(define (patterns-of inv)
  (append (filter string? (invocation-option-values inv 'pattern))
          (invocation-operands inv 'pattern-operand)))

(define (bre-neutral? p)
  (and (for/and ([c (in-string p)])
         (not (memv c '(#\+ #\? #\| #\( #\) #\{ #\} #\\))))
       (not (regexp-match? #rx"^\\^?\\*" p))))

(define (ere-neutral? p)
  (for/and ([c (in-string p)])
    (not (memv c '(#\{ #\} #\\)))))

(define (dialect-ok? inv)
  (define head (word-logical (invocation-head inv)))
  (define e (+ (invocation-flag-count inv 'extended-regexp)
               (if (equal? head "egrep") 1 0)))
  (define f (+ (invocation-flag-count inv 'fixed-strings)
               (if (equal? head "fgrep") 1 0)))
  (define p (invocation-flag-count inv 'perl-regexp))
  (and (<= (+ (if (> e 0) 1 0) (if (> f 0) 1 0) (if (> p 0) 1 0)) 1)
       (cond
         [(> f 0) #t]
         [(> p 0) (and (not (invocation-has-option? inv 'pattern-file))
                       (= 1 (length (patterns-of inv))))]
         [(> e 0) (and (not (invocation-has-option? inv 'pattern-file))
                       (andmap ere-neutral? (patterns-of inv)))]
         [else (and (not (invocation-has-option? inv 'pattern-file))
                    (andmap bre-neutral? (patterns-of inv)))])))

(define (output-modes-ok? inv)
  (<= (+ (if (invocation-has-flag? inv 'count) 1 0)
         (if (invocation-has-flag? inv 'files-with-matches) 1 0)
         (if (invocation-has-flag? inv 'only-matching) 1 0))
      1))

;; grep gives -x precedence over -w; rg matches with -w regardless.
(define (match-scope-ok? inv)
  (not (and (invocation-has-flag? inv 'word-regexp)
            (invocation-has-flag? inv 'line-regexp))))

;; GNU grep short-circuits -v with a pattern that matches every line --
;; grep -v -c "" prints no per-file counts at all -- so invert requires
;; non-empty patterns.
(define (invert-ok? inv)
  (or (not (invocation-has-flag? inv 'invert))
      (for/and ([p (in-list (patterns-of inv))])
        (positive? (string-length p)))))

;; -o is where the two tools disagree most: grep prints nothing under
;; -v -o where rg prints lines, grep ignores context options under -o
;; where rg honors them, and grep skips empty matches where rg emits one
;; per position. So only-matching excludes invert and context, and every
;; visible pattern must be non-empty and -- outside fixed-string mode,
;; where * and ? are literals -- free of the nullable quantifiers.
(define (only-matching-ok? inv)
  (define fixed?
    (or (equal? "fgrep" (word-logical (invocation-head inv)))
        (invocation-has-flag? inv 'fixed-strings)))
  (or (not (invocation-has-flag? inv 'only-matching))
      (and (not (invocation-has-flag? inv 'invert))
           (not (invocation-has-option? inv 'after-context))
           (not (invocation-has-option? inv 'before-context))
           (not (invocation-has-option? inv 'context))
           (for/and ([p (in-list (patterns-of inv))])
             (and (positive? (string-length p))
                  (or fixed?
                      (not (regexp-match? #rx"[*?]" p))))))))

(define (in-domain? inv)
  (and (dialect-ok? inv) (output-modes-ok? inv) (match-scope-ok? inv)
       (only-matching-ok? inv) (invert-ok? inv)))

(define-command-mapping grep->rg
  #:from grep-cli
  #:to   rg-cli
  #:heads (("grep" . "rg"))
  #:domain in-domain?

  (identify (head "fgrep") (head "grep" (flag fixed-strings)))
  (identify (head "egrep") (head "grep" (flag extended-regexp)))
  (identify (option colour) (option color))
  (identify (option color #f) (option color "auto"))
  (identify (flag extended-regexp) ε)

  (same line-number ignore-case invert word-regexp line-regexp
        files-with-matches only-matching quiet with-filename fixed-strings
        text byte-offset pattern pattern-file color
        after-context before-context context max-count
        no-filename no-messages)
  ;; grep -c reports a count for every file, including zeroes; rg omits
  ;; zero-count files unless told otherwise.
  (split count (count include-zero))
  ;; grep -r filters nothing; bare rg skips hidden files and .gitignore.
  (split recursive (hidden no-ignore))
  (rename perl-regexp pcre2)
  (rename include glob)
  (operands (pattern-operand . pattern-operand)
            (files . paths))
  #:unmapped reject)
