#lang racket/base
;; Surface syntax for tool interfaces.
;;
;;   (define-tool-interface filesystem-mcp
;;     #:server "filesystem"
;;     (tool "read_file" (param path #:required))
;;     (tool "search_files"
;;           (param path #:required)
;;           (param pattern #:required)))
;;
;; A thin macro over the runtime constructors in tool-spec.rkt --
;; validation lives there once; the macro checks the statically visible
;; shape so mistakes surface as syntax errors pointing at the offending
;; clause.

(require (for-syntax racket/base
                     syntax/parse)
         "tool-spec.rkt")

(provide define-tool-interface)

(begin-for-syntax
  (define-syntax-class param-clause
    #:datum-literals (param)
    #:attributes (expr)
    (pattern (param id:id
                    (~alt (~optional (~and #:required required))
                          (~optional (~seq #:values (val:str ...+))))
                    ...)
      #:attr req (if (attribute required) #'#t #'#f)
      #:with expr #'(make-param 'id
                                #:required? req
                                #:values (~? (list val ...) #f))))

  (define-syntax-class tool-clause
    #:datum-literals (tool)
    #:attributes (expr)
    (pattern (tool name:str p:param-clause ...)
      #:with expr #'(make-tool name (list p.expr ...)))))

(define-syntax (define-tool-interface stx)
  (syntax-parse stx
    [(_ name:id #:server server:str t:tool-clause ...)
     #'(define name
         (make-tool-interface #:server server
                              #:tools (list t.expr ...)))]))
