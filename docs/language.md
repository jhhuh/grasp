# Language Reference

Grasp is a dynamically-typed, strict Lisp dialect with S-expression syntax. It runs on GHC's runtime system with a CBPV-aware evaluator that distinguishes computation and transaction modes.

## Syntax

### Atoms

| Syntax | Type | Examples |
|--------|------|----------|
| Integers | 64-bit fixed-width (`Int`) | `42`, `-7`, `0` |
| Doubles | IEEE 754 | `3.14`, `-0.5` |
| Strings | Double-quoted | `"hello"`, `"with \"escapes\""` |
| Booleans | Hash-prefixed | `#t`, `#f` |
| Symbols | Unquoted identifiers | `foo`, `+`, `null?`, `my-var` |

Symbol characters include everything except `( ) " # ;` and whitespace. Operators like `+`, `-`, `*`, `<`, `>`, `=` and names like `null?` are all valid symbols.

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

Returns nil.

### `lambda`

Creates an anonymous function (closure):

```lisp
(lambda (x) (* x x))
(lambda (x y) (+ x y))
```

Lambdas capture their lexical environment. The body may contain multiple expressions (implicit `begin`):

```lisp
(lambda (x)
  (define y (* x x))
  (+ y 1))
```

### `if`

Conditional evaluation:

```lisp
(if (> x 0) "positive" "non-positive")
```

Only `#f` is falsy. Everything else (including `0`, `""`, `()`) is truthy. Lazy values are auto-forced before testing.

### `quote`

Returns its argument unevaluated:

```lisp
(quote foo)       ; => foo
(quote (1 2 3))   ; => (1 2 3)
```

The `'expr` reader syntax desugars to `(quote expr)` during parsing.

### `begin`

Evaluates a sequence of expressions, returns the last:

```lisp
(begin
  (define x 1)
  (define y 2)
  (+ x y))         ; => 3

(begin)             ; => ()
```

### `let`

Creates sequential bindings in a child environment, then evaluates the body:

```lisp
(let (x 10
      y (* x 2))  ; y sees x — bindings are sequential (like Scheme's let*)
  (+ x y))        ; => 30
```

The body supports multiple expressions (implicit `begin`).

### `loop` / `recur`

Clojure-style explicit tail recursion. `loop` establishes bindings and a restart point; `recur` jumps back with new values:

```lisp
(loop (i 0 sum 0)
  (if (> i 10)
    sum
    (recur (+ i 1) (+ sum i))))   ; => 55
```

`recur` is only valid inside `loop`. The number of `recur` arguments must match the number of loop bindings.

### `lazy` / `force`

Opt-in laziness via real GHC THUNK closures:

```lisp
(define x (lazy (+ 1 2)))  ; x is a THUNK, not 3
(force x)                   ; => 3 (evaluated, result cached)
(force x)                   ; => 3 (cached, not re-evaluated)
```

`(lazy expr)` creates a real GHC THUNK on the heap via `unsafeInterleaveIO`. GHC's standard update mechanism replaces the thunk with an indirection on first force.

Primitives and control flow auto-force lazy arguments:

```lisp
(+ (lazy 10) (lazy 20))     ; => 30 (auto-forced)
(if (lazy #t) "yes" "no")   ; => "yes" (auto-forced)
```

### `atomically`

Enters transaction mode (STM). Inside an `atomically` block, IO-only primitives (`spawn`, `make-chan`, `chan-put`, `chan-get`) are rejected:

```lisp
(define tv (make-tvar 0))
(atomically
  (write-tvar tv 42))
(read-tvar tv)  ; => 42
```

Nested `atomically` is an error. This enforces the CBPV discipline: transactions compose, but cannot perform irreversible IO.

### `defmacro`

Defines a macro that receives unevaluated arguments as quoted data:

```lisp
(defmacro when (cond body)
  (list 'if cond body '()))

(when (> x 0) (display "positive"))
; expands to: (if (> x 0) (display "positive") ())
```

The macro body returns a value (built with `list`, `quote`, etc.), which is converted back to an expression and re-evaluated in the caller's environment.

## Primitive Functions

### Arithmetic

| Function | Signature | Description |
|----------|-----------|-------------|
| `+` | `Int -> Int -> Int` | Addition |
| `-` | `Int -> Int -> Int` | Subtraction |
| `*` | `Int -> Int -> Int` | Multiplication |
| `div` | `Int -> Int -> Int` | Integer division |

All arithmetic operates on integers. Non-integer arguments produce a runtime error.

```lisp
(+ 1 2)       ; => 3
(- 10 3)      ; => 7
(* 6 7)       ; => 42
(div 10 3)    ; => 3
```

### Comparison

| Function | Signature | Description |
|----------|-----------|-------------|
| `=` | `a -> a -> Bool` | Structural equality |
| `<` | `Int -> Int -> Bool` | Less than |
| `>` | `Int -> Int -> Bool` | Greater than |

`=` compares values structurally. Two cons cells are equal if their cars and cdrs are equal. Functions are never equal.

### List Operations

| Function | Signature | Description |
|----------|-----------|-------------|
| `list` | `a... -> List` | Construct a list from arguments |
| `cons` | `a -> b -> Cons` | Create a cons cell |
| `car` | `Cons -> a` | First element |
| `cdr` | `Cons -> b` | Rest |
| `null?` | `a -> Bool` | Test if value is nil |

```lisp
(list 1 2 3)         ; => (1 2 3)
(cons 1 (list 2 3))  ; => (1 2 3)
(car (list 1 2 3))   ; => 1
(cdr (list 1 2 3))   ; => (2 3)
(null? '())          ; => #t
(cons 1 2)           ; => (1 . 2)  — improper list
```

### STM

| Function | Signature | Description |
|----------|-----------|-------------|
| `make-tvar` | `a -> TVar` | Create a transactional variable |
| `read-tvar` | `TVar -> a` | Read current value |
| `write-tvar` | `TVar -> a -> ()` | Write a value |

TVars are GHC STM `TVar` values. `read-tvar` and `write-tvar` work in both computation and transaction modes. Use `atomically` to compose multiple TVar operations into an atomic transaction.

```lisp
(define tv (make-tvar 0))
(atomically (write-tvar tv 42))
(read-tvar tv)  ; => 42
```

### Concurrency

| Function | Signature | Description |
|----------|-----------|-------------|
| `spawn` | `(() -> a) -> ()` | Fork a green thread |
| `make-chan` | `() -> Chan` | Create a channel |
| `chan-put` | `Chan -> a -> ()` | Write to channel |
| `chan-get` | `Chan -> a` | Read from channel (blocks) |

These are IO-only -- rejected inside `atomically`.

```lisp
(define ch (make-chan))
(spawn (lambda () (chan-put ch (* 6 7))))
(chan-get ch)  ; => 42
```

### IO

| Function | Signature | Description |
|----------|-----------|-------------|
| `error` | `a -> !` | Throw an error |
| `display` | `a -> ()` | Print a value (no newline) |
| `newline` | `() -> ()` | Print a newline |

## Types at Runtime

Every Grasp value is `GraspVal` (alias for `Any` from `GHC.Exts`) -- an untyped pointer to a GHC heap closure. Type discrimination uses `unpackClosure#` to read info-table addresses.

| GHC closure | Grasp type | Printed as |
|-------------|------------|------------|
| `I# n` | Int | `42` |
| `D# d` | Double | `3.14` |
| `True` | Bool | `#t` |
| `False` | Bool | `#f` |
| `GraspSym s` | Symbol | `foo` |
| `GraspStr s` | String | `"hello"` |
| `GraspCons a d` | Cons | `(1 2 3)` or `(1 . 2)` |
| `GraspNil` | Nil | `()` |
| `GraspLambda` | Lambda | `<lambda>` |
| `GraspPrim` | Primitive | `<primitive:+>` |
| `GraspLazy` | Lazy | `<lazy>` |
| `GraspMacro` | Macro | `<macro>` |
| `GraspChan` | Chan | `<chan>` |
| `GraspModule` | Module | `<module:name>` |
| `GraspRecur` | Recur | (internal) |
| `GraspPromptTag` | PromptTag | `<prompt-tag>` |
| `GraspTVar` | TVar | `<tvar>` |

GHC-equivalent types (Int, Double, Bool) reuse GHC's own closures with zero marshaling. Grasp-specific types use Haskell ADTs whose info tables GHC generates automatically. There is no static type system -- any operation that receives an unexpected type produces a runtime error.

## CBPV Modes

The evaluator carries an `EvalMode` that partitions effects:

- **ModeComputation** -- unrestricted IO. All primitives available. This is the default mode.
- **ModeTransaction** -- STM only. IO-only primitives are rejected. Entered via `(atomically body)`. Nested `atomically` is an error.

This enforces the CBPV discipline at runtime: transactions compose (you can combine STM blocks into larger atomic operations), but cannot perform irreversible IO (which would break rollback). Pure value operations and STM primitives work in both modes.

## Evaluation Model

Grasp is **strict** (call-by-value). All arguments are evaluated before function application:

```lisp
(define x (+ 1 2))  ; x is 3, not a thunk for (+ 1 2)
```

Opt-in laziness via `lazy`/`force` creates real GHC THUNKs. A lazy value prints as `<lazy>` without forcing.

### Environments

Environments are mutable `IORef EnvData` values. `define` mutates the environment in place. Lambdas capture a reference to their defining environment. `let`, `loop`, and `lambda` application create child environments that inherit from the parent.

## Error Handling

The REPL catches all Haskell exceptions and continues:

```
grasp> (car 42)
error: car expects a cons cell
grasp> (+ 1 "hello")
error: expected two integers, got: 2 args
```
