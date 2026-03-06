# Macro System — Design

## Goal

Add `(defmacro name (params) body)` that defines user macros operating on quoted
runtime values. Macros receive unevaluated arguments as cons cells/symbols, return
code as data, and the evaluator re-evaluates the expansion.

## Architecture

Grasp macros follow the traditional Lisp model: code is data, macros are functions
that transform data before evaluation.

### Data Flow

```
eval env (EList (fn : args))
  1. eval fn → value v
  2. graspTypeOf v == GTMacro?
     YES:
       a. Quote each arg via evalQuote → [Any]
       b. Apply macro body to quoted args → Any (the expansion)
       c. anyToExpr expansion → LispExpr
       d. eval env expandedExpr
     NO:
       eval each arg, apply as before
```

### Why eval-time expansion

A separate macro-expansion pass adds pipeline complexity and requires the macro
environment to be available before evaluation begins. Since Grasp is interpreted
(tree-walking), expanding at eval time is simpler: when `eval` sees a call where
the function resolves to a `GraspMacro`, it quotes the arguments, calls the macro
body, converts the result back to `LispExpr`, and evals the expansion. No new
pipeline stage needed.

## Macro Representation

A new ADT, mirroring `GraspLambda`:

```haskell
data GraspMacro = GraspMacro [Text] LispExpr Env
```

With corresponding infrastructure:
- `GTMacro` added to `GraspType`
- `macroInfoPtr` sentinel for type discrimination
- `mkMacro`, `toMacroParts` constructor/extractor
- `showGraspType GTMacro = "Macro"`
- Printer: `GTMacro -> "<macro>"`

Macros are stored in regular `envBindings`, just like lambdas. The evaluator
distinguishes them by `graspTypeOf` when deciding how to apply.

## Syntax

```lisp
(defmacro when (cond body)
  (list 'if cond body '()))

(when (> x 0) (print "positive"))
; expands to: (if (> x 0) (print "positive") ())
```

- `defmacro` is a special form (handled by pattern match in `eval`)
- Parameters receive unevaluated arguments as quoted `Any` values
- Body is a single expression evaluated in the macro's closure environment
- The return value (cons cells, symbols, literals) is the expansion

## The `anyToExpr` Function

The critical bridge: converts runtime `Any` values back to `LispExpr` for
re-evaluation.

```haskell
anyToExpr :: Any -> LispExpr
anyToExpr v = case graspTypeOf v of
  GTInt       -> EInt (fromIntegral (toInt v))
  GTDouble    -> EDouble (toDouble v)
  GTBoolTrue  -> EBool True
  GTBoolFalse -> EBool False
  GTSym       -> ESym (toSym v)
  GTStr       -> EStr (toStr v)
  GTNil       -> EList []
  GTCons      -> EList (consToList v)
  _           -> error $ "cannot use " <> showGraspType (graspTypeOf v)
                       <> " as code in macro expansion"
```

`consToList` walks the cdr chain collecting `[LispExpr]`. Improper lists
(where cdr is not nil or cons) produce an error, since `LispExpr` has no
dotted-pair representation.

## Macro Application

```haskell
applyMacro :: Any -> [Any] -> Env -> IO Any
```

Identical to lambda application: bind params to quoted args in a child
environment, evaluate the body. The only difference from `apply` is that
args are already quoted (not evaluated), and the result is code (not a
final value).

## Eval Changes

The function application clause changes from:

```haskell
eval env (EList (fn : args)) = do
  f <- eval env fn
  vals <- mapM (eval env) args
  apply f vals
```

To:

```haskell
eval env (EList (fn : args)) = do
  f <- eval env fn
  f' <- forceIfLazy f
  case graspTypeOf f' of
    GTMacro -> do
      quotedArgs <- mapM evalQuote args
      let (params, body, closure) = toMacroParts f'
      let bindings = Map.fromList (zip params quotedArgs)
      parentEd <- readIORef closure
      childEnv <- newIORef $ parentEd { envBindings = Map.union bindings (envBindings parentEd) }
      expansion <- eval childEnv body
      eval env (anyToExpr expansion)
    _ -> do
      vals <- mapM (eval env) args
      apply f' vals
```

Key points:
- Special forms (`define`, `lambda`, `if`, `lazy`, `force`, `hs@`, `hs:`)
  are matched before this clause, so macros cannot shadow them
- The expansion is evaluated in the **caller's** environment (`env`), not the
  macro's closure — this is standard Lisp macro semantics
- The macro body is evaluated in the macro's closure environment (with params
  bound to quoted args)

## Printing

```haskell
GTMacro -> "<macro>"
```

A macro prints as `<macro>` without expansion.

## Error Handling

- `anyToExpr` on non-data values (lambda, primitive, lazy, macro) throws
  a clear error: "cannot use Lambda as code in macro expansion"
- Improper lists in expansion throw: "improper list in macro expansion"
- Wrong arity in defmacro body throws the same errors as lambda

## What's NOT Included

- **Quasiquote/unquote** (`` ` `` and `,`) — ergonomic but adds parser
  complexity. Follow-up work.
- **Hygienic macros** — prevents variable capture but significantly more
  complex. Premature for current stage.
- **`macroexpand`** — a debugging form that shows expansion without
  evaluating. Nice-to-have, easy to add later.
- **Recursive macro expansion** — the expansion result is evaluated, not
  re-expanded. If a macro expands into another macro call, the second
  macro is expanded naturally during eval (since eval checks for macros).
  This gives us recursive expansion for free without explicit re-expansion.

## Files Changed

| Module | Status | Changes |
|--------|--------|---------|
| `Grasp.NativeTypes` | MODIFY | Add `GraspMacro`, `GTMacro`, info ptr, mkMacro, toMacroParts |
| `Grasp.Eval` | MODIFY | Add `defmacro` special form, macro expansion in apply, `anyToExpr` |
| `Grasp.Printer` | MODIFY | Add `GTMacro -> "<macro>"` |
| Test files | MODIFY | Add macro tests |

## Dependencies

No new dependencies. Everything builds on existing infrastructure.
