#lang racket/base
;; cp(1) -- BSD flags plus the GNU long spellings and target-directory
;; options.
;;
;; Ground truth: GNU coreutils (nixpkgs; `nix shell nixpkgs#coreutils -c
;; cp --help`); BSD cp (macOS 15) shares the short spellings declared
;; here except -u and -t/-T. Deliberately omitted: GNU-only -b, -d, -Z,
;; --sparse, --parents, --debug, and friends; BSD-only -c, -N, -X.
;;
;; Operands are one 'many slot, the same back-anchored shape as mv
;; (`cp SRC... DEST`): the slot holds all path words and a consumer
;; draws the boundary itself (the last word is the destination, unless
;; -t names it and all words are sources).
(require (prefix-in cli: cli-spec))

(provide cp-cli)

(define cp-cli
  (cli:cmd 'cp
     (cli:flag 'recursive #:aliases '(-r -R --recursive))
     (cli:flag 'force #:aliases '(-f --force))
     (cli:flag 'interactive #:aliases '(|-i| --interactive))
     (cli:flag 'no-clobber #:aliases '(-n --no-clobber))
     (cli:flag 'verbose #:aliases '(-v --verbose))
     (cli:flag 'archive #:aliases '(-a --archive))
     (cli:flag 'preserve-attrs #:aliases '(-p))
     (cli:flag 'no-dereference #:aliases '(-P --no-dereference))
     (cli:flag 'dereference #:aliases '(-L --dereference))
     (cli:flag 'dereference-args #:aliases '(-H))
     (cli:flag 'link #:aliases '(-l --link))
     (cli:flag 'symbolic-link #:aliases '(-s --symbolic-link))
     (cli:flag 'update #:aliases '(-u))
     (cli:flag 'one-file-system #:aliases '(-x --one-file-system))
     (cli:flag 'no-target-directory #:aliases '(-T --no-target-directory))
     (cli:flag 'target-directory 'string #:aliases '(-t --target-directory))
     (cli:flag 'suffix 'string #:aliases '(-S --suffix))
     (cli:flag 'backup (cli:enum "none" "off" "numbered" "t" "existing"
                                 "nil" "simple" "never")
               #:aliases '(--backup) #:arity '?)
     (cli:flag 'preserve 'string #:aliases '(--preserve) #:arity '?)
     (cli:flag 'reflink (cli:enum "always" "auto" "never")
               #:aliases '(--reflink) #:arity '?)
     (cli:arg 'args 'string #:arity '*)))
