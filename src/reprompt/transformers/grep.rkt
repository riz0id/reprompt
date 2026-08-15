#lang racket/base
;; Rewrite `grep` as `rg` in command-head position, preserving arguments.
;;
;; A genuine linea syntax transform, not a string replace: the command line
;; is read into a (#%linea-line word ...) form, each command head — the first
;; word, and any word following a `|` pipe — that is exactly `grep` becomes
;; `rg`, and the line is rendered back to a command string. `grep` appearing
;; as an argument (a search pattern, or `echo grep`) is left untouched, which
;; is precisely the head-vs-argument distinction the parse makes syntactic.
;;
;; Invoked by the default rewrite hook as: racket grep.rkt COMMAND
;; Prints the rewritten command on stdout and exits 0 when a `grep` head was
;; replaced. Exits non-zero otherwise — a parse failure, a word that cannot
;; be rendered faithfully, or no `grep` head to rewrite — so the caller keeps
;; the original command unchanged.
(require linea/read
         syntax/parse
         racket/string)

(define pipe-sym (string->symbol "|"))
(define grep-sym 'grep)
(define rg-sym 'rg)

(define (quote-word s)
  ;; Re-quote a string word so it round-trips as a single shell word.
  (define out (open-output-string))
  (write-char #\" out)
  (for ([c (in-string s)])
    (when (or (char=? c #\") (char=? c #\\))
      (write-char #\\ out))
    (write-char c out))
  (write-char #\" out)
  (get-output-string out))

(define (word->shell d)
  (cond
    [(symbol? d) (symbol->string d)]
    [(string? d) (quote-word d)]
    [(number? d) (number->string d)]
    [else (error 'grep "unrenderable word: ~s" d)]))

(define (rewrite-heads words)
  ;; Replace head-position `grep` with `rg`; report whether anything changed.
  (let loop ([ws words]
             [head? #t]
             [acc '()]
             [changed #f])
    (cond
      [(null? ws) (values (reverse acc) changed)]
      [else
       (define w (car ws))
       (define is-pipe (and (symbol? w) (eq? w pipe-sym)))
       (define-values (w* changed*)
         (if (and head? (eq? w grep-sym))
             (values rg-sym #t)
             (values w changed)))
       (loop (cdr ws) is-pipe (cons w* acc) changed*)])))

(define (transform command)
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (eprintf "grep: ~a\n" (exn-message e))
                     (exit 1))])
    (define stx (linea-read-syntax 'grep (open-input-string command)))
    (syntax-parse stx
      #:datum-literals (#%linea-line)
      [(#%linea-line w ...)
       (define words (syntax->datum #'(w ...)))
       (define-values (new-words changed) (rewrite-heads words))
       (unless changed
         (eprintf "grep: no grep command to rewrite\n")
         (exit 1))
       (string-join (map word->shell new-words) " ")]
      [_
       (eprintf "grep: not a command line\n")
       (exit 1)])))

(define argv (current-command-line-arguments))
(when (< (vector-length argv) 1)
  (eprintf "usage: grep.rkt COMMAND\n")
  (exit 2))
(displayln (transform (vector-ref argv 0)))
