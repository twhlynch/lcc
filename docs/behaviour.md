# Behavior where lcc differs from LC3

lcc compiles LC3 assembly to native code via LLVM. This introduces semantic
differences from standard LC3 emulators. This document defines how lcc differs
from traditional LC3.

## Raw words are always NOPs

LC3 memory contains raw 16-bit values and the CPU decodes whatever the PC points
to as an instruction. This means a `.FILL x1234` would decode as a valid `ADD
R1, R0, #-12`.

In lcc `.FILL`/`.BLKW`/`.STRINGZ` directives placed between instructions are
treated as **NOPs** in every case. Execution will fall through to the next word,
and the stored value is still accessible via `LD`/`ST`/`LEA`/`LDR`/`STR`.

This means for the following code:

```asm
Var .FILL xF025 ; equivelant to halt

    lea r0, Var
    add r0, r0, #1
    str r0, r0, #0
```

LC3 says the code should execute `.FILL xF025` as a `halt` instruction, skipping
the entire program. In lcc, it skips over it silently.

## Self modifying code

Writing to instruction memory (`STR`/`STI` to an address containing code) can
create self modifying code in LC3. But in lcc, the compiled program contains
native assembly instructions, not 16-bit LC3 words. Overwriting a "word" in
memory does not modify the corresponding native instruction.

On real LC3, self-modifying code works because instructions are just specific
memory values but in lcc, storage is separate from the program, so an
instruction and memory value can be at the same address.

This means for the following code:

```asm
    lea r0, Var
    str r0, r0, #3 ; override the next line with halt
    reg
    halt

Var .FILL xF025 ; equivelant to halt
```

LC3 should override the `reg` instruction with `halt` but in lcc it will stay
`reg`, despite the value from `r0` also being stored in `[Var+3]`.

## No supervisor

LC3 supports interrupts via `RTI`, and privelaged memory (< `x3000`) containing
e.g., the supervisor stack. lcc does not implement interrupt handling, and
compiles everything as a single user-mode program so accessing privelaged memory
will work.

This means for the following code:

```asm
Z   .FILL x0

    ld r0 Z
    str r0 r0 #0
```

LC3 should assert the attempt to access supervisor-only memory while in user
mode, but lcc just sets `x0` to `0`.
