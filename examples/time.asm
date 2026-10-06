.ORIG x3000

    time
    st r0, tlo
    add r0, r1, #0
    putn
    ld r0, nl
    out
    ld r0, tlo
    putn
    halt

tlo .FILL #0
nl  .FILL #10

.END
