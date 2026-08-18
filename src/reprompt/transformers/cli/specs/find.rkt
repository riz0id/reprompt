#lang racket/base
;; find(1) -- paths first, then an expression of primaries and operators.
;; Multi-character single-dash primaries are literal aliases, matched as
;; whole words before any short-cluster decomposition (`-name` must never
;; unbundle as `-n -a -m -e`), and every value-taking primary is repeatable
;; because expressions repeat freely (`-name a -o -name b`). Ordering among
;; primaries is preserved by the invocation's argument order.
;;
;; `-exec`/`-ok` are absent by design: their `{} \;` terminators contain
;; characters the safe reader rejects, so those commands are left untouched.
(require "../main.rkt")

(provide find-cli)

(define-command-interface find-cli
  #:names ("find")
  (flag follow-args "-H")
  (flag follow "-L")
  (flag no-follow "-P")
  (flag depth-first "-d" "-depth")
  (flag xdev "-x" "-xdev" "-mount")
  (flag print "-print")
  (flag print0 "-print0")
  (flag ls-format "-ls")
  (flag delete "-delete")
  (flag empty "-empty")
  (flag prune "-prune")
  (flag nouser "-nouser")
  (flag nogroup "-nogroup")
  (flag and-op "-a" "-and")
  (flag or-op "-o" "-or")
  (flag not-op "!" "-not")
  (option name "-name" #:repeatable)
  (option iname "-iname" #:repeatable)
  (option path-primary "-path" #:repeatable)
  (option ipath "-ipath" #:repeatable)
  (option regex "-regex" #:repeatable)
  (option iregex "-iregex" #:repeatable)
  (option type "-type" #:repeatable)
  (option size "-size" #:repeatable)
  (option mtime "-mtime" #:repeatable)
  (option mmin "-mmin" #:repeatable)
  (option atime "-atime" #:repeatable)
  (option amin "-amin" #:repeatable)
  (option ctime "-ctime" #:repeatable)
  (option cmin "-cmin" #:repeatable)
  (option newer "-newer" #:repeatable)
  (option user "-user" #:repeatable)
  (option group "-group" #:repeatable)
  (option perm "-perm" #:repeatable)
  (option links "-links" #:repeatable)
  (option inum "-inum" #:repeatable)
  (option samefile "-samefile" #:repeatable)
  (option maxdepth "-maxdepth")
  (option mindepth "-mindepth")
  (operand paths #:arity many))
