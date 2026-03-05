# Task 2: S-Expression Parser (TDD)

## Goal
Add a megaparsec-based S-expression parser with full test coverage.

## Steps
1. Create `src/GhcLisp/Types.hs` — AST types (LispExpr)
2. Create `test/ParserSpec.hs` — hspec tests for all atom/list/quote forms
3. Update `test/Spec.hs` — switch to hspec-discover
4. Create `src/GhcLisp/Parser.hs` — megaparsec parser
5. Update `ghc-lisp.cabal` — add new modules to both targets
6. Run `nix develop -c cabal test` — verify all tests pass
7. Commit

## Key design decisions
- Parser type: `Parsec Void Text`
- `pExpr` order: pBool | pStr | pQuote | pList | try pInt | pSym
- `try pInt` before `pSym` so `-7` parses as integer, bare `-` as symbol
- Semicolons for line comments
