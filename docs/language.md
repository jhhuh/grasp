# Language Reference

Grasp is a dynamically-typed, strict Lisp dialect with S-expression syntax. It runs on GHC's runtime system.

## Syntax

### Atoms

| Syntax | Type | Examples |
|--------|------|----------|
| Integers | Arbitrary-precision | `42`, `-7`, `0` |
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

Quoted lists become cons-cell chains at runtime. `'(1 2 3)` produces `(LCons 1 (LCons 2 (LCons 3 LNil)))`.

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

Grasp can call compiled Haskell functions using the `hs:` prefix syntax:

```lisp
(hs:succ 41)              ; => 42
(hs:negate 5)             ; => -5
(hs:reverse (list 1 2 3)) ; => (3 2 1)
(hs:length (list 1 2 3))  ; => 3
```

The legacy `haskell-call` form is also supported:

```lisp
(haskell-call "succ" 41)  ; => 42
```

### Type validation

Each registered Haskell function has type metadata. Grasp validates argument types before calling:

```
λ> (hs:succ "hello")
error: succ: expected Int, got String
λ> (hs:reverse 42)
error: reverse: expected List[Int], got Int
```

### Safe evaluation

Haskell functions that throw exceptions do not crash the process. The RTS bridge builds thunks in C (via `rts_apply`) but forces them in Haskell using `try`/`evaluate`, catching exceptions safely.

### How it works

Functions are dispatched through a typed registry (`HsFuncRegistry`). Two calling conventions are supported:

**RTS bridge (Int -> Int functions):** `succ` and `negate` go through the C bridge. A `StablePtr` is created once at registry construction. Each call uses `grasp_build_int_app` in C to build a thunk via `rts_apply`, then forces it safely in Haskell.

**Haskell-side marshaling (list functions):** `reverse` and `length` marshal Grasp cons lists to Haskell `[Int]`, call the function directly, and marshal back.

### Supported functions

| Function | Input | Output | Calling convention |
|----------|-------|--------|--------------------|
| `succ` | Int | Int | RTS bridge |
| `negate` | Int | Int | RTS bridge |
| `reverse` | List[Int] | List[Int] | Haskell marshaling |
| `length` | List[Int] | Int | Haskell marshaling |

## Evaluation Model

Grasp is **strict** (call-by-value). All arguments are evaluated before function application:

```lisp
(define x (+ 1 2))  ; x is 3, not a thunk for (+ 1 2)
```

This is the default for most Lisps and is the simplest model to start with. Opt-in laziness (through real GHC THUNK closures) is a planned future feature.

### Environments

Environments are mutable `IORef EnvData` values carrying both a symbol table (`Map Text LispVal`) and a Haskell function registry (`HsFuncRegistry`). Each lambda creates a child environment that inherits from its closure's environment:

```lisp
(define x 10)
(define f (lambda (y) (+ x y)))
(f 5)       ; => 15, looks up x in parent env
(define x 20)
(f 5)       ; => 15, closure captured the env ref
```

Note: because environments are `IORef`s, `define` mutates the environment in place. A lambda captures a reference to its defining environment, so subsequent `define`s in that environment are visible to the lambda.

## Types at Runtime

Every Grasp value is a `LispVal`:

| Constructor | Description | Printed as |
|-------------|-------------|------------|
| `LInt n` | Arbitrary-precision integer | `42` |
| `LDouble d` | Double-precision float | `3.14` |
| `LSym s` | Symbol | `foo` |
| `LStr s` | String | `"hello"` |
| `LBool b` | Boolean | `#t` / `#f` |
| `LCons a d` | Cons cell | `(1 2 3)` or `(1 . 2)` |
| `LNil` | Empty list / nil | `()` |
| `LFun` | Lambda closure | `<lambda>` |
| `LPrimitive` | Built-in function | `<primitive:+>` |

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
