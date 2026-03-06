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

Lambdas capture their lexical environment at creation time. The body must be a single expression.

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

## Evaluation Model

Grasp is **strict** (call-by-value). All arguments are evaluated before function application:

```lisp
(define x (+ 1 2))  ; x is 3, not a thunk for (+ 1 2)
```

This is the default for most Lisps and is the simplest model to start with. Opt-in laziness (through real GHC THUNK closures) is a planned future feature.

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

GHC-equivalent types (Int, Double, Bool) reuse GHC's own closures — a Grasp integer IS a Haskell `Int`, with zero marshaling overhead. Grasp-specific types use Haskell ADTs whose info tables GHC generates automatically.

There is no type system. Any operation that receives an unexpected type will produce a runtime error.

## Error Handling

Errors are currently reported as Haskell exceptions caught by the REPL:

```
λ> (/ 1 0)
error: unbound symbol: /
λ> (car 42)
error: car expects a cons cell
λ> (+ 1 "hello")
error: expected two integers, got: 2 args
```

There is no user-level exception mechanism yet. The REPL catches all exceptions and continues.
