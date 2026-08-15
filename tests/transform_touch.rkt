#lang racket/base
;; Rewrite a shell command line by parsing it with the linea reader and
;; replacing the argument words with a single hidden word, preserving the
;; command head. Invoked as: racket transform_touch.rkt COMMAND HIDDEN
;; Prints the transformed command to stdout; exits non-zero on any parse
;; failure so the caller can choose not to rewrite. This is a genuine
;; syntax transformation over rash/linea line syntax, not a string
;; replacement: the incoming command is read into a (#%linea-line word ...)
;; form, transformed structurally, and rendered back to a command string.
(require linea/read
         syntax/parse
         racket/string)

(define (word->string d)
  (cond
    [(symbol? d) (symbol->string d)]
    [(number? d) (number->string d)]
    [(string? d) d]
    [else (format "~a" d)]))

(define (transform command hidden)
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (eprintf "transform_touch: ~a\n" (exn-message e))
                     (exit 1))])
    (define stx (linea-read-syntax 'transform (open-input-string command)))
    (syntax-parse stx
      #:datum-literals (#%linea-line)
      [(#%linea-line head arg ...)
       (define new-line
         (list '#%linea-line
               (syntax->datum #'head)
               (string->symbol hidden)))
       (string-join (map word->string (cdr new-line)) " ")]
      [_
       (eprintf "transform_touch: not a command line\n")
       (exit 1)])))

(define argv (current-command-line-arguments))
(when (< (vector-length argv) 2)
  (eprintf "usage: transform_touch.rkt COMMAND HIDDEN\n")
  (exit 2))
(displayln (transform (vector-ref argv 0) (vector-ref argv 1)))
