# lcc

An LC-3 to LLVM compiler written in Zig.

`lcc` uses [ELK](https://github.com/dxrcy/elk)'s IR directly through its library
API, translates it to LLVM IR in memory, and delegates optimisation and native
code generation to LLVM as a library. `clang` is invoked for the final link
step.

```text
LC-3 -> ELK -> elk.Air -> lcc -> LLVM module -> passes -> object -> clang -> executable
```

## Usage

```sh
lcc examples/arithmetic.asm
```

The compiled program's exit status is R0 (truncated by the operating system),
which lets simple programs be tested without traps.

Diagnostics are reported by ELK's own infrastructure.

### Flags

| Flag               | Description                                          |
| ------------------ | ---------------------------------------------------- |
| `-o <file>`        | Output executable                                    |
| `-Onone`           | Skip optimisation pass entirely                      |
| `-O0`..`-O3`       | LLVM optimisation levels                             |
| `-emit-llvm`       | Print optimised LLVM IR                              |
| `-target <triple>` | Compile for another target (e.g. `x86_64-linux-gnu`) |
| `-arch <name>`     | Shorthand for `-target` (e.g. `-arch x86_64`)        |

Cross targets reuse the host operating system suffix when only an architecture
is given, so `-arch x86_64` on a Mac produces an x86_64 executable that runs
under Rosetta. Backends are resolved from the shared LLVM library at runtime,
so no rebuild is needed to compile for a different architecture.

## Runtime

The standard traps are implemented natively in `src/runtime/lc3_runtime.c`,
which is embedded into the compiler and linked into every executable:

| Trap    | Vector | Behaviour                                          |
| ------- | ------ | -------------------------------------------------- |
| `GETC`  | x20    | Read one character into R0                         |
| `OUT`   | x21    | Print the low byte of R0                           |
| `PUTS`  | x22    | Print the NUL-terminated string at mem[R0]         |
| `IN`    | x23    | Prompt with `Input> `, read and echo one character |
| `PUTSP` | x24    | Like PUTS but two characters per word              |
| `HALT`  | x25    | Flush output and exit 0                            |

Trap semantics follow ELK's emulator.

## Build

Requires Zig `0.16.x`, a shared-library LLVM installation (15 or newer,
discovered via `llvm-config`), and `clang` on `PATH` for linking:

```sh
brew install llvm      # macOS
apt install llvm-dev   # Debian/Ubuntu
```

```sh
zig build
zig build test
./zig-out/bin/lcc examples/hello.asm
```
