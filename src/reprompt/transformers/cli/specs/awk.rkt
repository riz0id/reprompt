#lang racket/base
;; awk(1) -- POSIX awk, head `awk` alone: gawk/mawk/nawk are their own
;; commands, not alternative heads of this one. The program operand slot is
;; required: when -f supplies the program, the first file word fills the
;; slot instead; a -f invocation with no operand words does not parse.
(require (prefix-in cli: cli-spec))

(provide awk-cli)

(define awk-cli
  (cli:cmd 'awk
     (cli:flag 'field-separator 'string #:aliases '(-F))
     (cli:flag 'assign 'string #:aliases '(-v) #:repeat 'list)
     (cli:flag 'program-file 'string #:aliases '(-f) #:repeat 'list)
     (cli:arg 'program 'string)
     (cli:arg 'files 'string #:arity '*)))
