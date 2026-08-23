.ORIG x3000

    and r1, r1, #0      ; sum = 0
    add r2, r2, #5      ; counter = 5
Loop
    add r1, r1, r2      ; sum += counter
    add r2, r2, #-1     ; counter--
    brp Loop            ; repeat while counter > 0
    add r0, r1, #0      ; r0 = 15

.END
