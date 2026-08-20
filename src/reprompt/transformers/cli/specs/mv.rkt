#lang racket/base
;; mv(1) -- BSD flags plus the GNU long spellings and -t/-T/-S/--backup.
;;
;; Ground truth: GNU coreutils (nixpkgs; `nix shell nixpkgs#coreutils -c
;; mv --help`); BSD mv (macOS 15) shares -f/-i/-n/-v. Deliberately
;; omitted: BSD-only -h; GNU-only -b, -u/--update, -Z/--context,
;; --debug, --exchange, --no-copy, --strip-trailing-slashes.
;;
;; Operands are one 'many slot: mv's grammar back-anchors the
;; destination (`mv SRC... DEST`), a required-positional-after-variadic
;; shape cli-spec's deterministic matching rejects, so the slot holds
;; all path words and a consumer draws the boundary itself (the last
;; word is the destination, unless -t names it and all words are
;; sources).
(require (prefix-in cli: cli-spec))

(provide mv-cli)

(define mv-cli
  (cli:cmd 'mv
     (cli:flag 'force #:aliases '(-f --force))
     (cli:flag 'interactive #:aliases '(|-i| --interactive))
     (cli:flag 'no-clobber #:aliases '(-n --no-clobber))
     (cli:flag 'verbose #:aliases '(-v --verbose))
     (cli:flag 'no-target-directory #:aliases '(-T --no-target-directory))
     (cli:flag 'target-directory 'string #:aliases '(-t --target-directory))
     (cli:flag 'suffix 'string #:aliases '(-S --suffix))
     (cli:flag 'backup (cli:enum "none" "off" "numbered" "t" "existing"
                                 "nil" "simple" "never")
               #:aliases '(--backup) #:arity '?)
     (cli:arg 'args 'string #:arity '*)))
