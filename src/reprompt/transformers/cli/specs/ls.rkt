#lang racket/base
;; ls(1) -- the single-letter flags BSD and GNU agree on, plus a few GNU
;; longs. Short options whose meaning diverges between the two about taking
;; a value (-w, -T, -I) are deliberately absent so they reject instead of
;; misparsing on one platform or the other.
(require (prefix-in cli: cli-spec))

(provide ls-cli)

(define ls-cli
  (cli:cmd 'ls
     (cli:flag 'all #:aliases '(-a --all))
     (cli:flag 'almost-all #:aliases '(-A --almost-all))
     (cli:flag 'long #:aliases '(-l))
     (cli:flag 'human-readable #:aliases '(-h --human-readable))
     (cli:flag 'directory #:aliases '(-d --directory))
     (cli:flag 'classify #:aliases '(-F --classify))
     (cli:flag 'slash #:aliases '(-p))
     (cli:flag 'recursive #:aliases '(-R --recursive))
     (cli:flag 'sort-size #:aliases '(-S))
     (cli:flag 'sort-time #:aliases '(-t))
     (cli:flag 'reverse #:aliases '(-r --reverse))
     (cli:flag 'access-time #:aliases '(-u))
     (cli:flag 'change-time #:aliases '(-c))
     (cli:flag 'one-per-line #:aliases '(|-1|))
     (cli:flag 'columns #:aliases '(-C))
     (cli:flag 'across #:aliases '(-x))
     (cli:flag 'commas #:aliases '(-m))
     (cli:flag 'hide-control #:aliases '(-q --hide-control-chars))
     (cli:flag 'size-blocks #:aliases '(-s --size))
     (cli:flag 'inode #:aliases '(|-i| --inode))
     (cli:flag 'numeric #:aliases '(-n --numeric-uid-gid))
     (cli:flag 'no-owner #:aliases '(-g))
     (cli:flag 'no-group-long #:aliases '(-o))
     (cli:flag 'kibibytes #:aliases '(-k))
     (cli:flag 'colorized #:aliases '(-G))
     (cli:flag 'no-sort #:aliases '(-f))
     (cli:flag 'color 'string #:aliases '(--color) #:arity '?)
     (cli:flag 'time-style 'string #:aliases '(--time-style))
     (cli:flag 'sort-by 'string #:aliases '(--sort))
     (cli:flag 'group-directories-first #:aliases '(--group-directories-first))
     (cli:arg 'paths 'string #:arity '*)))
