#lang racket/base
;; mv(1) -- BSD flags plus the GNU long spellings and -t/-T/-S/--backup.
;; The trailing 'one operand binds from the end, after sources absorb the
;; surplus: mv SRC... DEST.
(require "../main.rkt")

(provide mv-cli)

(define-command-interface mv-cli
  #:names ("mv")
  (flag force "-f" "--force")
  (flag interactive "-i" "--interactive")
  (flag no-clobber "-n" "--no-clobber")
  (flag verbose "-v" "--verbose")
  (flag no-target-directory "-T" "--no-target-directory")
  (option target-directory "-t" "--target-directory")
  (option suffix "-S" "--suffix")
  (option backup "--backup" #:optional-value)
  (operand sources #:arity many)
  (operand dest #:arity one))
