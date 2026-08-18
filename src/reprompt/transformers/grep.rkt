#lang racket/base
;; Rewrite `grep` invocations as `rg`, preserving meaning, not just the head.
;;
;; The translation itself lives in the grep->rg command mapping
;; (cli/mappings/grep-rg.rkt) -- an explicit inter-interface specification
;; between the grep and rg command interfaces (cli/specs/grep.rkt,
;; cli/specs/rg.rkt). This script is only the plumbing: parse each
;; pipeline stage whose head is grep/egrep/fgrep against the grep
;; interface, run the mapping, and keep the original command whenever the
;; mapping rejects -- a grep it does not fully understand is never
;; half-translated.
;;
;; Invoked by the default rewrite hook as: racket grep.rkt COMMAND
;; Prints the rewritten command on stdout and exits 0 when a stage was
;; rewritten; exits non-zero otherwise so the caller keeps the original.
(require "cli/main.rkt"
         "cli/specs/grep.rkt"
         "cli/mappings/grep-rg.rkt")

(define registry (make-spec-registry (list grep-cli)))

(define argv (current-command-line-arguments))
(when (< (vector-length argv) 1)
  (eprintf "usage: grep.rkt COMMAND\n")
  (exit 2))
(define rewritten
  (transform-line (vector-ref argv 0) registry (mapping->transformer grep->rg)))
(unless rewritten
  (eprintf "grep: no grep command to rewrite\n")
  (exit 1))
(displayln rewritten)
