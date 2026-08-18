#lang racket/base
;; cp(1) -- BSD flags plus the GNU long spellings and target-directory
;; options. Same back-anchored operand shape as mv: cp SRC... DEST.
(require "../main.rkt")

(provide cp-cli)

(define-command-interface cp-cli
  #:names ("cp")
  (flag recursive "-r" "-R" "--recursive")
  (flag force "-f" "--force")
  (flag interactive "-i" "--interactive")
  (flag no-clobber "-n" "--no-clobber")
  (flag verbose "-v" "--verbose")
  (flag archive "-a" "--archive")
  (flag preserve-attrs "-p")
  (flag no-dereference "-P" "--no-dereference")
  (flag dereference "-L" "--dereference")
  (flag dereference-args "-H")
  (flag link "-l" "--link")
  (flag symbolic-link "-s" "--symbolic-link")
  (flag update "-u")
  (flag one-file-system "-x" "--one-file-system")
  (flag no-target-directory "-T" "--no-target-directory")
  (option target-directory "-t" "--target-directory")
  (option suffix "-S" "--suffix")
  (option backup "--backup" #:optional-value)
  (option preserve "--preserve" #:optional-value)
  (option reflink "--reflink" #:optional-value)
  (operand sources #:arity many)
  (operand dest #:arity one))
