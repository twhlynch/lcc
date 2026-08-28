.ORIG x3000

    jsr Sub1

    halt

Sub1
    add r0, r7, #0
    putn

    st r7, SaveR7
    jsr Sub2

    add r0, r7, #0
    putn

    ld r7, SaveR7

    add r0, r7, #0
    putn

    ret

Sub2
    add r0, r7, #0
    putn

    ret

SaveR7 .FILL #0

.END
