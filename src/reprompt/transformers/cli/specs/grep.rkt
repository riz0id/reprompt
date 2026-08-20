#lang racket/base
;; grep(1) -- the POSIX core plus the GNU/BSD spellings both implementations
;; agree on. Options where BSD and GNU disagree about taking a value (-Z)
;; are deliberately absent so they reject instead of misparsing. The head is
;; grep alone: egrep and fgrep are their own commands, not alternative heads
;; of this one. Operands are one 'many slot: whether the first word is the
;; pattern or a file depends on -e/-f, a distinction cli-spec's guardless
;; positionals cannot draw, so a consumer needing it must draw the boundary
;; over the slot's words itself (rendering is verbatim either way).
(require (prefix-in cli: cli-spec))

(provide grep-cli)

(define grep-cli
  (cli:cmd 'grep
     (cli:flag 'recursive #:aliases '(-r --recursive))
     (cli:flag 'recursive-follow #:aliases '(-R --dereference-recursive))
     (cli:flag 'line-number #:aliases '(-n --line-number))
     (cli:flag 'ignore-case #:aliases '(|-i| --ignore-case))
     (cli:flag 'invert #:aliases '(-v --invert-match))
     (cli:flag 'word-regexp #:aliases '(-w --word-regexp))
     (cli:flag 'line-regexp #:aliases '(-x --line-regexp))
     (cli:flag 'count #:aliases '(-c --count))
     (cli:flag 'files-with-matches #:aliases '(-l --files-with-matches))
     (cli:flag 'files-without-match #:aliases '(-L --files-without-match))
     (cli:flag 'only-matching #:aliases '(-o --only-matching))
     (cli:flag 'quiet #:aliases '(-q --quiet --silent))
     (cli:flag 'no-messages #:aliases '(-s --no-messages))
     (cli:flag 'with-filename #:aliases '(-H --with-filename))
     (cli:flag 'no-filename #:aliases '(-h --no-filename))
     (cli:flag 'byte-offset #:aliases '(-b --byte-offset))
     (cli:flag 'extended-regexp #:aliases '(-E --extended-regexp))
     (cli:flag 'fixed-strings #:aliases '(-F --fixed-strings))
     (cli:flag 'basic-regexp #:aliases '(-G --basic-regexp))
     (cli:flag 'perl-regexp #:aliases '(-P --perl-regexp))
     (cli:flag 'text #:aliases '(-a --text))
     (cli:flag 'skip-binary #:aliases '(|-I|))
     (cli:flag 'null-data #:aliases '(-z --null-data))
     (cli:flag 'pattern 'string #:aliases '(-e --regexp) #:repeat 'list)
     (cli:flag 'pattern-file 'string #:aliases '(-f --file) #:repeat 'list)
     (cli:flag 'after-context 'string #:aliases '(-A --after-context))
     (cli:flag 'before-context 'string #:aliases '(-B --before-context))
     (cli:flag 'context 'string #:aliases '(-C --context))
     (cli:flag 'max-count 'string #:aliases '(-m --max-count))
     (cli:flag 'directories (cli:enum "read" "recurse" "skip")
               #:aliases '(-d --directories))
     (cli:flag 'devices (cli:enum "read" "skip") #:aliases '(-D --devices))
     (cli:flag 'include 'string #:aliases '(--include) #:repeat 'list)
     (cli:flag 'exclude 'string #:aliases '(--exclude) #:repeat 'list)
     (cli:flag 'include-dir 'string #:aliases '(--include-dir) #:repeat 'list)
     (cli:flag 'exclude-dir 'string #:aliases '(--exclude-dir) #:repeat 'list)
     (cli:flag 'binary-files (cli:enum "binary" "text" "without-match")
               #:aliases '(--binary-files))
     (cli:flag 'label 'string #:aliases '(--label))
     (cli:flag 'color (cli:enum "never" "no" "none" "auto" "tty" "if-tty"
                                "always" "yes" "force")
               #:aliases '(--color) #:arity '?)
     (cli:flag 'colour (cli:enum "never" "no" "none" "auto" "tty" "if-tty"
                                 "always" "yes" "force")
               #:aliases '(--colour) #:arity '?)
     (cli:arg 'args 'string #:arity '*)))
