#lang racket/base
;; launchctl(1) -- a subcommand-style interface: the word after `launchctl`
;; selects a nested interface with its own flags and operands.
(require "../main.rkt")

(provide launchctl-cli)

(define-command-interface launchctl-cli
  #:names ("launchctl")
  (subcommand "load"
              (flag override "-w")
              (flag force "-F")
              (operand paths #:arity many))
  (subcommand "unload"
              (flag override "-w")
              (flag force "-F")
              (operand paths #:arity many))
  (subcommand "list"
              (flag extended "-x")
              (operand label #:arity optional))
  (subcommand "start" (operand label #:arity one))
  (subcommand "stop" (operand label #:arity one))
  (subcommand "enable" (operand target #:arity one))
  (subcommand "disable" (operand target #:arity one))
  (subcommand "bootstrap"
              (operand domain #:arity one)
              (operand paths #:arity many))
  (subcommand "bootout"
              (operand domain #:arity one)
              (operand paths #:arity many))
  (subcommand "kickstart"
              (flag kill "-k")
              (flag print-pid "-p")
              (operand target #:arity one))
  (subcommand "print" (operand target #:arity one))
  (subcommand "kill"
              (operand signal #:arity one)
              (operand target #:arity one))
  (subcommand "remove" (operand label #:arity one))
  (subcommand "blame" (operand target #:arity one))
  (subcommand "hostinfo")
  (subcommand "managerpid")
  (subcommand "manageruid")
  (subcommand "managername"))
