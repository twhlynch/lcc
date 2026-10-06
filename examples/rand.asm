.ORIG x3000

    ld r0, sval
    seed
    rand
    putn
    ld r0, nl
    out
    rand
    putn
    ld r0, nl
    out
    rand
    putn
    halt

sval .FILL #42
nl  .FILL #10

.END
