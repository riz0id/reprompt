#lang racket/base
;; awk(1) -- POSIX awk. The program operand slot is active only when no -f
;; supplied a program file. Note that the idiomatic single-quoted program
;; (`awk '{print $1}'`) is rejected by the safe reader before any spec is
;; consulted, so this interface is exercised mainly by -f invocations.
(require "../main.rkt")

(provide awk-cli)

(define-command-interface awk-cli
  #:names ("awk" "gawk" "mawk" "nawk")
  (option field-separator "-F")
  (option assign "-v" #:repeatable)
  (option program-file "-f" #:repeatable)
  (operand program #:arity one
           #:unless (lambda (inv) (invocation-has-option? inv 'program-file)))
  (operand files #:arity many))
