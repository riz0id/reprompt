#lang racket/base
;; wc(1), GNU coreutils. BSD wc lacks the long spellings and --total /
;; --files0-from / --debug, but agrees with GNU on every short option it
;; shares, so nothing here misparses under either implementation.
;; --help/--version are omitted as elsewhere in specs/.
(require (prefix-in cli: cli-spec)
         "../main.rkt")

(provide wc-cli)

(define wc-cli
  (command->interface
   (cli:cmd 'wc
     (cli:flag 'bytes #:aliases '(-c --bytes))
     (cli:flag 'chars #:aliases '(-m --chars))
     (cli:flag 'lines #:aliases '(-l --lines))
     (cli:flag 'debug #:aliases '(--debug))
     (cli:flag 'max-line-length #:aliases '(-L --max-line-length))
     (cli:flag 'words #:aliases '(-w --words))
     (cli:flag 'files0-from 'string #:aliases '(--files0-from))
     (cli:flag 'total (cli:enum "auto" "always" "only" "never")
               #:aliases '(--total))
     (cli:arg 'files 'string #:arity '*))))
