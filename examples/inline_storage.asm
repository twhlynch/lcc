.ORIG x3000

A       .FILL #1

        lea  r0, A
        str  r1, r0, #3 ; mess up next instruction
        add  r1, r0, #1
        sti  r1, B

B       .FILL #0
        .FILL xF027 ; trap reg

        reg

        halt

.END
