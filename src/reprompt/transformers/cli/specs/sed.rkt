#lang racket/base
;; sed(1) -- GNU/BSD common ground. `-i` is the attached-only optional-value
;; case (GNU `-i[SUFFIX]`, `sed -i.bak`); BSD's separate-suffix spelling
;; `sed -i '' file` still renders verbatim, the empty suffix just parses as
;; an operand. `-l` takes a value in GNU and none in BSD, so it is absent.
;; The script operand slot is active only when no -e/-f supplied a script.
(require "../main.rkt")

(provide sed-cli)

(define-command-interface sed-cli
  #:names ("sed")
  (flag quiet "-n" "--quiet" "--silent")
  (flag extended-regexp "-E" "-r" "--regexp-extended")
  (flag separate "-s" "--separate")
  (flag unbuffered "-u" "--unbuffered")
  (flag null-data "-z" "--null-data")
  (flag posix "--posix")
  (flag append-buffered "-a")
  (option expression "-e" "--expression" #:repeatable)
  (option script-file "-f" "--file" #:repeatable)
  (option in-place "-i" "--in-place" #:optional-value #:attached-only)
  (operand script #:arity one
           #:unless (lambda (inv)
                      (or (invocation-has-option? inv 'expression)
                          (invocation-has-option? inv 'script-file))))
  (operand files #:arity many))
