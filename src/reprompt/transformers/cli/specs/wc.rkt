#lang racket/base
;; wc(1), GNU coreutils. BSD wc lacks the long spellings and --total /
;; --files0-from / --debug, but agrees with GNU on every short option it
;; shares, so nothing here misparses under either implementation.
;; --help/--version are omitted as elsewhere in specs/.
(require "../main.rkt")

(provide wc-cli)

(define-command-interface wc-cli
  #:names ("wc")
  (flag bytes "-c" "--bytes")
  (flag chars "-m" "--chars")
  (flag lines "-l" "--lines")
  (flag debug "--debug")
  (flag max-line-length "-L" "--max-line-length")
  (flag words "-w" "--words")
  (option files0-from "--files0-from")
  (option total "--total" #:values ("auto" "always" "only" "never"))
  (operand files #:arity many))
