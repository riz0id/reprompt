#lang racket/base
;; Tool-call envelopes for syntax transformers.
;;
;; The default rewrite hook hands each transformer the enclosing tool
;; call rendered as Bash(<command>), and a transformer answers with one
;; call form: Bash(<command>) to stay a shell call, or
;; <server>.<tool>(<json-object>) to retarget the call onto an MCP
;; backend tool. Envelope parsing is textual -- parentheses lie outside
;; the safe reader's language, so the envelope is stripped before the
;; inner command ever reaches words.rkt.

(require racket/string)

(provide parse-bash-envelope
         render-bash-call
         render-mcp-call)

(define (parse-bash-envelope call)
  ;; The inner command of a Bash(<command>) envelope, or #f.
  (define m (regexp-match #px"(?s:^Bash\\((.*)\\)$)" call))
  (and m (cadr m)))

(define (render-bash-call command)
  (string-append "Bash(" command ")"))

(define (json-string s)
  ;; A JSON string literal for plain text: the two escapes that matter
  ;; for the generated value language, plus control-character safety.
  (define out (open-output-string))
  (write-char #\" out)
  (for ([c (in-string s)])
    (cond
      [(char=? c #\") (write-string "\\\"" out)]
      [(char=? c #\\) (write-string "\\\\" out)]
      [(char<? c #\space)
       (write-string "\\u" out)
       (write-string (substring (number->string (+ #x10000 (char->integer c)) 16) 1) out)]
      [else (write-char c out)]))
  (write-char #\" out)
  (get-output-string out))

(define (render-mcp-call server tool params)
  ;; params: (listof (cons string string)), rendered as a JSON object
  ;; with keys in sorted order so the same call always renders the same
  ;; bytes.
  (define sorted (sort params string<? #:key car))
  (string-append
   server "." tool
   "({"
   (string-join (for/list ([p (in-list sorted)])
                  (string-append (json-string (car p)) ":"
                                 (json-string (cdr p))))
                ",")
   "})"))
