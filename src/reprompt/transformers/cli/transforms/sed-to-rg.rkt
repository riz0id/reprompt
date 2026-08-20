#lang racket/base
;; sed -n '/pattern/p' -> rg, over the bundled specs (specs/sed.rkt as
;; source, specs/rg.rkt as target). The claimed domain is the
;; print-matching-lines idiom only: quiet mode with a single bare
;; /regexp/p script. The #:when guard admits just quiet-mode
;; invocations with no -e/-f/-i (guards see parsed flags, not
;; positional values), and the script's shape is checked at rewrite
;; time by script->pattern, which raises on anything that is not
;; exactly a /regexp/p print program -- a caller treats that as
;; not-rewritable, the same as (xform-unmatched). The guard also
;; requires at least one file operand: a file-less sed reads stdin
;; while a path-less rg searches the working tree, so those
;; invocations stay sed. Patterns cross
;; verbatim with one narrowing: sed's default dialect is BRE while
;; rg's engine is ERE-like, so scripts using BRE-specific escapes
;; (\( \) \{ \} \|) raise rather than silently changing meaning.
;; Should cli-spec-transform grow an (arg NAME = ...) value guard,
;; the shape check belongs there instead.
(require cli-spec-transform)
(require (for-transform "../specs/sed.rkt" "../specs/rg.rkt"))

(provide sed->rg)

;; "/pat/p" -> "pat". The address body is any run of characters in
;; which / appears only escaped; \/ unescapes to / (sed reads the
;; escape, rg must not see it) and every other escape passes through.
(define (script->pattern s)
  (define m (regexp-match #px"^/((?:[^/\\\\]|\\\\.)*)/p$" s))
  (unless m
    (error 'sed->rg "script is not a /regexp/p print program: ~a" s))
  (define body (cadr m))
  (when (regexp-match? #px"\\\\[(){}|]" body)
    (error 'sed->rg
           "pattern uses BRE-specific escapes, meaning would change under rg: ~a"
           body))
  (regexp-replace* #px"\\\\/" body "/"))

(define-transformer sed->rg
  #:source sed-cli
  #:target rg-cli
  #:when (and (flag quiet)
              (arg files)
              (not (flag expression))
              (not (flag script-file))
              (not (flag in-place)))

  (flag extended-regexp
        => (drop "rg's default engine already accepts ERE; patterns cross verbatim"))
  (flag separate
        => (drop "sed -s restarts line numbering per file; no rg line-cycle equivalent"))
  (flag unbuffered => (drop "rg manages its own output buffering"))
  (flag null-data => (flag 'null-data))
  (flag posix => (drop "POSIX-only sed dialect has no rg counterpart"))
  (flag append-buffered => (drop "BSD write-buffering toggle; no rg counterpart"))
  (arg script => (arg 'pattern) #:value script->pattern)
  (arg files => (arg 'paths)))
