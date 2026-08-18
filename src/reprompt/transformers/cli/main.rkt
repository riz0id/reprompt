#lang racket/base
;; The cli library's public surface. Transformers require this file (plus
;; the specs they use) and nothing else.
(require "words.rkt"
         "line.rkt"
         "spec.rkt"
         "parse.rkt"
         "invocation.rkt"
         "dsl.rkt"
         "mapping.rkt"
         "mapping-dsl.rkt")

(provide (all-from-out "words.rkt")
         (all-from-out "line.rkt")
         (all-from-out "spec.rkt")
         (all-from-out "parse.rkt")
         (all-from-out "invocation.rkt")
         (all-from-out "dsl.rkt")
         (all-from-out "mapping.rkt")
         (all-from-out "mapping-dsl.rkt")
         transform-line)

(define (transform-line source registry proc)
  ;; Rewrite every stage whose head has an interface in the registry and
  ;; parses against it, keeping the stage's redirects. proc takes the
  ;; interface and the parsed invocation and returns a new invocation, or #f
  ;; to leave the stage alone. -> rewritten command string, or #f when
  ;; nothing changed or the line was rejected.
  (define cl (parse-line source))
  (cond
    [(reject? cl) #f]
    [else
     (define-values (cl* changed)
       (map-stages
        cl
        (lambda (st)
          (define spec (registry-lookup registry (stage-head st)))
          (define inv (and spec (parse-invocation spec (stage-words st))))
          (define inv* (and (invocation? inv) (proc spec inv)))
          (and (invocation? inv*)
               (stage (invocation-words inv*) (stage-redirects st))))))
     (and changed (render-line cl*))]))
