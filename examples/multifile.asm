; multifile main entry point
;
; extra file loads at x3050
;
;   lcc examples/multifile.asm examples/multifile_extra.asm

.ORIG x3000

    ld r2, Sub         ; r2 = x3050, the extra files entry point
    jsrr r2            ; call it; prints the greeting
    ld r2, Answer      ; r2 = x3053, the extra files data word
    ldr r0, r2, #0     ; r0 = 42
    putn               ; print it
    halt

Sub    .FILL x3050
Answer .FILL x3053

.END
