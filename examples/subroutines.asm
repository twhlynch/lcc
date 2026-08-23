.ORIG x3000

    add r1, r1, #15
    add r1, r1, #6      ; r1 = 21
    jsr Twice           ; r1 = 42
    lea r5, Func        ; r5 = &Func
    jsrr r5             ; r1 = 50
    add r0, r1, #0      ; r0 = 50
    brnzp Tail

Twice
    add r1, r1, r1      ; r1 *= 2
    ret

Func
    add r1, r1, #8      ; r1 += 8
    ret

Tail
    add r0, r0, #0

.END
