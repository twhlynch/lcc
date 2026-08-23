.ORIG x3000

    ld r1, Ten          ; r1 = mem[Ten] = 10
    lea r2, Buffer      ; r2 = &Buffer
    str r1, r2, #0      ; mem[Buffer] = 10
    ldr r3, r2, #0      ; r3 = 10
    add r3, r3, r1      ; r3 = 20
    st r3, Dest         ; mem[Dest] = 20
    lea r5, Dest        ; r5 = &Dest
    st r5, DPtr         ; mem[DPtr] = &Dest
    ldi r4, DPtr        ; r4 = mem[mem[DPtr]] = 20
    add r4, r4, #-8     ; r4 = 12
    add r0, r4, #0      ; r0 = 12
    brnzp Tail

Ten    .FILL #10
DPtr   .FILL #0
Buffer .FILL #0
Dest   .FILL #0

Tail
    add r0, r0, #0

.END
