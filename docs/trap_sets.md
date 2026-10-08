# Writing trap sets

A trap set (or extension) is a C or C++ source file that provides native
implementations for LC-3 trap vectors. Sets are loaded per build with `-traps`.

```sh
lcc program.asm -traps mytraps.c         # one set
lcc program.asm -traps a.c -traps b.c    # one flag per set
```

A few sets are compiled into lcc itself and can be selected by name. The bundled
sets are `minecraft`, `rand`, `syscalls`, `terminal`, and `time`. Any other value
is read as a `.c`/`.cpp` source.

```sh
lcc program.asm -traps terminal -traps time
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
lcc program.asm -traps minecraft
```

| Trap   | Vector | Description                         |
| ------ | ------ | ----------------------------------- |
| `chat` | `x28`  | Post the string at mem[R0] to chat  |
| `getp` | `x29`  | Read the player position into R0-R2 |
| `setp` | `x2A`  | Set the player position from R0-R2  |
| `getb` | `x2B`  | Read the block at (R0-R2) into R3   |
| `setb` | `x2C`  | Set the block at (R0-R2) to R3      |
| `geth` | `x2D`  | Read the height at (R0, R2) into R1 |

## The syscall set

`src/runtime/sets/syscalls.c` provides file traps `x50`-`x56` backed by the
host file API:

```sh
lcc program.asm -traps syscalls
```

| Trap     | Vector | Input                                | Output                   |
| -------- | ------ | ------------------------------------ | ------------------------ |
| `open`   | `x50`  | R0 = path address, R1 = mode         | R0 = fd, or -1           |
| `close`  | `x51`  | R0 = fd                              | R0 = 0, or -1            |
| `read`   | `x52`  | R0 = fd, R1 = buffer, R2 = count     | R0 = bytes, or -1        |
| `write`  | `x53`  | R0 = fd, R1 = buffer, R2 = count     | R0 = bytes, or -1        |
| `seek`   | `x54`  | R0 = fd, R1/R2 = offset, R3 = whence | R0/R1 = new offset       |
| `size`   | `x55`  | R0 = fd                              | R0/R1 = size, or R0 = -1 |
| `remove` | `x56`  | R0 = path address                    | R0 = 0, or -1            |

Conventions:

- File descriptors `0`, `1`, and `2` are stdin, stdout, and stderr.
- Paths are NULL terminated strings with one character per word (like `puts`).
- buffers hold one byte per word.
- Counts are 16-bit, offsets and sizes are 32-bit with the high word in `R1`.
- Failed calls return `-1`.
- Each trap sets the condition codes. Negative when the call failed, positive
  when it succeeded. So any syscall can be followed by `brn fail`.
- `open` modes: `0` read, `1` create or truncate, `2` create or append.
- `seek` whence values: `0` set, `1` current, `2` end.

## The terminal set

The `terminal` set provides traps `x40`-`x46` for full screen
programs: escape sequence output, key decoding, and a non-blocking read.

```sh
lcc program.asm -traps terminal
```

| Trap    | Vector | Input                           | Output                               |
| ------- | ------ | ------------------------------- | ------------------------------------ |
| `clear` | `x40`  | -                               | Clear the screen                     |
| `home`  | `x41`  | -                               | Cursor to row 1, column 1            |
| `goto`  | `x42`  | R0 = row, R1 = column (1-based) | Move the cursor                      |
| `alt`   | `x43`  | R0 = 0 enter, 1 leave           | Alternate screen buffer              |
| `cur`   | `x44`  | R0 = 0 hide, 1 show             | Cursor visibility                    |
| `key`   | `x45`  | -                               | R0 = next key code                   |
| `poll`  | `x46`  | -                               | R0 = next byte, -1 if none, 0 at end |

Key codes:

- Bytes are returned as read, except Enter is normalised to `x0A`
  (terminals send CR or LF) and Backspace to `x08` (BS or DEL).
- `x1B` is Escape. It is reported once the following byte arrives unless
  that byte starts a sequence, it is kept for the next read.
- `x0100`-`x0103` are the arrow keys (`ESC [ A`-`D`), `x0104` is Delete
  (`ESC [ 3 ~`). Unknown sequences are swallowed and the next key is read.
- `key` reads through `getc`, so command line arguments arrive before
  stdin and end of input ends the program, exactly like `getc`.

`poll` is `key`'s non-blocking equivalent, it returns at once with the
next byte, `-1` when stdin has none, and `0` at end of input instead of
exiting, so a program can run between keypresses. It should not be
mixed with `key`/`getc`, which do not share its buffer.
