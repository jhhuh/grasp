# Phase 7: Language Ergonomics, TCO, File Execution, Standard Library — Design

## Goal

Four features that make Grasp practical for real programs: `begin`/`let`/multi-body
lambda, `loop`/`recur` for iterative recursion, command-line file execution, and a
standard library written in Grasp.

## Feature 1: Language Ergonomics

### `begin`

`(begin e1 e2 ... en)` — evaluates forms sequentially, returns last result.

Semantics:
1. Evaluate all forms in order in the current env
2. Return the value of the last form
3. `(begin)` with no forms returns nil

Implementation: a new `eval` clause. `mapM` all expressions, return the last.

### Multi-expression lambda

`(lambda (params) e1 e2 ... en)` — body forms get implicit `begin` wrapping.

Change the lambda clause from requiring `[expr]` (exactly one body) to accepting
`(expr:rest)` (one or more). When multiple body forms exist, evaluate them as
`begin` — all but last for side effects, return last.

### `let`

`(let ((x 1) (y 2)) body...)` — sequential let bindings.

Semantics:
1. Create a child env inheriting from current env
2. For each `(name value)` pair, evaluate `value` in the child env and bind `name`
3. Evaluate body forms (with `begin` semantics) in the child env
4. Return the last body result

Note: bindings are sequential (like `let*` in Scheme), not parallel. Later
bindings can reference earlier ones. This is simpler and more useful.

## Feature 2: Tail Call Optimization — `loop`/`recur`

Clojure-style explicit loop construct.

### `loop`

```lisp
(loop ((var init) ...) body...)
```

Semantics:
1. Create a child env
2. Evaluate each `init` expression and bind `var` in the child env
3. Evaluate body forms (with `begin` semantics)
4. If body returns normally, that's the loop result
5. If body evaluates `(recur new-val ...)`, rebind vars and re-evaluate body

### `recur`

```lisp
(recur expr ...)
```

`recur` is only valid inside a `loop` body. It signals that the loop should
restart with new bindings. The number of `recur` arguments must match the
number of loop variables.

Implementation: `recur` returns a sentinel value (a new `GraspRecur` ADT).
The `loop` clause checks if the body result is `GTRecur` — if so, extracts
the new values, rebinds, and loops (Haskell `fix` or explicit recursion
with `go`). If the result is any other type, returns it.

### New type

```haskell
data GraspRecur = GraspRecur [Any]
```

With `GTRecur`, info pointer, `mkRecur`, `toRecurArgs`. The recur type
should never escape a loop — if it does, produce a clear error.

### Examples

```lisp
;; Sum 0..99
(loop ((i 0) (sum 0))
  (if (= i 100) sum
    (recur (+ i 1) (+ sum i))))
;; => 4950

;; Factorial
(define fact (lambda (n)
  (loop ((i n) (acc 1))
    (if (= i 0) acc
      (recur (- i 1) (* acc i))))))
(fact 10)  ;; => 3628800
```

## Feature 3: File Execution

`Main.hs` checks `System.Environment.getArgs`:
- No args → REPL (current behavior)
- One arg → treat as file path, read with `parseFile`, evaluate all
  expressions sequentially in the default env, exit
- Print the result of the last expression (or nothing on error)

The env is set up with `defaultEnvWithInterop` so files can use `hs:`,
modules, etc.

## Feature 4: Standard Library

A `lib/prelude.gsp` module providing common list and logic operations
written in Grasp itself:

```lisp
(module prelude
  (export map filter fold-left fold-right
          length append reverse
          not and or
          abs min max
          nth range)
  ...)
```

Functions use `loop`/`recur` for iteration where needed (depends on
Feature 2 landing first).

Not auto-loaded. Users opt in with `(import "lib/prelude.gsp")`.

Tested via a dedicated test file that loads the prelude and exercises
each function.

## What's NOT Included

- **`cond`** — can be written as a macro over `if`
- **String operations** — `hs:` already covers these
- **Full TCO** — `loop`/`recur` covers the 90% case
- **Auto-loading prelude** — explicit import keeps things simple
- **`do` notation** — not applicable to a strict Lisp

## Ordering

1. `begin` + multi-body lambda + `let` (no dependencies)
2. `loop`/`recur` (needs `begin` semantics for multi-body)
3. File execution (independent, but useful for testing stdlib)
4. Standard library (needs `loop`/`recur` for iterative functions)

## Files Changed

| Module | Changes |
|--------|---------|
| `Grasp.NativeTypes` | Add `GraspRecur` ADT, `GTRecur`, info ptr, mk/to |
| `Grasp.Eval` | Add `begin`, `let`, `loop`, `recur` special forms; multi-body lambda |
| `Grasp.Printer` | Add `GTRecur` case (error: should not be printed) |
| `Main.hs` | Add `getArgs` dispatch for file execution |
| `lib/prelude.gsp` | New: standard library module |
| Test files | Tests for all new features |

## Dependencies

- `System.Environment` (getArgs) — already in `base`
- No new package dependencies
