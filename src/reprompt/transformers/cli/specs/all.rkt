#lang racket/base
;; Every bundled command interface, plus a ready-made registry over them.
(require "../main.rkt"
         "grep.rkt"
         "rg.rkt"
         "cd.rkt"
         "ls.rkt"
         "curl.rkt"
         "sed.rkt"
         "find.rkt"
         "awk.rkt"
         "mv.rkt"
         "cp.rkt"
         "launchctl.rkt"
         "systemctl.rkt"
         "wc.rkt")

(provide (all-from-out "grep.rkt" "rg.rkt" "cd.rkt" "ls.rkt" "curl.rkt"
                       "sed.rkt" "find.rkt" "awk.rkt" "mv.rkt" "cp.rkt"
                       "launchctl.rkt" "systemctl.rkt" "wc.rkt")
         all-interfaces
         default-registry)

(define all-interfaces
  (list grep-cli rg-cli cd-cli ls-cli curl-cli sed-cli
        find-cli awk-cli mv-cli cp-cli launchctl-cli systemctl-cli
        wc-cli))

(define default-registry (make-spec-registry all-interfaces))
