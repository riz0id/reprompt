#lang racket/base
;; find(1) -- the pre-expression surface GNU and BSD agree on: the
;; symlink-handling flags [-H|-L|-P], one starting path, and the
;; expression tail captured verbatim.
;;
;; Ground truth: GNU findutils 4.11.0 (nixpkgs; `nix run
;; nixpkgs#findutils -- --help`): `find [-H] [-L] [-P] [-Olevel]
;; [-D debugopts] [path...] [expression]`; BSD find (macOS 15):
;; `find [-H | -L | -P] [-EXdsx] [-f path] path ... [expression]`.
;;
;; The expression (`-type f`, `-name PATTERN`, `! -perm ...`,
;; `-exec ... ;`) is its own language: its primaries and operators are
;; single-dash whole words and bare punctuation, neither short nor long
;; aliases, so it is not declared flag-by-flag -- a rest clause
;; captures everything from the first path onward, uninterpreted.
;; Consequences, stated rather than hidden: the path slot holds only
;; the first path, additional paths travel at the head of the
;; expression tail; and an invocation that omits the path
;; (`find -name x`, where GNU defaults the path to `.`) does not
;; parse, because a leading `-name` reads as an unknown flag cluster.
;;
;; Deliberately omitted: -O and -D (GNU-only), and -E, -X, -d, -s, -x
;; and the valued -f (BSD-only) -- spellings the two implementations
;; do not share.
(require (prefix-in cli: cli-spec))

(provide find-cli)

(define find-cli
  (cli:cmd 'find
     (cli:flag 'follow-args #:aliases '(-H))
     (cli:flag 'follow #:aliases '(-L))
     (cli:flag 'physical #:aliases '(-P))
     (cli:arg 'path 'string)
     (cli:rest 'expression #:after 'first-positional)))
