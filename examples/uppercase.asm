; reads one character with GETC
; prints it converted to upper case
.ORIG x3000

    getc                ; read a character without echo
    ld r1, ALow         ; 'a'
    not r2, r1
    add r2, r2, #1      ; r2 = -'a'
    add r2, r0, r2      ; c - 'a'
    brn Print           ; below 'a', leave as is
    ld r1, AHigh        ; 'z'
    not r2, r1
    add r2, r2, #1
    add r2, r0, r2      ; c - 'z'
    brp Print           ; above 'z', leave as is
    ld r1, Shift        ; 32
    not r2, r1
    add r2, r2, #1
    add r0, r0, r2      ; c -= 32

Print
    out
    halt

ALow  .FILL #97         ; 'a'
AHigh .FILL #122        ; 'z'
Shift .FILL #32

.END
