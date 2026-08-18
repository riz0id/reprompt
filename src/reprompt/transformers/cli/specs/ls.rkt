#lang racket/base
;; ls(1) -- the single-letter flags BSD and GNU agree on, plus a few GNU
;; longs. Short options whose meaning diverges between the two about taking
;; a value (-w, -T, -I) are deliberately absent so they reject instead of
;; misparsing on one platform or the other.
(require "../main.rkt")

(provide ls-cli)

(define-command-interface ls-cli
  #:names ("ls")
  (flag all "-a" "--all")
  (flag almost-all "-A" "--almost-all")
  (flag long "-l")
  (flag human-readable "-h" "--human-readable")
  (flag directory "-d" "--directory")
  (flag classify "-F" "--classify")
  (flag slash "-p")
  (flag recursive "-R" "--recursive")
  (flag sort-size "-S")
  (flag sort-time "-t")
  (flag reverse "-r" "--reverse")
  (flag access-time "-u")
  (flag change-time "-c")
  (flag one-per-line "-1")
  (flag columns "-C")
  (flag across "-x")
  (flag commas "-m")
  (flag hide-control "-q" "--hide-control-chars")
  (flag size-blocks "-s" "--size")
  (flag inode "-i" "--inode")
  (flag numeric "-n" "--numeric-uid-gid")
  (flag no-owner "-g")
  (flag no-group-long "-o")
  (flag kibibytes "-k")
  (flag colorized "-G")
  (flag no-sort "-f")
  (option color "--color" #:optional-value)
  (option time-style "--time-style")
  (option sort-by "--sort")
  (flag group-directories-first "--group-directories-first")
  (operand paths #:arity many))
