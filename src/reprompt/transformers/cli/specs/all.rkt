#lang racket/base
;; Every bundled command interface, plus a ready-made registry over them.
(require "../main.rkt"
         "grep.rkt"
         "rg.rkt"
         "cd.rkt"
         "ls.rkt"
         "curl.rkt"
         "sed.rkt"
         "awk.rkt"
         "launchctl.rkt"
         "systemctl.rkt"
         "wc.rkt"
         "git.rkt"
         "gh.rkt")

(provide (all-from-out "grep.rkt" "rg.rkt" "cd.rkt" "ls.rkt" "curl.rkt"
                       "sed.rkt" "awk.rkt"
                       "launchctl.rkt" "systemctl.rkt" "wc.rkt"
                       "git.rkt" "gh.rkt")
         all-interfaces
         default-registry)

(define all-interfaces
  (list grep-cli rg-cli cd-cli ls-cli curl-cli sed-cli
        awk-cli launchctl-cli systemctl-cli
        wc-cli git-cli gh-cli))

(define default-registry (make-spec-registry all-interfaces))
