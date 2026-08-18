#lang racket/base
;; Command lines over safe words: pipelines, connectors, and redirects.
;;
;; A parsed line is a sequence of pipelines joined by `&&` / `||` connectors,
;; each pipeline a sequence of stages joined by `|`, plus an optional trailing
;; `&`. Within a stage, redirect words (`>`, `>>`, `<`, `2>`, `2>&1`, `&>`,
;; and their attached-target forms like `>out.txt`) are shell syntax, not
;; command arguments: they are peeled into stage-redirects so a command
;; interface never sees them and an unknown-argument policy never falsely
;; rejects `grep foo f > out`. On render the redirects are re-emitted after
;; the stage's argument words, in their original relative order -- for a
;; simple command that placement is semantically equivalent wherever the
;; redirect appeared.
;;
;; A `&` anywhere but the very end of the line separates commands the way `;`
;; does, so it is rejected rather than misread as an argument.
(require racket/string
         "words.rkt")

(provide (struct-out cmd-line)
         (struct-out pipeline)
         (struct-out stage)
         parse-line
         render-line
         stage-head
         map-stages)

;; connectors: the `&&` / `||` words between pipelines, in order
;; trailing: '() or the final `&` word
(struct cmd-line (pipelines connectors trailing) #:transparent)
(struct pipeline (stages) #:transparent)
;; words: argument words, head first; redirects: (listof (listof word))
(struct stage (words redirects) #:transparent)

(define (self-contained-redirect? l)
  (or (regexp-match? #px"^[0-9]*>&([0-9]+|-)$" l)
      (regexp-match? #px"^[0-9]*<&([0-9]+|-)$" l)))

(define (needs-target-redirect? l)
  (or (regexp-match? #px"^[0-9]*(>>|>|<)$" l)
      (regexp-match? #px"^&>>?$" l)))

(define (attached-target-redirect? l)
  (or (regexp-match? #px"^[0-9]*(>>|>|<).+$" l)
      (regexp-match? #px"^&>>?.+$" l)))

(define (split-stage ws)
  ;; Argument words and redirect groups for one stage; reject on a dangling
  ;; redirect operator or a stage with no command word.
  (let loop ([ws ws] [args '()] [redirects '()])
    (cond
      [(null? ws)
       (if (null? args)
           (reject "empty pipeline stage")
           (stage (reverse args) (reverse redirects)))]
      [else
       (define w (car ws))
       (define l (word-logical w))
       (cond
         [(self-contained-redirect? l)
          (loop (cdr ws) args (cons (list w) redirects))]
         [(needs-target-redirect? l)
          (if (null? (cdr ws))
              (reject "redirect without target")
              (loop (cddr ws) args (cons (list w (cadr ws)) redirects)))]
         [(attached-target-redirect? l)
          (loop (cdr ws) args (cons (list w) redirects))]
         [else
          (loop (cdr ws) (cons w args) redirects)])])))

(define (split-on ws delimiter?)
  ;; Word groups separated by delimiter words, with the delimiters.
  (let loop ([ws ws] [group '()] [groups '()] [delims '()])
    (cond
      [(null? ws) (values (reverse (cons (reverse group) groups)) (reverse delims))]
      [(delimiter? (word-logical (car ws)))
       (loop (cdr ws) '() (cons (reverse group) groups) (cons (car ws) delims))]
      [else (loop (cdr ws) (cons (car ws) group) groups delims)])))

(define (build-pipeline ws)
  (define-values (groups _delims) (split-on ws (lambda (l) (equal? l "|"))))
  (let loop ([groups groups] [stages '()])
    (cond
      [(null? groups) (pipeline (reverse stages))]
      [else
       (define st (split-stage (car groups)))
       (if (reject? st) st (loop (cdr groups) (cons st stages)))])))

(define (parse-line source)
  ;; string -> cmd-line | reject
  (define ws (safe-read-line source))
  (cond
    [(reject? ws) ws]
    [else
     (define-values (body trailing)
       (let ([rev (reverse ws)])
         (if (and (pair? rev) (equal? "&" (word-logical (car rev))))
             (values (reverse (cdr rev)) (list (car rev)))
             (values ws '()))))
     (cond
       [(for/or ([w (in-list body)]) (equal? "&" (word-logical w)))
        (reject "& separates commands")]
       [else
        (define-values (groups connectors)
          (split-on body (lambda (l) (member l '("&&" "||")))))
        (let loop ([groups groups] [pipelines '()])
          (cond
            [(null? groups)
             (cmd-line (reverse pipelines) connectors trailing)]
            [else
             (define pl (build-pipeline (car groups)))
             (if (reject? pl)
                 pl
                 (loop (cdr groups) (cons pl pipelines)))]))])]))

(define (stage-render-words st)
  (append (stage-words st) (apply append (stage-redirects st))))

(define (render-line cl)
  (define (render-pipeline pl)
    (string-join (map (lambda (st) (render-words (stage-render-words st)))
                      (pipeline-stages pl))
                 " | "))
  (string-join
   (append
    (let loop ([pls (cmd-line-pipelines cl)] [cs (cmd-line-connectors cl)] [acc '()])
      (cond
        [(null? pls) (reverse acc)]
        [(null? cs) (reverse (cons (render-pipeline (car pls)) acc))]
        [else (loop (cdr pls) (cdr cs)
                    (cons (word-raw (car cs))
                          (cons (render-pipeline (car pls)) acc)))]))
    (map word-raw (cmd-line-trailing cl)))
   " "))

(define (stage-head st)
  ;; Logical text of the stage's command word, #f for an empty stage.
  (if (null? (stage-words st))
      #f
      (word-logical (car (stage-words st)))))

(define (map-stages cl proc)
  ;; Apply proc to every stage; proc returns a new stage or #f (unchanged).
  ;; -> (values cmd-line changed?)
  (define changed #f)
  (define new-cl
    (cmd-line
     (for/list ([pl (in-list (cmd-line-pipelines cl))])
       (pipeline
        (for/list ([st (in-list (pipeline-stages pl))])
          (define st* (proc st))
          (cond
            [(stage? st*) (set! changed #t) st*]
            [else st]))))
     (cmd-line-connectors cl)
     (cmd-line-trailing cl)))
  (values new-cl changed))
