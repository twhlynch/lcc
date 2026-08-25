.ORIG x3000

    jsr Sub1

    halt

Sub1
    st r7, SaveR7
    jsr Sub2
    ld r7, SaveR7

    ret

Sub2
    reg

    ret

SaveR7 .FILL #0

.END
