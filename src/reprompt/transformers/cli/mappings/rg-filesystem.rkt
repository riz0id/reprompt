#lang racket/base
;; rg(1) file-discovery mode -> the filesystem MCP server's search_files
;; tool.
;;
;; The claimed fragment is deliberately narrow: rg with --files (list
;; files, no content search) plus --hidden and --no-ignore -- the server
;; walks with no hidden-file or ignore-rule filtering, so only the
;; unfiltered rg walk can match it -- with at most one slash-free,
;; non-negated glob (server matching is by base name) and at most one
;; path operand in directory spelling. Everything else, above all
;; content search, has no counterpart on the server and rejects, so the
;; command runs as real rg.

(require "../main.rkt"
         "../specs/rg.rkt"
         "../tools/filesystem.rkt")

(provide rg->filesystem)

(define (dir-spelling? v)
  (or (member v '("." "..")) (regexp-match? #rx"/$" v)))

(define (in-domain? inv)
  (and (invocation-has-flag? inv 'files)
       (invocation-has-flag? inv 'hidden)
       (invocation-has-flag? inv 'no-ignore)
       (let ([gs (invocation-option-values inv 'glob)])
         (and (<= (length gs) 1)
              (for/and ([g (in-list gs)])
                (and (string? g)
                     (positive? (string-length g))
                     (not (regexp-match? #rx"^!" g))
                     (not (regexp-match? #rx"/" g))))))
       (let ([ps (invocation-operands inv 'paths)])
         (and (<= (length ps) 1)
              (for/and ([p (in-list ps)]) (dir-spelling? p))))))

(define-command-tool-mapping rg->filesystem
  #:from rg-cli
  #:to   filesystem-mcp
  #:domain in-domain?
  (tool "search_files"
        #:consumes (files hidden no-ignore)
        (param path #:from-operand paths #:default ".")
        (param pattern #:from-option glob #:default "*")))
