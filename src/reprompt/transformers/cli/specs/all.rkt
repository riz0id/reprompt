#lang racket/base
;; Every bundled command interface specification.
(require "grep.rkt"
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
         "wc.rkt"
         "git.rkt"
         "gh.rkt")

(provide (all-from-out "grep.rkt" "rg.rkt" "cd.rkt" "ls.rkt" "curl.rkt"
                       "sed.rkt" "find.rkt" "awk.rkt" "mv.rkt" "cp.rkt"
                       "launchctl.rkt" "systemctl.rkt" "wc.rkt"
                       "git.rkt" "gh.rkt")
         all-interfaces)

(define all-interfaces
  (list grep-cli rg-cli cd-cli ls-cli curl-cli sed-cli
        find-cli awk-cli mv-cli cp-cli launchctl-cli systemctl-cli
        wc-cli git-cli gh-cli))
