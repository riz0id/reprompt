#lang racket/base

;; Every bundled MCP interface specification.

(require "filesystem.rkt")

(provide (all-from-out "filesystem.rkt")
         all-mcp-interfaces)

(define all-mcp-interfaces
  (list read-file list-directory))
