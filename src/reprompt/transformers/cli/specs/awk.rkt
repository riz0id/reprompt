#lang racket/base
;; awk(1) -- POSIX awk, head `awk` alone: gawk/mawk/nawk are their own
;; commands, not alternative heads of this one. The program operand slot is
;; required: when -f supplies the program, the first file word fills the
;; slot instead (rendering stays verbatim), and a -f invocation with no
;; operand words rejects and runs as real awk. Note that the
;; idiomatic single-quoted program (`awk '{print $1}'`) is rejected by the
;; safe reader before any spec is consulted, so this interface is exercised
;; mainly by -f invocations.
(require (prefix-in cli: cli-spec)
         "../main.rkt")

(provide awk-cli)

(define awk-cli
  (command->interface
   (cli:cmd 'awk
     (cli:flag 'field-separator 'string #:aliases '(-F))
     (cli:flag 'assign 'string #:aliases '(-v) #:repeat 'list)
     (cli:flag 'program-file 'string #:aliases '(-f) #:repeat 'list)
     (cli:arg 'program 'string)
     (cli:arg 'files 'string #:arity '*))))
