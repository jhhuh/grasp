# Dynamic Function Lookup — Design

## Goal

Call any compiled Haskell function by name at runtime, with automatic type
inference for monomorphic functions and explicit annotation for polymorphic ones.
Eliminate the need to pre-register functions in a static registry.

## Architecture

A lazy-initialized GHC API session (`runGhc`) provides two core operations:

1. **`exprType`** — queries the type of a Haskell expression, returning a GHC
   `Type` that we decompose with `splitFunTys` to learn arity and argument types.

2. **`compileExpr`** — compiles a Haskell expression to `HValue` (which IS `Any`
   = `GraspVal`), giving us the function closure directly on the GHC heap.

Since Grasp values are native GHC closures (Phase 1), functions operating on
native types (Int, Double, Bool) can be applied with zero marshaling via
`unsafeCoerce`. Marshaling is only needed at boundaries where Grasp and Haskell
representations differ (lists, strings).

The existing static registry remains as a fast path — `hs:succ` checks the
registry first (zero overhead), then falls back to GHC API lookup (cached after
first call).

## Key Decisions

1. **GHC API directly** (not `hint`) — maximum control, same dependency (`ghc`
   package), direct access to `Type` representations for auto-inference.

2. **Lazy GHC session** — initialized on first `hs:` call that misses the static
   registry. No startup cost if interop isn't used.

3. **Two calling forms** — `hs:` for auto-inferred monomorphic functions, `hs@`
   for annotated polymorphic/complex functions.

4. **Cache everything** — compiled closures and type info cached in a
   `Map Text (FuncInfo, Any)` so repeated calls are instant after first lookup.

## Calling Convention

### Auto-inferred (`hs:` prefix)

Works for monomorphic functions with supported types:

```lisp
(hs:succ 41)                  ;; => 42 (still uses static registry)
(hs:Data.Char.toUpper 'a')    ;; => error: Char not supported
(hs:Data.Char.ord ...)        ;; => error: Char not supported, use hs@
```

On registry miss, the GHC API looks up the function, infers its type, checks
all arguments and the return type are supported, compiles the function, and
applies it. Errors clearly if any type is unsupported.

### Annotated (`hs@` form)

For polymorphic functions or functions with unsupported types:

```lisp
(hs@ "Data.List.sort :: [Int] -> [Int]" (list 3 1 2))  ;; => (1 2 3)
(hs@ "reverse :: [Int] -> [Int]" (list 1 2 3))         ;; => (3 2 1)
```

The string argument is a Haskell expression with a type signature. `compileExpr`
compiles it (GHC monomorphizes the type), and we use the annotated type for
marshaling decisions.

## Supported Types

| GHC Type | Grasp Type | Marshaling | Notes |
|----------|-----------|------------|-------|
| `Int` | GTInt | None (native I#) | Zero cost |
| `Double` | GTDouble | None (native D#) | Zero cost |
| `Bool` | GTBoolTrue/False | None (native) | Zero cost |
| `[a]` | GTCons chain | Marshal cons↔list | `a` must be supported |
| `String` | GTStr | Text↔[Char] | Via `T.pack`/`T.unpack` |
| `Text` | GTStr | Unwrap/wrap GraspStr | Direct |

Types not in this table produce a clear error message suggesting the `hs@` form.

## Function Application

For native types, direct closure application via `unsafeCoerce`:

```haskell
-- Apply a function closure to arguments, curried
applyN :: Any -> [Any] -> IO Any
applyN f []     = pure f
applyN f (x:xs) = applyN (unsafeCoerce f x) xs
```

For arguments needing marshaling, convert before applying:

```haskell
-- Example: calling sort :: [Int] -> [Int]
-- 1. Marshal Grasp cons list → Haskell [Int]
-- 2. Apply function
-- 3. Marshal Haskell [Int] → Grasp cons list
```

The marshaling direction is determined by the type classification:
- **Argument positions**: Grasp→Haskell marshaling
- **Return position**: Haskell→Grasp marshaling

## Type Decomposition

```haskell
-- Parse a GHC Type into something we can work with
data GraspArgType
  = NativeInt | NativeDouble | NativeBool
  | ListOf GraspArgType    -- [a] where a is supported
  | HaskellString          -- String = [Char]
  | HaskellText            -- Data.Text.Text
  deriving (Eq, Show)

data GraspFuncInfo = GraspFuncInfo
  { funcArity   :: Int
  , funcArgs    :: [GraspArgType]
  , funcReturn  :: GraspArgType
  }

-- Classify a GHC Type into our type system
classifyType :: GHC.Type -> Either String GraspArgType
-- Uses GHC.Core.Type functions to inspect the type structure
```

## GHC Session Management

```haskell
-- New field in EnvData
data EnvData = EnvData
  { envBindings   :: Map Text GraspVal
  , envHsRegistry :: HsFuncRegistry
  , envGhcSession :: IORef (Maybe GhcState)  -- lazy init
  }

data GhcState = GhcState
  { ghcSession :: GHC.HscEnv
  , ghcCache   :: IORef (Map Text CachedFunc)
  }

data CachedFunc = CachedFunc
  { cfInfo    :: GraspFuncInfo   -- parsed type info
  , cfClosure :: Any             -- compiled function closure
  }
```

The GHC session is initialized once on first dynamic lookup and reused for all
subsequent calls. The cache maps qualified function names to their compiled
closures and type metadata.

## Dispatch Flow

```
(hs:Data.List.nub xs)
  │
  ├─ Check static registry → miss
  │
  ├─ Check GHC cache → miss (first call)
  │
  ├─ Initialize GHC session (if needed)
  │
  ├─ exprType "Data.List.nub" → [Int] -> [Int] (if monomorphic)
  │   └─ classifyType → ListOf NativeInt -> ListOf NativeInt
  │   └─ Error if polymorphic: "nub is polymorphic, use hs@ form"
  │
  ├─ compileExpr "Data.List.nub" → Any (function closure)
  │
  ├─ Cache (funcInfo, closure) under "Data.List.nub"
  │
  ├─ Marshal args: Grasp cons list → [Int]
  │
  ├─ Apply: (unsafeCoerce closure :: [Int] -> [Int]) marshaledArgs
  │
  ├─ Marshal result: [Int] → Grasp cons list
  │
  └─ Return GraspVal
```

## Module Resolution

For qualified names like `Data.List.sort`:
1. Parse the function name to extract module path and function name
2. Use `GHC.findModule` to locate the module
3. Use `GHC.setContext` to bring it into scope
4. Then `exprType`/`compileExpr` as usual

For unqualified names (e.g., `hs:succ`), search `Prelude` first.

## Error Handling

| Scenario | Error message |
|----------|--------------|
| Module not found | `"unknown module: Data.Foo"` |
| Function not exported | `"Data.List.foo is not exported"` |
| Polymorphic function via hs: | `"nub :: Eq a => [a] -> [a] is polymorphic, use hs@ with type annotation"` |
| Unsupported argument type | `"Data.Char.ord: unsupported type (Char -> Int), use hs@ with type annotation"` |
| Type mismatch at call | `"Data.List.sort: argument 1: expected [Int], got Int"` |
| GHC session failure | `"GHC error: <details>"` |

## Dependencies

| Package | Purpose |
|---------|---------|
| `ghc` | GHC API: `compileExpr`, `exprType`, `splitFunTys` |
| `ghc-paths` | Auto-resolve `libdir` for `runGhc` |

Both are in nixpkgs and available via the Nix flake.

## Risk: GHC API Stability

The GHC API is internal and changes between major versions. Mitigation:
- Pin to GHC 9.8 in the flake
- Isolate all GHC API calls in one module (`Grasp.DynLookup`)
- The core mechanism (`compileExpr` → `Any`) has been stable since GHC 8.0

## Risk: GHC Session Concurrency

`runGhc` is not thread-safe. The session must be protected by a mutex if
concurrent REPL sessions are ever supported. For now, single-threaded REPL
is fine.

## Files Changed

| Module | Status | Changes |
|--------|--------|---------|
| `Grasp.DynLookup` | NEW | GHC session, type inference, compilation, cache |
| `Grasp.Types` | MODIFY | Add `envGhcSession` to `EnvData` |
| `Grasp.Eval` | MODIFY | Add `hs@` special form, update `hs:` fallback |
| `Grasp.HaskellInterop` | MODIFY | Initialize GHC session, wire up fallback |
| `grasp.cabal` | MODIFY | Add `ghc`, `ghc-paths` dependencies |
| `flake.nix` | POSSIBLY | Ensure `ghc` package is available |
| Test files | NEW/MODIFY | Tests for dynamic lookup |
