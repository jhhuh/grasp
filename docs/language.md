# Language Reference

Grasp is a dynamically-typed, strict Lisp dialect with S-expression syntax. It runs on GHC's runtime system.

## Syntax

### Atoms

| Syntax | Type | Examples |
|--------|------|----------|
| Integers | 64-bit fixed-width (`Int`) | `42`, `-7`, `0` |
| Doubles | IEEE 754 | `3.14`, `-0.5` |
| Strings | Double-quoted | `"hello"`, `"with \"escapes\""` |
| Booleans | Hash-prefixed | `#t`, `#f` |
| Symbols | Unquoted identifiers | `foo`, `+`, `null?`, `my-var` |

Symbol characters include everything except `( ) " # ; ` and whitespace. This means operators like `+`, `-`, `*`, `<`, `>`, `=` and names like `null?`, `haskell-call` are all valid symbols.

### Lists

Parenthesized sequences of expressions:

```lisp
(+ 1 2)
(list 1 2 3)
(define x 42)
```

### Comments

Line comments start with `;`:

```lisp
; This is a comment
(+ 1 2) ; inline comment
```

### Quoting

The quote form prevents evaluation:

```lisp
(quote (1 2 3))   ; => (1 2 3)
'(1 2 3)          ; => (1 2 3) — shorthand
'foo               ; => foo (a symbol, not looked up)
```

Quoted lists become cons-cell chains at runtime. `'(1 2 3)` produces a chain of `GraspCons` closures terminated by `GraspNil`.

## Special Forms

Special forms are syntactic constructs handled directly by the evaluator, not as function application.

### `define`

Binds a value in the current environment:

```lisp
(define x 42)
(define square (lambda (x) (* x x)))
```

`define` evaluates the body, then mutates the environment to insert the binding. Returns the bound value.

### `lambda`

Creates an anonymous function (closure):

```lisp
(lambda (x) (* x x))
(lambda (x y) (+ x y))
```

Lambdas capture their lexical environment at creation time. The body may contain multiple expressions, which are evaluated sequentially (implicit `begin`):

```lisp
(lambda (x)
  (define y (* x x))
  (+ y 1))
```

Single-expression lambdas work as before:

```lisp
(define make-adder (lambda (n) (lambda (x) (+ n x))))
(define add5 (make-adder 5))
(add5 10)  ; => 15
```

### `if`

Conditional evaluation:

```lisp
(if (> x 0) "positive" "non-positive")
```

The condition is evaluated first. If it returns `#f`, the else-branch is evaluated. For **any other value** (including `0`, `""`, and `()`), the then-branch is evaluated. Only `#f` is falsy.

### `quote`

Returns its argument unevaluated:

```lisp
(quote foo)       ; => foo
(quote (1 2 3))   ; => (1 2 3)
```

The `'expr` reader syntax desugars to `(quote expr)` during parsing.

### `begin`

Evaluates a sequence of expressions and returns the value of the last one:

```lisp
(begin
  (define x 1)
  (define y 2)
  (+ x y))         ; => 3

(begin)             ; => ()
```

`(begin)` with no body expressions returns nil. Multi-expression lambda bodies and `let` bodies use implicit `begin` semantics.

### `let`

Creates sequential bindings in a child environment, then evaluates the body:

```lisp
(let ((x 10)
      (y (* x 2)))  ; y sees x — bindings are sequential (like Scheme's let*)
  (+ x y))          ; => 30
```

Each binding is evaluated in order, and later bindings can reference earlier ones. The body supports multiple expressions (implicit `begin`):

```lisp
(let ((x 1))
  (define y 2)
  (+ x y))         ; => 3
```

### `loop` / `recur`

Clojure-style explicit tail recursion. `loop` establishes bindings and a restart point; `recur` jumps back with new values:

```lisp
(loop ((i 0) (sum 0))
  (if (> i 10)
    sum
    (recur (+ i 1) (+ sum i))))   ; => 55
```

`recur` evaluates its arguments, then re-binds the loop variables and re-executes the body. It is only valid inside `loop` — using `recur` outside produces an error. The number of `recur` arguments must match the number of loop bindings.

`loop` body supports multiple expressions (implicit `begin`):

```lisp
(loop ((n 1) (acc 1))
  (if (> n 5)
    acc
    (recur (+ n 1) (* acc n))))   ; => 120 (5!)
```

### `with-handler` / `signal`

A delimited-continuation condition system using GHC's `prompt#` and `control0#` primops:

```lisp
(with-handler
  (lambda (condition restart)
    ;; condition: the signaled value
    ;; restart: calling it resumes from the signal point
    (if (= condition 'division-by-zero)
      (restart 0)        ; (signal ...) returns 0, body continues
      condition))        ; don't restart, with-handler returns this
  body)

(signal value)  ; raise a condition to the nearest handler
```

The handler receives two arguments: the signaled value and a restart function. If the handler calls `(restart v)`, evaluation resumes from the signal point with `v` as the return value. If the handler returns without calling restart, `with-handler` returns the handler's value and the body is abandoned.

Haskell exceptions (from `error` calls) are also caught and forwarded to the handler with a non-resumable restart.

```lisp
;; Catch division errors
(with-handler (lambda (c r) "caught") (car 42))  ; => "caught"

;; Nested handlers
(with-handler (lambda (c r) (+ c 1000))
  (with-handler (lambda (c r) (r (+ c 10)))
    (+ 1 (signal 5))))  ; => 16
```

### `match`

Structural pattern matching:

```lisp
(match expr
  (0 "zero")                    ; literal match
  ((cons h t) (list 'head h))  ; destructure cons
  (() "empty")                  ; nil match
  (#t "true")                  ; boolean match
  (_ "wildcard")               ; match anything, don't bind
  (x (list 'other x)))        ; variable bind (catchall)
```

Patterns are tried top-to-bottom. The first match wins. No match produces an error.

Pattern types:
- **Literal**: `0`, `"hello"`, `#t`, `#f` — match by equality
- **Nil**: `()` — match empty list
- **Cons**: `(cons head tail)` — destructure a cons cell
- **Wildcard**: `_` — match anything, don't bind
- **Variable**: bare symbol — match anything, bind to name

## Primitive Functions

### Arithmetic

| Function | Signature | Description |
|----------|-----------|-------------|
| `+` | `Int -> Int -> Int` | Addition |
| `-` | `Int -> Int -> Int` | Subtraction |
| `*` | `Int -> Int -> Int` | Multiplication |
| `div` | `Int -> Int -> Int` | Integer division |

All arithmetic operates on integers. Applying an arithmetic primitive to non-integer arguments is an error.

```lisp
(+ 1 2)       ; => 3
(- 10 3)      ; => 7
(* 6 7)       ; => 42
(div 10 3)    ; => 3
(+ -1 -2)     ; => -3
```

### Comparison

| Function | Signature | Description |
|----------|-----------|-------------|
| `=` | `a -> a -> Bool` | Structural equality |
| `<` | `Int -> Int -> Bool` | Less than |
| `>` | `Int -> Int -> Bool` | Greater than |

`=` compares values structurally. Two cons cells are equal if their cars and cdrs are equal. Functions are never equal. `<` and `>` work only on integers.

```lisp
(= 1 1)       ; => #t
(= 1 2)       ; => #f
(< 1 2)       ; => #t
(> 3 1)       ; => #t
(= '(1 2) '(1 2))  ; => #t
```

### List Operations

| Function | Signature | Description |
|----------|-----------|-------------|
| `list` | `a... -> List` | Construct a list from arguments |
| `cons` | `a -> b -> Cons` | Create a cons cell |
| `car` | `Cons -> a` | First element of a cons cell |
| `cdr` | `Cons -> b` | Rest of a cons cell |
| `null?` | `a -> Bool` | Test if value is nil |

Lists are built from cons cells terminated by nil `()`:

```lisp
(list 1 2 3)         ; => (1 2 3)
(cons 1 (list 2 3))  ; => (1 2 3)
(car (list 1 2 3))   ; => 1
(cdr (list 1 2 3))   ; => (2 3)
(null? '())          ; => #t
(null? (list 1))     ; => #f
```

Improper lists (where cdr is not a list) print with dot notation:

```lisp
(cons 1 2)  ; => (1 . 2)
```

### Function Application

| Function | Signature | Description |
|----------|-----------|-------------|
| `apply` | `Fn -> List -> a` | Call a function with arguments from a list |

```lisp
(apply + (list 1 2))             ; => 3
(apply (lambda (x y) (+ x y)) (list 10 20))  ; => 30
```

### Debugging / Introspection

| Function | Signature | Description |
|----------|-----------|-------------|
| `type-of` | `a -> String` | Returns the type name as a string |
| `inspect` | `a -> List` | Returns closure info (type, pointer count, non-pointer count) |
| `gc-stats` | `() -> List` | Returns GC statistics as an association list |

```lisp
(type-of 42)              ; => "Int"
(type-of (lambda (x) x))  ; => "Lambda"
(inspect 42)              ; => (type "Int" pointers 0 non-pointers 1)
(gc-stats)                ; => (collections N bytes-allocated N max-live-bytes N)
```

`gc-stats` requires `+RTS -T` to enable statistics collection. Without it, returns an error message.

## Haskell Interop

Grasp can call any Haskell function at runtime using the `hs:` prefix syntax:

```lisp
(hs:succ 41)                         ; => 42
(hs:negate 5)                        ; => -5
(hs:reverse (list 1 2 3))            ; => (3 2 1)
(hs:abs -5)                          ; => 5
(hs:not #f)                          ; => #t
(hs:Data.List.sort (list 3 1 2))     ; => (1 2 3)
(hs:Data.List.nub (list 1 2 1 3 2))  ; => (1 2 3)
```

The `hs:` prefix checks a static registry of pre-registered functions first (zero overhead), then falls back to the GHC API for dynamic lookup. Dynamic lookups are cached after the first call.

### Annotated form (`hs@`)

For polymorphic functions or functions with unsupported types, use `hs@` with an explicit type annotation:

```lisp
(hs@ "Data.List.sort :: [Int] -> [Int]" (list 3 1 2))  ; => (1 2 3)
(hs@ "reverse :: [Int] -> [Int]" (list 1 2 3))         ; => (3 2 1)
(hs@ "(+) :: Int -> Int -> Int" 10 32)                  ; => 42
```

The string argument is a Haskell expression with a type signature. The GHC API compiles it and uses the annotated type for marshaling decisions.

### Supported types for dynamic lookup

| GHC Type | Grasp Type | Marshaling | Notes |
|----------|-----------|------------|-------|
| `Int` | Integer | None (native I#) | Zero cost |
| `Double` | Double | None (native D#) | Zero cost |
| `Bool` | Boolean | None (native) | Zero cost |
| `[a]` | Cons chain | Marshal cons↔list | `a` must be supported |
| `String` | String | Text↔[Char] | Via `T.pack`/`T.unpack` |

Types not in this table produce an error suggesting the `hs@` form.

### Legacy form

The `haskell-call` form is also supported:

```lisp
(haskell-call "succ" 41)  ; => 42
```

### Type validation

Registered functions have type metadata. Grasp validates argument types before calling:

```
λ> (hs:succ "hello")
error: succ: expected Int, got String
```

### How it works

Three dispatch paths exist:

**Static registry (fast path):** Pre-registered functions (`succ`, `negate`, `reverse`, `length`) are looked up in a `Map`. For `Int -> Int` functions, the C bridge builds thunks via `rts_apply`; list functions marshal cons chains to Haskell lists.

**Dynamic GHC API (fallback):** On registry miss, a lazy-initialized GHC API session (`runGhc`) infers the function's type via `exprType`, compiles it via `compileExpr`, marshals arguments, applies the compiled closure, and marshals the result back. The compiled closure and type info are cached.

**Annotated (`hs@`):** The expression string includes a type annotation. The GHC API compiles it directly, using the annotated type for marshaling.

## Macros

### `defmacro`

Defines a macro — a function that receives unevaluated arguments and returns code:

```lisp
(defmacro when (cond body)
  (list 'if cond body '()))

(when (> x 0) (print "positive"))
; expands to: (if (> x 0) (print "positive") ())
```

Macro arguments are **not evaluated** before being passed to the macro body. Instead,
they are quoted — converted to runtime data (cons cells, symbols, literals) that the
macro body can inspect and rearrange using standard list operations (`list`, `cons`,
`car`, `cdr`).

The macro body returns a value (typically built with `list` and `quote`), which is
then converted back to an expression and evaluated in the caller's environment.

```lisp
(defmacro double (x) (list '+ x x))
(double (+ 1 2))  ; expands to (+ (+ 1 2) (+ 1 2)) => 6
```

A macro value prints as `<macro>`.

## Modules

### `module`

Defines a module with explicit exports:

```lisp
(module math
  (export square cube)

  (define square (lambda (x) (* x x)))
  (define cube (lambda (x) (* x (square x))))
  (define helper (lambda (x) (+ x 1)))  ; not exported
)
```

The module body is evaluated in a fresh environment inheriting the caller's
primitives. Only symbols listed in `(export ...)` are accessible from outside.
A module value prints as `<module:name>`.

### `import`

Loads a module from a file:

```lisp
(import math)              ; loads math.gsp from current directory
(import "./lib/utils.gsp") ; explicit path
```

Import binds all exported symbols both qualified and unqualified:

```lisp
(import math)
(square 5)       ; => 25 (unqualified)
(math.square 5)  ; => 25 (qualified)
```

Modules are cached after first load — importing the same module twice reuses
the cached version. Circular dependencies are detected and produce an error.

## Concurrency

Grasp provides green threads and channels for concurrent programming. Threads are real GHC green threads scheduled by GHC's native scheduler.

### `spawn`

Spawns a new green thread running the given zero-argument function:

```lisp
(spawn (lambda () (+ 1 2)))  ; runs in background, returns ()
```

`spawn` returns `()` immediately. The spawned thread runs concurrently. Exceptions in spawned threads are silently caught — use channels to communicate results or errors back.

### `make-chan`, `chan-put`, `chan-get`

Channels provide typed, blocking communication between threads:

```lisp
(define ch (make-chan))
(spawn (lambda () (chan-put ch (* 6 7))))
(chan-get ch)  ; => 42 (blocks until value is available)
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `make-chan` | `() -> Chan` | Create a new channel |
| `chan-put` | `Chan -> a -> ()` | Write a value to the channel |
| `chan-get` | `Chan -> a` | Read a value (blocks until available) |

A channel value prints as `<chan>`.

## Evaluation Model

Grasp is **strict** (call-by-value). All arguments are evaluated before function application:

```lisp
(define x (+ 1 2))  ; x is 3, not a thunk for (+ 1 2)
```

### Opt-in Laziness

Individual expressions can be deferred with `lazy`:

```lisp
(define x (lazy (+ 1 2)))  ; x is a THUNK, not 3
(force x)                   ; => 3 (evaluated, result cached)
(force x)                   ; => 3 (cached, not re-evaluated)
```

`(lazy expr)` creates a real GHC THUNK closure on the heap. The thunk is not evaluated until explicitly forced. GHC's standard update mechanism replaces the thunk with an indirection on first force, so subsequent accesses return the cached value.

Primitives and Haskell interop auto-force lazy arguments:

```lisp
(+ (lazy 10) (lazy 20))     ; => 30 (auto-forced)
(hs:succ (lazy 41))          ; => 42 (auto-forced)
(if (lazy #t) "yes" "no")   ; => "yes" (auto-forced)
```

A lazy value prints as `<lazy>` without forcing it.

### Environments

Environments are mutable `IORef EnvData` values carrying both a symbol table (`Map Text GraspVal`) and a Haskell function registry (`HsFuncRegistry`). Each lambda creates a child environment that inherits from its closure's environment:

```lisp
(define x 10)
(define f (lambda (y) (+ x y)))
(f 5)       ; => 15, looks up x in parent env
(define x 20)
(f 5)       ; => 15, closure captured the env ref
```

Note: because environments are `IORef`s, `define` mutates the environment in place. A lambda captures a reference to its defining environment, so subsequent `define`s in that environment are visible to the lambda.

## Types at Runtime

Every Grasp value is a `GraspVal` (alias for `Any` from `GHC.Exts`) — an untyped pointer to a GHC heap closure. Type discrimination uses `unpackClosure#` to read info-table addresses at runtime.

| GHC closure | Grasp type | Printed as |
|-------------|------------|------------|
| `I# n` | 64-bit integer | `42` |
| `D# d` | Double-precision float | `3.14` |
| `True` / `False` | Boolean | `#t` / `#f` |
| `GraspSym s` | Symbol | `foo` |
| `GraspStr s` | String | `"hello"` |
| `GraspCons a d` | Cons cell | `(1 2 3)` or `(1 . 2)` |
| `GraspNil` | Empty list / nil | `()` |
| `GraspLambda` | Lambda closure | `<lambda>` |
| `GraspPrim` | Built-in function | `<primitive:+>` |
| `GraspLazy` | Lazy thunk | `<lazy>` |
| `GraspMacro` | Macro | `<macro>` |
| `GraspChan` | Channel | `<chan>` |
| `GraspModule` | Module | `<module:name>` |
| `GraspRecur` | Recur (internal) | error if printed |
| `GraspPromptTag` | Prompt tag (internal) | `<prompt-tag>` |

GHC-equivalent types (Int, Double, Bool) reuse GHC's own closures — a Grasp integer IS a Haskell `Int`, with zero marshaling overhead. Grasp-specific types use Haskell ADTs whose info tables GHC generates automatically.

There is no type system. Any operation that receives an unexpected type will produce a runtime error.

## Error Handling

### Condition System

Grasp has a condition system built on GHC's delimited continuation primops. See `with-handler` and `signal` in Special Forms.

The prelude provides convenience wrappers:

```lisp
(import "lib/prelude.gsp")

;; try: wraps a thunk, returns (error condition) on signal
(try (lambda () (signal 42)))     ; => (error 42)
(try (lambda () (+ 1 2)))         ; => 3

;; catch: like try but with custom handler
(catch (lambda () (signal 42))
       (lambda (c r) (r 0)))      ; => 0 (restart with 0)
```

### REPL Error Recovery

The REPL catches all Haskell exceptions and continues:

```
λ> (car 42)
error: car expects a cons cell
λ> (+ 1 "hello")
error: expected two integers, got: 2 args
```
