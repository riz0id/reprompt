#lang racket/base
;; git(1) -- a read-only, current-repository fragment: the status,
;; diff, show, and branch subcommands with a deliberately narrow
;; argument set.
;;
;; Ground truth: git 2.55.0 (nixpkgs; `nix shell nixpkgs#git -c git
;; status -h`, `... git diff -h`, `... git show -h`, `... git branch
;; -h`). `--staged` is documented as a synonym of `--cached` on diff;
;; `-r`/`--remotes` and `-a`/`--all` are branch's listing selectors.
;;
;; Deliberately omitted, so commands using them reject: every other
;; subcommand; every global option (`-C`, `-c`, `--no-pager`, ...); and
;; every subcommand option not listed above (e.g. `status -s` and
;; `branch -v` change the output format, `diff --stat` replaces the
;; patch, `branch --contains` filters). Operand slots cover only a
;; single positional per subcommand: diff's optional TARGET and show's
;; optional REV; a second positional (a pathspec, a second revision)
;; rejects at parse.
(require (prefix-in cli: cli-spec)
         "../main.rkt")

(provide git-cli)

(define git-cli
  (command->interface
   (cli:cmd 'git
     (cli:subcommand 'status)
     (cli:subcommand 'diff
       (cli:flag 'staged #:aliases '(--staged --cached))
       (cli:arg 'target 'string #:arity '?))
     (cli:subcommand 'show
       (cli:arg 'revision 'string #:arity '?))
     (cli:subcommand 'branch
       (cli:flag 'remotes #:aliases '(-r --remotes))
       (cli:flag 'all #:aliases '(-a --all))))))
