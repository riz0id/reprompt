#lang racket/base
;; cd -- the shell builtin: symlink handling flags and one optional
;; directory operand (`cd` alone means $HOME, `cd -` is the previous
;; directory and parses as an operand).
(require "../main.rkt")

(provide cd-cli)

(define-command-interface cd-cli
  #:names ("cd")
  (flag logical "-L")
  (flag physical "-P")
  (flag fail-on-broken "-e")
  (flag extended-attributes "-@")
  (operand dir #:arity optional))
