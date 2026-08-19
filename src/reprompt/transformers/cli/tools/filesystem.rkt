#lang racket/base
;; The filesystem MCP server (the reference server-filesystem, mounted
;; under the backend name "filesystem"): the fragment of its tool
;; interface that command mappings target. Like the command specs, this
;; is deliberately partial -- array- and number-typed parameters
;; (excludePatterns, head/tail) are omitted from the declared tools
;; because the parameter model is string-valued, and undeclared tools
;; simply cannot be targeted by a mapping.
(require "../tool-spec.rkt"
         "../tool-dsl.rkt")

(provide filesystem-mcp)

(define-tool-interface filesystem-mcp
  #:server "filesystem"
  (tool "search_files"
        (param path #:required)
        (param pattern #:required))
  (tool "list_directory"
        (param path #:required))
  (tool "read_text_file"
        (param path #:required))
  (tool "get_file_info"
        (param path #:required)))
