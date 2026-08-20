#lang racket/base
;; grep -> rg, over the bundled specs (specs/grep.rkt as source,
;; specs/rg.rkt as target). Patterns cross verbatim -- there is no
;; regex-dialect translation -- so the regexp-selection flags record that
;; claim as drops: -E is dropped because rg's default engine already
;; accepts ERE, and -G because rg has no BRE engine at all. Behavior grep
;; gates behind a flag but rg does by default (-r, -I, -d/-D) is likewise
;; dropped with the default named in the reason. The four filename-filter
;; options merge into rg's one glob vocabulary (negations last, since
;; later rg globs override earlier ones), and --color/--colour merge into
;; rg's mandatory-value --color by collapsing grep's nine-word vocabulary
;; to never/auto/always. transform-argv reports every drop an invocation
;; actually uses, so nothing is lost silently.
(require cli-spec-transform)
(require (for-transform "../specs/grep.rkt" "../specs/rg.rkt"))

(provide grep->rg)

;; grep's --include-dir/--exclude-dir match a directory basename at any
;; depth; the equivalent rg glob brackets it with **.
(define (dir-glob d)
  (string-append "**/" d "/**"))

(define (globs-by inc exc incd excd)
  (define globs
    (append (or inc '())
            (map dir-glob (or incd '()))
            (map (lambda (g) (string-append "!" g)) (or exc '()))
            (map (lambda (d) (string-append "!" (dir-glob d))) (or excd '()))))
  (and (pair? globs) globs))

;; v is grep's parsed --color value: #t for a bare occurrence (arity '?),
;; or one of its nine enum words.
(define (color->rg v)
  (cond
    [(member v '("never" "no" "none")) "never"]
    [(member v '("always" "yes" "force")) "always"]
    [else "auto"]))

(define-transformer grep->rg
  #:source grep-cli
  #:target rg-cli

  (flag recursive => (drop "rg recurses into directories by default"))
  (flag recursive-follow => (flag 'follow))
  (flag line-number => keep)
  (flag ignore-case => keep)
  (flag invert => keep)
  (flag word-regexp => keep)
  (flag line-regexp => keep)
  (flag count => keep)
  (flag files-with-matches => keep)
  (flag files-without-match => keep)
  (flag only-matching => keep)
  (flag quiet => keep)
  (flag no-messages => keep)
  (flag with-filename => keep)
  (flag no-filename => keep)
  (flag byte-offset => keep)
  (flag extended-regexp
        => (drop "rg's default engine already accepts ERE; patterns cross verbatim"))
  (flag fixed-strings => keep)
  (flag basic-regexp => (drop "rg has no BRE engine; patterns cross verbatim"))
  (flag perl-regexp => (flag 'pcre2))
  (flag text => keep)
  (flag skip-binary => (drop "rg skips binary files by default"))
  (flag null-data
        => (drop "no rg counterpart; rg -z means --search-zip, not NUL-separated lines"))
  (flag pattern => keep)
  (flag pattern-file => keep)
  (flag after-context => keep)
  (flag before-context => keep)
  (flag context => keep)
  (flag max-count => keep)
  (flag directories
        => (drop "rg always recurses into directory operands; no -d equivalent"))
  (flag devices => (drop "rg always skips devices; no -D equivalent"))
  (merge (include exclude include-dir exclude-dir) => (flag 'glob)
         #:by globs-by)
  (flag binary-files
        => (drop "no rg counterpart; rg -a covers --binary-files=text"))
  (flag label => (drop "no rg counterpart for naming stdin"))
  (merge (color colour) => (flag 'color)
         #:by (lambda (c cc)
                (define v (if (eq? c #f) cc c))
                (and v (color->rg v))))
  (arg args => keep))
