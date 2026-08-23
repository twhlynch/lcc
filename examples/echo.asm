.ORIG x3000

Loop
    getc                ; R0 <- one character
    out                 ; echo it
    ld r1, Newline      ; '\n'
    not r1, r1
    add r1, r1, #1
    add r1, r0, r1      ; c == '\n' ?
    brz Done
    br Loop

Done
    halt

Newline .FILL #10

.END
