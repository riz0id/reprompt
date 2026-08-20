#lang racket/base
;; cd -- the shell builtin: symlink handling flags and one optional
;; directory operand (`cd` alone means $HOME, `cd -` is the previous
;; directory and parses as an operand).
(require (prefix-in cli: cli-spec)
         "../main.rkt")

(provide cd-cli)

(define cd-cli
  (command->interface
   (cli:cmd 'cd
     (cli:flag 'logical #:aliases '(-L))
     (cli:flag 'physical #:aliases '(-P))
     (cli:flag 'fail-on-broken #:aliases '(-e))
     (cli:flag 'extended-attributes #:aliases '(-@))
     (cli:arg 'dir 'string #:arity '?))))
