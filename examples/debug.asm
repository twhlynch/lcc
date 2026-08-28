.ORIG x3000

    and r0, r0, #0      ; r0 = sum
    and r1, r1, #0      ; r1 = counter
    and r2, r2, #0
    add r2, r2, #10     ; r2 = limit
    and r7, r7, #0      ; clear link register

Loop
    add r1, r1, #1      ; counter++
    add r0, r0, r1      ; sum += counter
    putn                ; print running total
    not r3, r2
    add r3, r3, #1
    add r3, r1, r3      ; r3 = counter - limit
    brnz Loop

    halt

.END
