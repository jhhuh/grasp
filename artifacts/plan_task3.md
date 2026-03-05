# Task 3: Core Evaluator (TDD)

## Goal
Add evaluator that converts `LispExpr` -> `LispVal`, plus a printer for `LispVal`.

## Steps
1. Modify `src/GhcLisp/Types.hs` — add `LispVal`, `Env` types + imports
2. Create `src/GhcLisp/Printer.hs` — `printVal` function
3. Create `src/GhcLisp/Eval.hs` — `eval`, `defaultEnv`, primitives
4. Create `test/EvalSpec.hs` — tests for literals, arithmetic, define, lambda, if, list ops, quote
5. Update `ghc-lisp.cabal` — add new modules to both executable and test-suite
6. Run tests — all should pass
7. Commit

## Verification
- `nix develop -c cabal test` passes all tests (parser + eval)
