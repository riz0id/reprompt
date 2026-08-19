#lang racket/base
;; Retarget rg file-discovery calls onto the filesystem MCP server.
;;
;; The translation lives in the rg->filesystem command-to-tool mapping
;; (cli/mappings/rg-filesystem.rkt); this script is only the plumbing:
;; unwrap the Bash(<command>) envelope, and when the whole call is a
;; lone in-domain rg invocation, print the equivalent
;; filesystem.search_files({...}) call. Anything else -- content
;; search, pipelines, redirects, filtered walks -- exits non-zero so
;; the caller keeps the original call and the command runs as real rg.
;;
;; Invoked by the default rewrite hook as: racket rg.rkt CALL
(require "cli/main.rkt"
         "cli/mappings/rg-filesystem.rkt")

(define argv (current-command-line-arguments))
(when (< (vector-length argv) 1)
  (eprintf "usage: rg.rkt CALL\n")
  (exit 2))
(define command (parse-bash-envelope (vector-ref argv 0)))
(unless command
  (eprintf "rg: not a Bash call\n")
  (exit 1))
(define rewritten (tool-mapping-rewrite-call rg->filesystem command))
(unless rewritten
  (eprintf "rg: no rg call to retarget\n")
  (exit 1))
(displayln rewritten)
