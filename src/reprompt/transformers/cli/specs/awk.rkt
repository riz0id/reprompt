#lang racket/base
;; awk(1) -- POSIX awk, head `awk` alone: gawk/mawk/nawk are their own
;; commands, not alternative heads of this one. The program operand slot is
;; required: when -f supplies the program, the first file word fills the
;; slot instead; a -f invocation with no operand words does not parse.
(require (prefix-in cli: cli-spec))

(provide awk-cli)

;; Program text is its own custom type (not 'string) so consumers that
;; interpret types -- invocation generation, above all -- can treat awk
;; programs distinctly from opaque strings. Any nonempty string parses.
(define awk-program
  (cli:custom 'awk-program
              #:parse (lambda (s) (and (positive? (string-length s)) s))
              #:describe "an awk program"))

(define awk-cli
  (cli:cmd 'awk
     (cli:flag 'field-separator 'string #:aliases '(-F))
     (cli:flag 'assign 'string #:aliases '(-v) #:repeat 'list)
     (cli:flag 'program-file 'file #:aliases '(-f) #:repeat 'list)
     (cli:arg 'program awk-program)
     (cli:arg 'files 'path #:arity '*)))
