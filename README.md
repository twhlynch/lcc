# lcc

An LC-3 to LLVM compiler written in Zig.

`lcc` uses [ELK](https://github.com/dxrcy/elk)s, IR directly through its library
API, translates it to LLVM IR, and delegates optimisation and native code
generation to LLVM.

```text
LC-3 -> ELK -> elk.Air -> lcc -> LLVM IR -> LLVM
```

## Usage

```sh
lcc examples/hello.asm
```

Diagnostics are reported by ELK's own infrastructure.

### Flags

| Flag         | Description              |
| ------------ | ------------------------ |
| `-o <file>`  | Output executable        |
| `-O0`..`-O3` | LLVM optimisation levels |

## Build

Requires Zig `0.16.x`

```sh
zig build
zig build test
./zig-out/bin/lcc examples/hello.asm
```
