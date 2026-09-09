#lang racket/base

(require "mcp-spec.rkt")

(provide read-file list-directory)

(define-mcp read-file
  #:method "read_file"
  #:returns 'string
  #:doc "Read a file, optionally a line range."
  (argument 'filepath 'path)
  (argument 'start-line 'int #:optional? #t)
  (argument 'end-line 'int #:optional? #t))

(define-mcp list-directory
  #:method "list_directory"
  #:returns 'string
  #:doc "List a directory's entries."
  (argument 'directory 'dir)
  (argument 'recursive 'bool #:optional? #t #:default #f))
