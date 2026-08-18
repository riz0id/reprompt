#lang racket/base
;; Safe linea parse: the fidelity foundation of the cli library.
;;
;; A command string is read with the linea reader into a (#%linea-line w ...)
;; form, and each word is captured together with its exact source substring,
;; recovered from the word's syntax position and span. Rendering an untouched
;; word emits that raw slice verbatim, so reader normalization (007 -> 7,
;; 1e3 -> 1000.0) can never corrupt a rewrite.
;;
;; The linea reader silently mangles several shell constructs: `;` truncates
;; the rest of the line as a comment, single quotes and backticks read as
;; Racket quote forms that can swallow following words, backslash escapes are
;; consumed, and parens/brackets/braces become nested structure. safe-read-line
;; therefore layers three guards, and any failure yields a `reject` value
;; rather than a corrupted word list:
;;   1. a source scan that refuses the characters the reader mangles, applied
;;      outside double-quoted regions (inside a string the reader is faithful,
;;      except that only the \" and \\ escapes mean the same thing in shell);
;;   2. a datum-shape check accepting only symbol/string/number/boolean words;
;;   3. a structural coverage check: word srclocs must be strictly ordered and
;;      non-overlapping with whitespace-only gaps, and must cover the input to
;;      its end -- which mechanically catches `;` truncation, swallowed words,
;;      and embedded newlines. A zero-width gap marks two tokens the reader
;;      split inside one shell word (--flag="v w" reads as `--flag=` plus the
;;      string) and the pair is rejoined into a single word.
(require linea/read)

(provide (struct-out word)
         (struct-out reject)
         safe-read-line
         quote-word
         text->word
         render-words)

;; raw     : exact substring of the source command
;; logical : the text the program would receive (symbol/string content)
;; quoted? : whether a double-quoted string contributed to the word
(struct word (raw logical quoted?) #:transparent)

;; Universal failure value: library functions reject, they never corrupt.
(struct reject (why) #:transparent)

;; Characters the linea reader mangles outside of double-quoted strings.
(define banned-chars
  (list #\' #\` #\# #\; #\\ #\( #\) #\[ #\] #\{ #\} #\« #\»))

(define (scan-source s)
  ;; #f when the source is safe to hand to the linea reader, a reject
  ;; otherwise. Tracks double-quoted regions: inside them only the \" and \\
  ;; escapes agree between Racket and shell, so anything else is refused.
  (define len (string-length s))
  (let loop ([i 0] [in-string #f])
    (cond
      [(>= i len)
       (if in-string (reject "unterminated string") #f)]
      [else
       (define c (string-ref s i))
       (cond
         [in-string
          (cond
            [(char=? c #\") (loop (add1 i) #f)]
            [(char=? c #\\)
             (if (and (< (add1 i) len)
                      (memv (string-ref s (add1 i)) '(#\" #\\)))
                 (loop (+ i 2) #t)
                 (reject "string escape with different shell meaning"))]
            [else (loop (add1 i) #t)])]
         [(char=? c #\") (loop (add1 i) #t)]
         [(memv c banned-chars)
          (reject (format "unsupported shell construct: ~a" c))]
         [else (loop (add1 i) #f)])])))

(define (datum->logical d raw)
  ;; The text the command would receive for one word datum, or #f when the
  ;; datum is not a shape a shell word can take.
  (cond
    [(symbol? d) (symbol->string d)]
    [(string? d) d]
    [(number? d) raw]
    [(boolean? d) raw]
    [else #f]))

(define (whitespace-only? s from to)
  (for/and ([i (in-range from to)])
    (char-whitespace? (string-ref s i))))

(define (collect-words source stxs)
  ;; Words with raw slices, enforcing order, coverage, and zero-gap rejoin.
  (define len (string-length source))
  (let loop ([stxs stxs] [prev-end 0] [acc '()])
    (cond
      [(null? stxs)
       (if (whitespace-only? source prev-end len)
           (reverse acc)
           (reject "line not fully parsed"))]
      [else
       (define stx (car stxs))
       (define pos (syntax-position stx))
       (define span (syntax-span stx))
       (cond
         [(not (and pos span)) (reject "word without source location")]
         [else
          (define start (sub1 pos))
          (define end (+ start span))
          (cond
            [(or (< start prev-end) (> end len))
             (reject "overlapping source locations")]
            [else
             (define raw (substring source start end))
             (define logical (datum->logical (syntax->datum stx) raw))
             (cond
               [(not logical) (reject (format "unrenderable word: ~s" (syntax->datum stx)))]
               [(and (pair? acc) (= start prev-end))
                ;; Zero-width gap: the reader split one shell word in two.
                (define w (car acc))
                (loop (cdr stxs) end
                      (cons (word (string-append (word-raw w) raw)
                                  (string-append (word-logical w) logical)
                                  (or (word-quoted? w) (string? (syntax->datum stx))))
                            (cdr acc)))]
               [(whitespace-only? source prev-end start)
                (loop (cdr stxs) end
                      (cons (word raw logical (string? (syntax->datum stx))) acc))]
               [else (reject "unparsed text between words")])])])])))

(define (safe-read-line source)
  ;; string -> (listof word) | reject
  (define scanned (scan-source source))
  (cond
    [(reject? scanned) scanned]
    [else
     (with-handlers ([exn:fail? (lambda (e) (reject (exn-message e)))])
       (define stx (linea-read-syntax 'cli (open-input-string source)))
       (cond
         [(eof-object? stx) (reject "empty command")]
         [else
          (define parts (syntax->list stx))
          (cond
            [(or (not parts)
                 (null? parts)
                 (not (eq? '#%linea-line (syntax->datum (car parts)))))
             (reject "not a command line")]
            [else (collect-words source (cdr parts))])]))]))

(define (quote-word s)
  ;; Re-quote a string so it round-trips as a single shell word.
  (define out (open-output-string))
  (write-char #\" out)
  (for ([c (in-string s)])
    (when (or (char=? c #\") (char=? c #\\))
      (write-char #\\ out))
    (write-char c out))
  (write-char #\" out)
  (get-output-string out))

(define (bare-safe? s)
  ;; Text that renders as a bare word whose raw slice survives a re-parse.
  (and (positive? (string-length s))
       (for/and ([c (in-string s)])
         (or (char-alphabetic? c)
             (char-numeric? c)
             (memv c '(#\- #\_ #\. #\/ #\: #\= #\@ #\% #\^ #\+ #\, #\~ #\*))))))

(define (text->word s)
  ;; Synthesize a word for text produced by an edit; quoted unless bare-safe.
  (if (bare-safe? s)
      (word s s #f)
      (word (quote-word s) s #t)))

(define (render-words ws)
  ;; Raw slices joined by single spaces.
  (let loop ([ws ws] [acc '()])
    (cond
      [(null? ws) (apply string-append (reverse acc))]
      [(null? (cdr ws)) (loop (cdr ws) (cons (word-raw (car ws)) acc))]
      [else (loop (cdr ws) (cons " " (cons (word-raw (car ws)) acc)))])))
