# Writing trap sets

A trap set (or extension) is a C or C++ source file that provides native
implementations for LC-3 trap vectors. Sets are loaded per build with `-traps`.

```sh
lcc program.asm -traps mytraps.c         # one set
lcc program.asm -traps a.c -traps b.c    # one flag per set
```

## The trap ABI

Every handler has the same signature, defined in `src/runtime/lcc_trap.h`:

```c
typedef struct lcc_trap_ctx
{
    unsigned short *memory; /* 65536 word address space */
    unsigned short *reg;    /* R0-R7 */
    unsigned short pc;      /* PC of the next instruction */
    unsigned short *cc;     /* condition code value */
} lcc_trap_ctx;
```

lcc automatically includes this header while compiling your set, so the macros
are always available even without including it yourself. A set may also include
it explicitly with `#include "lcc_trap.h"` for LSP completion. To generate the
header yourself (writes `lcc_trap.h` in the current directory):

```sh
lcc -generate-traps-header
```

## Declaring a handler

`LCC_TRAP(vect, alias)` expands to the handler's signature. The body follows as
a normal function definition:

```c
LCC_TRAP(0x30, foo)
{
    ctx->reg[0] = 42;
}
```

- `vect` is the trap vector integer in `0..255` (`0x30` in the example).
- `alias` is the mnemonic used in assembly (`foo` in the example). It must be
  lowercase letters `a-z` onlys.
- Keep each `LCC_TRAP(...)` invocation simple and on one line, lcc finds
  declarations by scanning the source as is, so wrapped or broken lines won't be
  detected.

The example above makes `foo` a valid instruction:

```asm
.ORIG x3000
    foo ; calls lcc_trap_foo
    halt
.END
```

## Link flags

`LCC_LINK(...)` appends flags to the link command when the set is used:

```c
LCC_LINK(-L/usr/local/lib, -lmcpp)
```

One flag per comma-separated argument. The macro expands to nothing; lcc
finds it by scanning, like `LCC_TRAP`. Bare file paths and relative `-L`
values resolve against the set file's own directory, so a stub can name an
object that sits beside it no matter where lcc runs from. Other flags pass
through untouched.

lcc invokes `clang` (not `clang++`), so it appends the platform C++ runtime
whenever a loaded set is C++ (`.cpp`, `.cc`, `.cxx`): `-lc++` on macOS,
`-lstdc++` on Linux. If your `LCC_LINK` already names a runtime, lcc leaves
the flags alone.

## Compiled trap sets

Handlers do not have to be written in C. All that matters is the ABI: an
unmangled `lcc_trap_<alias>` symbol taking `lcc_trap_ctx *`, with the layout
described in [The trap ABI](#the-trap-abi). Rust `staticlib`, Go `c-archive`,
a Zig static library, anything that produces a static archive or object file.

lcc still needs the vector and alias declarations to assemble the program, so a
compiled set ships with a stub C declaration. `LCC_TRAP` lines written as
prototypes with no body, and an `LCC_LINK` naming the library.

```c
/* mytraps.c declarations only */
LCC_TRAP(0x30, foo);
LCC_LINK(./libtraps.a)
```

```sh
lcc program.asm -traps mytraps.c
```

The stub compiles to an empty object while `LCC_LINK` passes the archive to the
linker, which pulls in your handlers. Everything else works as usual: the stub
participates in the collision and override rules exactly like a C set.

Example in Rust:

```rust
#[repr(C)]
pub struct LccTrapCtx {
    pub memory: *mut u16,
    pub reg: *mut u16,
    pub pc: u16,
    pub cc: *mut u16,
}

#[no_mangle]
pub extern "C" fn lcc_trap_foo(ctx: *mut LccTrapCtx) {
    unsafe {
        (*ctx).reg.write(42);
    }
}
```

```sh
rustc --crate-type staticlib traps.rs -o libtraps.a
lcc program.asm -traps mytraps.c
```

- Export handlers with C linkage (`extern "C"`, `#[no_mangle]`,
  `-buildmode=c-archive`), and keep the struct layout identical to `lcc_trap.h`.
- Static archives and objects link straight into the executable. Shared
  libraries link too, but the loader resolves a relative path against the
  working directory, so the program only runs from the directory holding the
  library. Build the library with an `@rpath` install name and link with
  `-dynamic` to avoid that. lcc adds the directory it ran from to the runtime
  search path.

## Overriding standard traps

A set may replace a standard trap by redeclaring it with the **same alias**:

```c
LCC_TRAP(0x26, putn) /* same alias as standard putn */
{
    printf("0x%04X\n", ctx->reg[0]);
}
```

The set's handler wins and the standard one is not called. Declaring a
standard vector under a _different_ alias throws an error.

## Errors

`-traps` failures exit with status 2 and report the file and line:

| Problem                           | Example message                         |
| --------------------------------- | --------------------------------------- |
| Duplicate vector inside one set   | `duplicate declaration of trap x30`     |
| Two sets claiming the same vector | `trap x30 already provided by trap set` |
| Renaming a standard trap          | `cannot redeclare it as ...`            |
| Reusing another trap's alias      | `trap alias 'chat' is already used`     |
| Bad alias (not lowercase `a-z`)   | `invalid trap alias ...`                |

## The minecraft set

`src/runtime/sets/minecraft.cpp` provides traps `x28`-`x2D` backed by
[mcpp](https://github.com/rozukke/mcpp). Requires mcpp installed in
`/usr/local`.

```sh
lcc program.asm -traps ./src/runtime/sets/minecraft.cpp
```

| Trap   | Vector | Description                         |
| ------ | ------ | ----------------------------------- |
| `chat` | `x28`  | Post the string at mem[R0] to chat  |
| `getp` | `x29`  | Read the player position into R0-R2 |
| `setp` | `x2A`  | Set the player position from R0-R2  |
| `getb` | `x2B`  | Read the block at (R0-R2) into R3   |
| `setb` | `x2C`  | Set the block at (R0-R2) to R3      |
| `geth` | `x2D`  | Read the height at (R0, R2) into R1 |
