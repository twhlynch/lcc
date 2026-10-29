.ORIG x3000

    time
    st r0, Tlo

    add r0, r1, #0
    putn

    ld r0, Nl
    out

    ld r0, Tlo
    putn

    halt

Tlo .FILL #0
Nl  .FILL #10

.END
