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

| Flag          | Description              |
| ------------- | ------------------------ |
| `-o <file>`   | Output executable        |
| `-O0`..`-O3`  | LLVM optimisation levels |
| `--emit-llvm` | Print generated LLVM IR  |

## Build

Requires Zig `0.16.x` and a shared-library LLVM installation (15 or newer,
discovered via `llvm-config`):

```sh
brew install llvm      # macOS
apt install llvm-dev   # Debian/Ubuntu
```

```sh
zig build
zig build test
./zig-out/bin/lcc examples/hello.asm
```
