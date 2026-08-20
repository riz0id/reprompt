#lang racket/base
;; launchctl(1) -- a subcommand-style interface: the word after `launchctl`
;; selects a nested interface with its own flags and operands.
(require (prefix-in cli: cli-spec)
         "../main.rkt")

(provide launchctl-cli)

(define launchctl-cli
  (command->interface
   (cli:cmd 'launchctl
     (cli:subcommand 'load
       (cli:flag 'override #:aliases '(-w))
       (cli:flag 'force #:aliases '(-F))
       (cli:arg 'paths 'string #:arity '*))
     (cli:subcommand 'unload
       (cli:flag 'override #:aliases '(-w))
       (cli:flag 'force #:aliases '(-F))
       (cli:arg 'paths 'string #:arity '*))
     (cli:subcommand 'list
       (cli:flag 'extended #:aliases '(-x))
       (cli:arg 'label 'string #:arity '?))
     (cli:subcommand 'start (cli:arg 'label 'string))
     (cli:subcommand 'stop (cli:arg 'label 'string))
     (cli:subcommand 'enable (cli:arg 'target 'string))
     (cli:subcommand 'disable (cli:arg 'target 'string))
     (cli:subcommand 'bootstrap
       (cli:arg 'domain 'string)
       (cli:arg 'paths 'string #:arity '*))
     (cli:subcommand 'bootout
       (cli:arg 'domain 'string)
       (cli:arg 'paths 'string #:arity '*))
     (cli:subcommand 'kickstart
       (cli:flag 'kill #:aliases '(-k))
       (cli:flag 'print-pid #:aliases '(-p))
       (cli:arg 'target 'string))
     (cli:subcommand 'print (cli:arg 'target 'string))
     (cli:subcommand 'kill
       (cli:arg 'signal 'string)
       (cli:arg 'target 'string))
     (cli:subcommand 'remove (cli:arg 'label 'string))
     (cli:subcommand 'blame (cli:arg 'target 'string))
     (cli:subcommand 'hostinfo)
     (cli:subcommand 'managerpid)
     (cli:subcommand 'manageruid)
     (cli:subcommand 'managername))))
