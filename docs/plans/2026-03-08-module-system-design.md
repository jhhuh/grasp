# Module System — Design

## Goal

Add a module system with `(module name (export ...) body...)` definition,
`(import name)` / `(import "path.gsp")` loading, qualified access via dot
notation (`math.square`), module caching, and circular dependency detection.

## Architecture

Modules are a new `GraspModule` ADT stored in `envModules` (a new field in
`EnvData`). `module` and `import` are special forms in `eval`. Qualified
access works by splitting symbols on `.` during lookup. A loading stack
in `EnvData` detects circular dependencies.

### Module Definition

A module file (`math.gsp`) contains:

```lisp
(module math
  (export square cube)

  (define square (lambda (x) (* x x)))
  (define cube (lambda (x) (* x (square x))))
  (define helper (lambda (x) (+ x 1)))  ; not exported
)
```

`module` is a special form: `(module name (export sym...) body...)`

Semantics:
1. Create a fresh child env inheriting primitives from the caller's env
2. Evaluate all body forms sequentially in the child env
3. Validate that every exported symbol is defined in the child env
4. Return a `GraspModule` containing the module name and a `Map Text Any`
   of exported bindings
5. Non-exported bindings exist during evaluation but are not accessible
   from outside

### Import

```lisp
(import math)              ; looks for math.gsp in cwd
(import "./lib/utils.gsp") ; explicit path
```

Import steps:
1. Resolve file path: symbol → `name.gsp` in cwd, string → literal path
2. Check `envModules` cache — if already loaded, reuse
3. Check `envLoading` stack — if currently loading, error (circular dep)
4. Read and parse the file (entire file as a single expression)
5. Push module name onto `envLoading`
6. Eval the `(module ...)` form in a fresh env (inherits primitives +
   Haskell interop from the importing env)
7. Pop from `envLoading`, add to `envModules` cache
8. Bind into caller's env:
   - Qualified: `math.square`, `math.cube` (name + "." + export)
   - Unqualified: `square`, `cube`

### Qualified Access

When `eval` looks up a symbol containing `.`:

1. Try exact match in `envBindings` first (handles explicit `define` of
   dotted names)
2. If not found and symbol contains `.`, split on first dot
3. Look up prefix in `envModules`
4. If found, look up suffix in the module's export map
5. If not found at any step, error "unbound symbol"

This approach requires no parser changes — dots are already valid in
symbol names. The split happens at eval time in the symbol lookup path.

### New Types

**`GraspModule` ADT:**

```haskell
data GraspModule = GraspModule Text (Map Text Any)
```

With `GTModule`, `moduleInfoPtr`, `mkModule`/`toModuleParts`.

Printer: `GTModule -> "<module:name>"`.

**`EnvData` changes:**

```haskell
data EnvData = EnvData
  { envBindings   :: Map Text GraspVal
  , envHsRegistry :: HsFuncRegistry
  , envGhcSession :: IORef (Maybe Any)
  , envModules    :: Map Text Any        -- loaded modules by name
  , envLoading    :: [Text]              -- circular dep detection stack
  }
```

### File Lookup

- Module files use `.gsp` extension
- `(import math)` looks for `math.gsp` in the current working directory
- `(import "./lib/math.gsp")` uses an explicit path relative to cwd
- No search path mechanism — explicit paths or cwd-relative only

### Re-exports

Work naturally through the module evaluation model:

```lisp
(module prelude
  (export square sort)
  (import math)
  (define square square)  ; re-export from math
  (define sort (lambda (xs) (hs:Data.List.sort xs)))
)
```

Imported bindings are available during module evaluation, so any
`define`d name in the export list gets exported. No special syntax.

### Error Handling

| Error | Message |
|-------|---------|
| File not found | `"import: file not found: math.gsp"` |
| Circular dependency | `"import: circular dependency: math -> utils -> math"` |
| No module form in file | `"import: no module definition in math.gsp"` |
| Export references undefined | `"module math: exported symbol 'foo' is not defined"` |
| Qualified lookup fails | `"unbound symbol: math.foo"` |

### Printing

`GTModule -> "<module:name>"` — shows the module name.

## What's NOT Included

- **Search paths** — no `GRASP_PATH` or configurable module directories.
  Explicit paths or cwd-relative only.
- **Selective import** — `(import math (only square))` for importing
  specific bindings. All exports are imported.
- **Import aliasing** — `(import math :as m)` for short qualified names.
- **Nested modules** — modules cannot define sub-modules.
- **Hot reloading** — modules are cached on first load, never reloaded.

## Files Changed

| Module | Status | Changes |
|--------|--------|---------|
| `Grasp.Types` | MODIFY | Add `envModules`, `envLoading` to `EnvData` |
| `Grasp.NativeTypes` | MODIFY | Add `GraspModule`, `GTModule`, info ptr, mkModule, toModuleParts |
| `Grasp.Eval` | MODIFY | Add `module`/`import` special forms, dot-split in symbol lookup |
| `Grasp.Printer` | MODIFY | Add `GTModule -> "<module:name>"` |
| Test files | MODIFY | Add module/import/qualified access tests |

## Dependencies

- `System.Directory` (doesFileExist, getCurrentDirectory) — already in `base`
- `Data.Text.IO` (readFile) — already used
- No new package dependencies.
