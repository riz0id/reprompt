#lang racket/base
;; gh(1), the GitHub CLI -- a listing fragment: `gh issue list`,
;; `gh pr list` (alias `ls`), and `gh api user`.
;;
;; Ground truth: gh 2.97.0 (nixpkgs; `nix shell nixpkgs#gh -c gh issue
;; list --help`, `... gh pr list --help`, `... gh api --help`).
;;
;; gh nests subcommands two deep and cli-spec nests arbitrarily, so
;; `issue list` and `pr list` are real nested subcommands (with `ls` as
;; a subcommand alias that parses verbatim but names the canonical
;; `issue list` path), and api's `user` endpoint is the one nested word
;; this fragment claims -- any other endpoint is an unknown subcommand
;; and rejects.
;;
;; Deliberately omitted, so commands using them reject: every other gh
;; command; every other issue/pr list flag
;; (`--label` and friends filter, `--json`/`--jq`/`--template` change
;; the output, `--limit` is numeric, `--web` opens a browser); and all
;; of api's flags and non-"user" endpoints. `-R`/`--repo` takes the
;; full `[HOST/]OWNER/REPO` (or URL) spelling. The state enumerations
;; are gh's own (issues: open|closed|all; prs: open|closed|merged|all).
(require (prefix-in cli: cli-spec))

(provide gh-cli)

(define gh-cli
  (cli:cmd 'gh
     (cli:subcommand 'issue
       (cli:subcommand 'list #:aliases '(ls)
         (cli:flag 'repo 'string #:aliases '(-R --repo))
         (cli:flag 'state (cli:enum "open" "closed" "all")
                   #:aliases '(-s --state))))
     (cli:subcommand 'pr
       (cli:subcommand 'list #:aliases '(ls)
         (cli:flag 'repo 'string #:aliases '(-R --repo))
         (cli:flag 'state (cli:enum "open" "closed" "merged" "all")
                   #:aliases '(-s --state))))
     (cli:subcommand 'api
       (cli:subcommand 'user))))
