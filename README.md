# lcc

An LC-3 to native compiler written in Zig.

lcc compiles LC-3 assembly into native executables using
[ELK](https://github.com/dxrcy/elk)'s IR as its frontend and LLVM as its
backend.

```
LC-3 source -> ELK parser -> elk.Air -> lcc codegen -> LLVM IR -> LLVM optimization -> object file -> clang -> executable
```

## Usage

```sh
lcc examples/hello.asm && ./hello
```

The compiled program's exit status depends on how it terminates. `halt` always
exits with status 0. If the program falls off the end of code without a `halt`,
R0 is used as the exit status (truncated by the OS).

### Command-line arguments

Compiled programs can receive command-line arguments, which are forwarded to
`getc` / `in` input. Arguments are joined with spaces and consumed before
falling back to stdin:

```sh
lcc examples/echo.asm && ./echo hi there
```

Diagnostics are reported by ELK's parser.

### Flags

| Flag               | Description                               |
| ------------------ | ----------------------------------------- |
| `-o <file>`        | Output executable path                    |
| `-Onone`           | Skip the LLVM optimization pass           |
| `-O0` .. `-O3`     | LLVM optimization levels                  |
| `-E`, `-emit-llvm` | Print the optimized LLVM IR to stdout     |
| `-target <triple>` | Cross-compile for a target triple         |
| `-arch <name>`     | Shorthand for `-target` using the host OS |
| `-dynamic`         | Link against liblc3 dynamically           |
| `-L<dir>`          | Directory to search for liblc3            |
| `-generate-liblc3` | Generate liblc3 shared library            |
| `-v`, `--version`  | Print version information                 |
| `-h`, `--help`     | Print usage help                          |

Cross-compilation reuses the host OS suffix when only an architecture is
given (`-arch x86_64` on macOS produces a Rosetta binary). LLVM backends are
loaded from the shared library at runtime, so no rebuild is needed for
different targets.

### Dynamic linking

By default, trap implementations are statically linked into every executable.
The `-dynamic` flag generates `liblc3` and links against it:

```sh
lcc examples/hello.asm -dynamic            # generates liblc3, compiles, works immediately
lcc examples/hello.asm -dynamic -L/usr/lib # look for liblc3 in /usr/lib
```

The linker searches for liblc3 in this order: `-L` (if given), `.`, then
`/usr/local/lib`. To install liblc3 system-wide for distributing binaries:

```sh
lcc -generate-liblc3 # creates liblc3.so / liblc3.dylib
```

See [docs/custom_lib.md](docs/custom_lib.md) for an example of creating a
custom trap library.

## Install

```sh
git clone https://github.com/twhlynch/lcc && cd lcc
zig build install -Doptimize=ReleaseFast --prefix ~/.local
```

## Runtime

Traps are implemented natively in `src/runtime/lc3_runtime.c`, which is embedded
into the compiler and linked into every executable. By default the runtime is
statically linked. Use `-dynamic` to link against a shared library instead (see
[Dynamic linking](#dynamic-linking)).

| Trap  | Vector | Description                                   |
| ----- | ------ | --------------------------------------------- |
| GETC  | x20    | Read one character into R0                    |
| OUT   | x21    | Print the low byte of R0                      |
| PUTS  | x22    | Print the NUL-terminated string at mem[R0]    |
| IN    | x23    | Prompt `Input> `, read and echo one character |
| PUTSP | x24    | Like PUTS but two characters per word         |
| HALT  | x25    | Flush output and exit with status 0           |
| PUTN  | x26    | Print R0 as an unsigned decimal with newline  |
| REG   | x27    | Dump registers, PC, and condition codes       |

Trap semantics follow ELK's emulator. `PUTN` and `REG` are debug extensions.

## Building

Requires:

- Zig 0.16.x
- LLVM 15+ (shared library, discovered via `llvm-config`)
- `clang` on `PATH` (for linking)

```sh
# macOS
brew install llvm

# Debian / Ubuntu
apt install llvm-dev
```

```sh
# build to ./zig-out/bin/lcc
zig build
zig build test
```

`zig build test` compiles every example and compares output against
[ELK](https://codeberg.org/dxrcy/elk) if it is installed:

```sh
git clone https://codeberg.org/dxrcy/elk && cd elk
zig build install -Doptimize=ReleaseFast --prefix ~/.local
```

### Testing on Linux

A Dockerfile is included for running the test suite on Ubuntu:

```sh
docker build --platform linux/amd64 -t lcc-test .
docker run --rm lcc-test
```

## Semantic differences from LC-3

lcc is not an emulator. Some behaviors differ from the LC-3
standard. See [docs/behaviour.md](docs/behaviour.md).
