#lang racket/base
;; Surface syntax for command-to-tool mappings.
;;
;;   (define-command-tool-mapping rg->filesystem
;;     #:from rg-cli
;;     #:to   filesystem-mcp
;;     #:domain in-domain?
;;     (tool "search_files"
;;           #:consumes (files hidden no-ignore)
;;           (param path #:from-operand paths #:default ".")
;;           (param pattern #:from-option glob #:default "*")))
;;
;; A thin macro over the runtime constructors in tool-mapping.rkt --
;; validation lives there once; the macro checks the statically visible
;; shape so mistakes surface as syntax errors pointing at the offending
;; clause. Domain predicates are defined before the mapping form
;; (#:domain is evaluated at definition time).

(require (for-syntax racket/base
                     syntax/parse)
         "tool-mapping.rkt")

(provide define-command-tool-mapping)

(begin-for-syntax
  (define-syntax-class binding-clause
    #:datum-literals (param)
    #:attributes (expr)
    (pattern (param id:id #:const value:str)
      #:with expr #'(param-binding 'id 'const value #f #f #f))
    (pattern (param id:id #:from-option src:id
                    (~alt (~optional (~seq #:default default:str))
                          (~optional (~seq #:forward fwd:expr))
                          (~optional (~seq #:witness wit:expr)))
                    ...)
      #:with expr #'(param-binding 'id 'option 'src
                                   (~? fwd #f) (~? wit #f)
                                   (~? default #f)))
    (pattern (param id:id #:from-operand src:id
                    (~optional (~seq #:default default:str)))
      #:with expr #'(param-binding 'id 'operand 'src #f #f
                                   (~? default #f))))

  (define-syntax-class tool-case-clause
    #:datum-literals (tool)
    #:attributes (expr)
    (pattern (tool name:str
                   (~alt (~optional (~seq #:consumes (consumed:id ...)))
                         (~optional (~seq #:when guard:expr)))
                   ...
                   b:binding-clause ...)
      #:with expr #'(tool-case name
                               (~? guard #f)
                               (~? (list 'consumed ...) '())
                               (list b.expr ...)))))

(define-syntax (define-command-tool-mapping stx)
  (syntax-parse stx
    [(_ name:id #:from from:expr #:to to:expr
        (~optional (~seq #:domain domain:expr))
        c:tool-case-clause ...+)
     #'(define name
         (make-command-tool-mapping
          #:from from
          #:to to
          #:cases (list c.expr ...)
          #:domain (~? (lambda (inv) (domain inv)) #f)))]))
