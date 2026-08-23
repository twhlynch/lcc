.ORIG x3000

    and r0, r0, #0      ; a = F(0) = 0
    add r1, r1, #1      ; b = F(1) = 1
    add r2, r2, #10     ; n = 10
Loop
    add r3, r0, r1      ; t = a + b
    add r0, r1, #0      ; a = b
    add r1, r3, #0      ; b = t
    add r2, r2, #-1     ; n--
    brp Loop

.END                    ; r0 = F(10) = 55
