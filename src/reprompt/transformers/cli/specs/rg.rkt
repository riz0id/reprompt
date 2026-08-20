#lang racket/base
;; rg(1), ripgrep -- the flags and options a grep translation or an rg
;; rewrite is likely to meet. Unlike grep, --color requires a value.
;; Operands are two named slots matching rg's grammar `rg PATTERN
;; [PATH...]`: 'pattern (required) then 'paths ('*), so transforms map
;; into each role by name and rendering order follows declaration
;; order. The pattern slot is required: when -e/-f/--files supplies the
;; pattern, the first path word fills the slot instead (word order is
;; preserved, so rendering stays verbatim), and a -e/-f invocation with
;; no operand words rejects -- a boundary cli-spec's guardless
;; positionals cannot draw, so only a consumer reading the slots by
;; name must draw it itself.
(require (prefix-in cli: cli-spec))

(provide rg-cli)

(define rg-cli
  (cli:cmd 'rg
     (cli:flag 'ignore-case #:aliases '(|-i| --ignore-case))
     (cli:flag 'smart-case #:aliases '(-S --smart-case))
     (cli:flag 'case-sensitive #:aliases '(-s --case-sensitive))
     (cli:flag 'invert #:aliases '(-v --invert-match))
     (cli:flag 'word-regexp #:aliases '(-w --word-regexp))
     (cli:flag 'line-regexp #:aliases '(-x --line-regexp))
     (cli:flag 'line-number #:aliases '(-n --line-number))
     (cli:flag 'no-line-number #:aliases '(-N --no-line-number))
     (cli:flag 'count #:aliases '(-c --count))
     (cli:flag 'count-matches #:aliases '(--count-matches))
     (cli:flag 'include-zero #:aliases '(--include-zero))
     (cli:flag 'files-with-matches #:aliases '(-l --files-with-matches))
     (cli:flag 'files-without-match #:aliases '(--files-without-match))
     (cli:flag 'only-matching #:aliases '(-o --only-matching))
     (cli:flag 'quiet #:aliases '(-q --quiet))
     (cli:flag 'hidden #:aliases '(--hidden))
     (cli:flag 'no-ignore #:aliases '(--no-ignore))
     (cli:flag 'unrestricted #:aliases '(-u --unrestricted))
     (cli:flag 'fixed-strings #:aliases '(-F --fixed-strings))
     (cli:flag 'pcre2 #:aliases '(-P --pcre2))
     (cli:flag 'multiline #:aliases '(-U --multiline))
     (cli:flag 'search-zip #:aliases '(-z --search-zip))
     (cli:flag 'text #:aliases '(-a --text))
     (cli:flag 'follow #:aliases '(-L --follow))
     (cli:flag 'with-filename #:aliases '(-H --with-filename))
     (cli:flag 'no-filename #:aliases '(|-I| --no-filename))
     (cli:flag 'no-messages #:aliases '(--no-messages))
     (cli:flag 'byte-offset #:aliases '(-b --byte-offset))
     (cli:flag 'heading #:aliases '(--heading))
     (cli:flag 'no-heading #:aliases '(--no-heading))
     (cli:flag 'pretty #:aliases '(-p --pretty))
     (cli:flag 'vimgrep #:aliases '(--vimgrep))
     (cli:flag 'json #:aliases '(--json))
     (cli:flag 'null #:aliases '(|-0| --null))
     (cli:flag 'null-data #:aliases '(--null-data))
     (cli:flag 'files #:aliases '(--files))
     (cli:flag 'regexp 'string #:aliases '(-e --regexp) #:repeat 'list)
     (cli:flag 'pattern-file 'string #:aliases '(-f --file) #:repeat 'list)
     (cli:flag 'after-context 'string #:aliases '(-A --after-context))
     (cli:flag 'before-context 'string #:aliases '(-B --before-context))
     (cli:flag 'context 'string #:aliases '(-C --context))
     (cli:flag 'max-count 'string #:aliases '(-m --max-count))
     (cli:flag 'glob 'string #:aliases '(-g --glob) #:repeat 'list)
     (cli:flag 'iglob 'string #:aliases '(--iglob) #:repeat 'list)
     (cli:flag 'type 'string #:aliases '(-t --type) #:repeat 'list)
     (cli:flag 'type-not 'string #:aliases '(-T --type-not) #:repeat 'list)
     (cli:flag 'type-add 'string #:aliases '(--type-add) #:repeat 'list)
     (cli:flag 'threads 'string #:aliases '(-j --threads))
     (cli:flag 'max-depth 'string #:aliases '(--max-depth))
     (cli:flag 'max-filesize 'string #:aliases '(--max-filesize))
     (cli:flag 'encoding 'string #:aliases '(-E --encoding))
     (cli:flag 'replace 'string #:aliases '(-r --replace))
     (cli:flag 'sort (cli:enum "none" "path" "modified" "accessed" "created")
               #:aliases '(--sort))
     (cli:flag 'sortr (cli:enum "none" "path" "modified" "accessed" "created")
               #:aliases '(--sortr))
     (cli:flag 'color (cli:enum "never" "auto" "always" "ansi")
               #:aliases '(--color))
     (cli:flag 'colors 'string #:aliases '(--colors) #:repeat 'list)
     (cli:arg 'pattern 'string)
     (cli:arg 'paths 'string #:arity '*)))
