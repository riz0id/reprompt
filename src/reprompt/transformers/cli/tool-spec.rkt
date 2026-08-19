#lang racket/base
;; The tool-interface model: what an MCP server's tools look like.
;;
;; A tool interface names a configured backend server and declares its
;; tools, each with parameter ids, required markers, and optional
;; enumerated value vocabularies -- the target-side analogue of
;; spec.rkt's command interfaces, so a command-to-tool mapping can
;; target keyword ids on both sides. Specs are authored at development
;; time, so constructor validation failures raise.

(provide (struct-out tool-interface)
         (struct-out tool-spec)
         (struct-out param-spec)
         make-param
         make-tool
         make-tool-interface
         tool-interface-find-tool
         tool-find-param)

;; server: the backend name as configured in reprompt.yaml
(struct tool-interface (server tools) #:transparent)
;; name: the tool's wire name (a string); params in declared order
(struct tool-spec (name params) #:transparent)
;; values: #f for free-form, or the list of valid value strings
(struct param-spec (id required? values) #:transparent)

(define (check-duplicates who what items)
  (let loop ([items items] [seen '()])
    (cond
      [(null? items) (void)]
      [(member (car items) seen)
       (error who "duplicate ~a: ~s" what (car items))]
      [else (loop (cdr items) (cons (car items) seen))])))

(define (make-param id #:required? [required? #f] #:values [values #f])
  (unless (symbol? id)
    (error 'make-param "parameter id must be a symbol: ~s" id))
  (when values
    (unless (and (list? values) (pair? values) (andmap string? values))
      (error 'make-param "parameter ~a: #:values must be a list of strings" id))
    (check-duplicates 'make-param "enumerated value" values))
  (param-spec id required? values))

(define (make-tool name params)
  (unless (and (string? name) (positive? (string-length name)))
    (error 'make-tool "tool name must be a non-empty string: ~s" name))
  (check-duplicates 'make-tool "parameter id" (map param-spec-id params))
  (tool-spec name params))

(define (make-tool-interface #:server server #:tools tools)
  (unless (and (string? server) (positive? (string-length server)))
    (error 'make-tool-interface "server must be a non-empty string: ~s" server))
  (check-duplicates 'make-tool-interface "tool name" (map tool-spec-name tools))
  (tool-interface server tools))

(define (tool-interface-find-tool ti name)
  (for/or ([t (in-list (tool-interface-tools ti))])
    (and (equal? name (tool-spec-name t)) t)))

(define (tool-find-param ts id)
  (for/or ([p (in-list (tool-spec-params ts))])
    (and (eq? id (param-spec-id p)) p)))
