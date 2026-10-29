.ORIG x3000

    ld r0, SeedValue
    seed

    rand
    putn

    ld r0, Nl
    out

    rand
    putn
    ld r0, Nl
    out

    rand
    putn

    halt

SeedValue .FILL #42
Nl        .FILL xA

.END
