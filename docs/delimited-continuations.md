# Delimited Continuations

This document explains delimited continuations: what they are in general, how GHC implements them at the RTS level, and how Grasp uses them to build a condition system. This is one of the clearest demonstrations of Grasp as a native tenant of the STG machine — when a Grasp program captures a continuation, it captures a real piece of the GHC execution stack stored as a heap object traced by GHC's GC.

## What is a continuation?

A **continuation** is "the rest of the computation." At any point during evaluation, the continuation represents everything that still needs to happen with the current value.

Consider evaluating `(+ 1 (+ 2 3))`. When the inner `(+ 2 3)` is being evaluated, the continuation is "take the result and add 1 to it." In the STG machine, this continuation exists as a stack frame — a return address plus saved values waiting for the result.

```
Stack during evaluation of (+ 2 3):

  ┌──────────────────────┐
  │  "add 1 to result"   │  ← continuation (stack frame)
  ├──────────────────────┤
  │  "print the result"  │  ← another frame
  ├──────────────────────┤
  │  "return to REPL"    │  ← bottom of stack
  └──────────────────────┘
```

**Undelimited continuations** (`call/cc` in Scheme) capture the *entire* remaining computation — every frame from the current point to the bottom of the stack. This makes them hard to reason about and hard to compose. If you capture a continuation in one part of a program and invoke it from another, you replace the *entire* control flow, which is rarely what you want.

## What makes them "delimited"?

A **delimited continuation** captures only a *portion* of the stack — from the current point up to a designated **prompt** (marker), not all the way to the bottom.

```
Stack with a prompt:

  ┌──────────────────────┐
  │  "add 1 to result"   │  ← captured by control0
  ├──────────────────────┤
  │  ══ PROMPT (tag=T) ══ │  ← capture stops here
  ├──────────────────────┤
  │  "print the result"  │  ← NOT captured
  ├──────────────────────┤
  │  "return to REPL"    │  ← NOT captured
  └──────────────────────┘
```

Two operations define the system:

- **`prompt`** — Places a marker on the stack. Think of it as a checkpoint.
- **`control0`** — Captures everything above the nearest matching prompt, removes it from the stack, and passes it as a function to a callback.

The captured slice of stack becomes a regular function you can call, store, or discard. Calling it "pastes" those frames back onto the stack, resuming execution from where `control0` was called, as if it returned a value.

### The operator zoo

The theory of delimited continuations has several variants, differing in two orthogonal choices:

| Operator | Captures the prompt frame? | Leaves the prompt on resume? |
|----------|---------------------------|------------------------------|
| `prompt` / `control` | Yes | Yes |
| `reset` / `shift` | No | Yes |
| `prompt` / `control0` | No | No |

GHC implements `prompt` / `control0`, which Dybvig et al. call the most general of the standard operators. The others can be built from it. "No / No" means: the prompt frame is *not* included in the captured continuation, and when the callback runs, the prompt is *not* reinstalled automatically.

### Prompt tags

A **prompt tag** identifies *which* prompt to capture up to. Without tags, `control0` would always capture to the nearest prompt, making it impossible to have nested handlers for different purposes. Tags are type-safe labels:

```
Stack with tagged prompts:

  ┌──────────────────────┐
  │  computation C       │  ← control0 tag=A captures this
  ├──────────────────────┤
  │  ══ PROMPT (tag=B) ══ │  ← skipped (wrong tag)
  ├──────────────────────┤
  │  computation B       │  ← control0 tag=A captures this too
  ├──────────────────────┤
  │  ══ PROMPT (tag=A) ══ │  ← capture stops here
  ├──────────────────────┤
  │  rest of program     │
  └──────────────────────┘
```

This is essential for Grasp's nested condition handlers — each `with-handler` creates a unique tag, so `signal` captures exactly the right slice of stack.

## How GHC implements delimited continuations

GHC's implementation, based on [proposal 313](https://github.com/ghc-proposals/ghc-proposals/blob/master/proposals/0313-delimited-continuation-primops.rst) by Alexis King, adds support directly to the RTS through stack manipulation. No changes to the compiler or code generator are needed — it is purely a runtime feature, available since GHC 9.6.

### The primops

```haskell
type PromptTag# :: Type -> TYPE UnliftedRep

newPromptTag# :: State# RealWorld -> (# State# RealWorld, PromptTag# a #)
prompt#       :: PromptTag# a
              -> (State# RealWorld -> (# State# RealWorld, a #))
              -> State# RealWorld -> (# State# RealWorld, a #)
control0#     :: PromptTag# a
              -> ((  (State# RealWorld -> (# State# RealWorld, b #))
                  -> State# RealWorld -> (# State# RealWorld, a #))
                -> State# RealWorld -> (# State# RealWorld, a #))
              -> State# RealWorld -> (# State# RealWorld, b #)
```

Stripped of `State#` threading, the intuitive types are:

```haskell
newPromptTag :: IO (PromptTag a)
prompt       :: PromptTag a -> IO a -> IO a
control0     :: PromptTag a -> ((IO b -> IO a) -> IO a) -> IO b
```

- `newPromptTag` creates a fresh, globally unique tag.
- `prompt tag body` runs `body` with a prompt frame on the stack.
- `control0 tag callback` captures the stack up to `tag`'s prompt, then calls `callback` with the captured continuation.

### RTS-level mechanics

**`prompt#`** pushes a `RET_SMALL` stack frame with a known info table pointer and the prompt tag. This frame is the marker that `control0#` searches for.

```
Before prompt#:                  After prompt#:
                                   ┌──────────────────┐
                                   │  body's frames    │
                                   ├──────────────────┤
  ┌──────────────────┐             │  PROMPT frame    │
  │  caller's frames │             │  (tag, info ptr) │
  └──────────────────┘             ├──────────────────┤
                                   │  caller's frames │
                                   └──────────────────┘
```

**`control0#`** walks up the stack looking for a prompt frame whose tag matches. When found, it:

1. **Copies** every frame between the current stack pointer and the prompt into a heap-allocated `CONTINUATION` closure.
2. **Removes** those frames (and the prompt) from the stack.
3. **Invokes** the callback, passing the `CONTINUATION` as the captured continuation.

```
Before control0#:                After control0#:

  ┌──────────────────┐
  │  frame C         │──┐        Heap:
  ├──────────────────┤  │        ┌──────────────────────┐
  │  frame B         │──┼───────▶│  CONTINUATION closure │
  ├──────────────────┤  │        │  [frame B, frame C]  │
  │  ══ PROMPT ══    │──┘        └──────────────────────┘
  ├──────────────────┤
  │  caller's frames │           Stack:
  └──────────────────┘           ┌──────────────────┐
                                 │  callback running │
                                 ├──────────────────┤
                                 │  caller's frames │
                                 └──────────────────┘
```

**Resuming** the continuation means copying the saved frames from the `CONTINUATION` closure back onto the stack and jumping into them, as if `control0#` returned with the given value. The continuation can be resumed zero, one, or many times.

### The `CONTINUATION` closure type

The captured continuation is a new closure type in GHC's RTS, similar to `AP_STACK` (a closure that stores a chunk of stack). Key properties:

- It is a **heap object** traced by GHC's generational copying GC. Stack frames inside it contain pointers to other closures, and the GC follows them during collection.
- It behaves like a `FUN` with arity 2 — it accepts a value and a `State#` token.
- It is a **functional** (non-abortive) continuation: invoking it *extends* the current stack rather than replacing it. This means captured continuations compose naturally.
- It can be stored in data structures, passed between threads, or discarded — it is a first-class value.

### Why `PromptTag#` is unlifted

`PromptTag#` has kind `TYPE UnliftedRep`. This means it cannot be `undefined`, cannot be stored in a lazy field, and cannot be used as a regular `Any`. GHC uses this restriction because a prompt tag must always be a real, valid value — a thunk that "might be a prompt tag" would be meaningless at the RTS level where `prompt#` needs to compare tags immediately.

This creates a practical challenge for Grasp, where all values are `Any` (a lifted type). See the Grasp section below for how we bridge this gap.

## How Grasp uses delimited continuations

Grasp uses delimited continuations to implement a **condition system** — a Common Lisp-style error handling mechanism where the handler can not only catch errors but also *resume* the failing computation with a replacement value.

### The user-level API

```lisp
;; Establish a handler
(with-handler
  (lambda (condition restart)
    (if (= condition 'division-by-zero)
      (restart 0)          ; resume from signal point, returning 0
      "unhandled"))        ; return this, abandon the body
  body)

;; Raise a condition
(signal value)
```

- `with-handler` installs a handler and runs the body. If the body completes normally, its value is returned.
- `signal` finds the nearest handler and invokes it with the signaled value and a restart function.
- The handler has two choices: call `restart` to resume the computation, or return a value to abandon the body.

This is more powerful than exceptions: the handler can fix the problem and let the computation continue, without the signaling code needing to know how the fix works.

### Implementation: `Grasp.Continuations`

The module `src/Grasp/Continuations.hs` wraps GHC's unboxed primops as regular IO functions.

#### Boxing `PromptTag#`

The central challenge: `PromptTag#` is unlifted (`TYPE UnliftedRep`), but Grasp stores all values as `Any` (a lifted type). `unsafeCoerce` cannot bridge different levities.

The solution uses a helper data type:

```haskell
data BoxTag = BoxTag (PromptTag# Any)
```

GHC allows unlifted types as fields in lifted data types — the field is strict by nature. `BoxTag` is lifted, so `unsafeCoerce` between `BoxTag` and `Any` works:

```haskell
boxTag :: PromptTag# Any -> Any
boxTag t = case unsafeCoerce (BoxTag t) of (a :: Any) -> a

unboxTag :: Any -> PromptTag# Any
unboxTag a = case unsafeCoerce a of BoxTag t -> t
```

This adds one indirection (the `BoxTag` constructor) but is only used at handler install/signal time, not in the hot evaluation loop.

#### Wrapping the primops

The three primops become regular IO functions:

```haskell
newPromptTag :: IO Any
newPromptTag = IO $ \s ->
  case newPromptTag# s of
    (# s', tag #) -> (# s', boxTag tag #)

prompt :: Any -> IO Any -> IO Any
prompt tagBox body = IO $ \s ->
  prompt# (unboxTag tagBox)
    (\s' -> case body of IO f -> f s') s

control0 :: Any -> ((Any -> IO Any) -> IO Any) -> IO Any
control0 tagBox callback = IO $ \s ->
  control0# (unboxTag tagBox)
    (\k s' -> case callback
       (\v -> IO (\s'' -> k (\s3 -> (# s3, v #)) s''))
       of IO f -> f s')
    s
```

The `control0` wrapper is the trickiest. The raw `control0#` continuation `k` has type:

```
k :: (State# RealWorld -> (# State# RealWorld, b #))
  -> State# RealWorld -> (# State# RealWorld, a #)
```

It takes a *computation* (not a value) and a state token. To resume with a value `v`, you pass `\s -> (# s, v #)` as the computation. The wrapper hides this by presenting `k` as a simple `Any -> IO Any` function.

#### The handler stack

Handlers are stored in a global mutable stack:

```haskell
{-# NOINLINE handlerStack #-}
handlerStack :: IORef [(Any, Any)]   -- [(promptTag, handlerFn)]
handlerStack = unsafePerformIO (newIORef [])
```

Dynamic scoping is the right model here: `signal` should find the nearest handler on the *call stack*, not in the lexical scope. A global IORef stack mirrors the call stack — `with-handler` pushes, and `signal` peeks at the top.

### Implementation: `with-handler` and `signal` in the evaluator

In `src/Grasp/Eval.hs`, two new eval clauses implement the condition system.

#### `with-handler`

```
(with-handler handler body)
```

1. Evaluate `handler` (a lambda taking `(condition, restart)`).
2. Create a fresh prompt tag.
3. Push `(tag, handler)` onto the handler stack.
4. Run `body` inside `prompt tag (eval env body)`.
5. On normal completion: pop the handler, return body's value.
6. On Haskell exception: pop the handler, call handler with the error message and a non-resumable restart.

```
                     handler stack          STG stack
                     ┌──────────┐
with-handler enters: │ (T, h)   │          ┌──────────┐
                     │   ...    │          │  body     │
                     └──────────┘          │  frames   │
                                           ├──────────┤
                                           │ PROMPT T │
                                           ├──────────┤
                                           │ caller   │
                                           └──────────┘
```

The `catch SomeException` around the prompt call means that Haskell `error` calls (from primitives like `car`, `cdr`, division) are forwarded to the Grasp handler. This unifies Grasp's condition system with Haskell's exception mechanism:

```lisp
(with-handler
  (lambda (c r) "caught")
  (car 42))               ; => "caught"
```

#### `signal`

```
(signal value)
```

1. Evaluate `value`.
2. Peek at the top of the handler stack.
3. Call `control0 tag callback`:
   - The callback receives continuation `k`.
   - Pop the handler from the stack.
   - Wrap `k` as a Grasp primitive `restart`.
   - Call `handler(value, restart)`.

```
Before signal:                  After control0 captures:

STG stack:                      STG stack:
  ┌──────────────┐
  │ (+ 1 □)      │──┐            ┌────────────────┐
  ├──────────────┤  │            │ handler call    │
  │ PROMPT T     │──┘ captured   ├────────────────┤
  ├──────────────┤     ══════▶   │ caller          │
  │ caller       │               └────────────────┘
  └──────────────┘
                                Heap:
                                  CONTINUATION [frames]
                                  wrapped as restart fn
```

The restart function re-pushes the handler before resuming, so the handler is available for subsequent signals within the same body:

```haskell
let restart = mkPrim "<restart>" (\case
      [v] -> do
        pushHandler tag handler  -- re-install for next signal
        r <- k v                 -- resume continuation
        popHandler               -- clean up after body completes
        pure r
      _ -> error "restart expects one argument")
```

### What happens at the RTS level

Consider this Grasp program:

```lisp
(with-handler
  (lambda (c r) (r 0))
  (+ 1 (signal 99)))
```

Here is what happens at the GHC runtime level:

1. **`with-handler`** evaluates the lambda (creating a `GraspLambda` closure on the heap). Calls `newPromptTag#`, which allocates a unique `PromptTag#`. Pushes the handler. Calls `prompt#`, which pushes a `RET_SMALL` prompt frame onto the STG stack.

2. **Body evaluation** begins. The evaluator enters `(+ 1 (signal 99))`. To evaluate `+`, it first needs the value of `(signal 99)`. The stack now has a frame for "add 1 to the result" above the prompt.

3. **`signal`** evaluates `99` (producing an `I# 99` closure). Then calls `control0#` with the handler's tag.

4. **`control0#`** walks the stack upward looking for the matching prompt frame. It finds it, with the "add 1" frame above it. It copies that frame into a heap-allocated `CONTINUATION` closure. The prompt frame and everything above it are removed from the stack.

5. **The callback** runs with `k` bound to the `CONTINUATION`. The handler is popped from the stack. The continuation is wrapped as a `GraspPrim` closure (the restart function). The handler lambda is applied to `(99, restart)`.

6. **The handler** calls `(restart 0)`. This re-pushes the handler, then invokes the `CONTINUATION` closure with value `0`. The RTS copies the saved frame ("add 1") back onto the stack, and `control0#`'s call site returns `0`.

7. **Execution resumes** as if `(signal 99)` returned `0`. The "add 1" frame completes: `(+ 1 0)` evaluates to `1`. The handler is popped. The result `1` is returned.

At every step, the continuation is a real GHC heap object. The GC traces it. The stack frames inside it reference closures that the GC keeps alive. When the continuation is invoked, the STG machine's own evaluation machinery processes those frames. Grasp isn't simulating continuations — it is using the same mechanism that GHC's own control flow uses.

### Nested handlers

Each `with-handler` creates a unique prompt tag, enabling nesting:

```lisp
(with-handler (lambda (c r) (+ c 1000))     ; outer handler
  (with-handler (lambda (c r) (r (+ c 10))) ; inner handler
    (+ 1 (signal 5))))
```

The stack has two prompts. `signal` captures to the inner prompt (top of the handler stack). The inner handler restarts with `15`, so the body computes `(+ 1 15)` = `16`.

If the inner handler had *not* called restart, the outer handler would never see the signal — it would just get the inner handler's return value. To propagate, the inner handler would re-signal: `(lambda (c r) (signal c))`.

## References

- [GHC Proposal 313: Delimited continuation primops](https://github.com/ghc-proposals/ghc-proposals/blob/master/proposals/0313-delimited-continuation-primops.rst) — Alexis King's proposal that added these primops to GHC
- [From delimited continuations to algebraic effects in Haskell](https://blog.poisson.chat/posts/2023-01-02-del-cont-examples.html) — Practical examples of using the primops for effects
- [A Monadic Framework for Delimited Continuations](https://legacy.cs.indiana.edu/~dyb/pubs/monadicDC.pdf) — Dybvig, Peyton Jones, Sabry — the theoretical foundation
- [Shift to control](https://homes.luddy.indiana.edu/ccshan/recur/recur.pdf) — Chung-chieh Shan — the paper GHC's design draws from
