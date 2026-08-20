#lang racket/base
;; sed(1) -- GNU/BSD common ground. `-i` is the '?-arity (attached-only
;; optional-value) case: GNU `-i[SUFFIX]`, `sed -i.bak`; BSD's
;; separate-suffix spelling `sed -i '' file` still renders verbatim, the
;; empty suffix just parses as an operand. `-l` takes a value in GNU and
;; none in BSD, and `-a` is BSD-only (GNU sed rejects it), so both are
;; absent. The script operand slot is required: when
;; -e/-f supplies the script, the first file word fills the slot instead
;; (rendering stays verbatim, so the emitted words are unchanged), and a
;; -e/-f invocation with no operand words rejects and runs as real sed.
(require (prefix-in cli: cli-spec))

(provide sed-cli)

;; Script text is its own custom type (not 'string) so consumers that
;; interpret types -- invocation generation, above all -- can treat sed
;; scripts distinctly from opaque strings. Any nonempty string parses.
(define sed-script
  (cli:custom 'sed-script
              #:parse (lambda (s) (and (positive? (string-length s)) s))
              #:describe "a sed script"))

(define sed-cli
  (cli:cmd 'sed
     (cli:flag 'quiet #:aliases '(-n --quiet --silent))
     (cli:flag 'extended-regexp #:aliases '(-E -r --regexp-extended))
     (cli:flag 'separate #:aliases '(-s --separate))
     (cli:flag 'unbuffered #:aliases '(-u --unbuffered))
     (cli:flag 'null-data #:aliases '(-z --null-data))
     (cli:flag 'posix #:aliases '(--posix))
     (cli:flag 'expression sed-script #:aliases '(-e --expression) #:repeat 'list)
     (cli:flag 'script-file 'file #:aliases '(-f --file) #:repeat 'list)
     (cli:flag 'in-place 'string #:aliases '(|-i| --in-place) #:arity '?)
     (cli:arg 'script sed-script)
     (cli:arg 'files 'path #:arity '*)))
