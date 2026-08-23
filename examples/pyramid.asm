; prompts for a height digit (0-9)
; prints a right-aligned pyramid of that height
.ORIG x3000

    lea r0, Prompt
    puts                    ; ask for the height

Read
    getc                    ; read one character without echo
    ld r4, NNewline
    add r4, r0, r4          ; c - '\n'
    brz Read                ; ignore newlines

    ld r3, NZero
    add r3, r0, r3          ; c - '0', negative when below '0'
    brn Bad
    ld r4, NColon
    add r4, r0, r4          ; c - ':', zero or positive when above '9'
    brzp Bad

    out                     ; echo the accepted digit
    ld r0, Newline
    out
    add r1, r3, #0          ; r1 = height

    and r2, r2, #0          ; clear row index
Rows
    add r2, r2, #1          ; i = 1..
    not r4, r2
    add r4, r4, #1
    add r4, r4, r1          ; n - i
    brn Done
    jsr Row                 ; print row i of height n
    brnzp Rows

Done
    halt

; draws one row n-i spaces followed by i stars and a newline
; expects n in r1 and the row index in r2
Row
    not r4, r2
    add r4, r4, #1
    add r4, r4, r1          ; spaces = n - i
Spaces
    brz Stars
    ld r0, Space
    out
    add r4, r4, #-1
    brnzp Spaces
Stars
    add r4, r2, #0          ; stars = i
StarLoop
    brz EndRow
    ld r0, Star
    out
    add r4, r4, #-1
    brnzp StarLoop
EndRow
    ld r0, Newline
    out
    ret

; rejects input outside '0'..'9' and prompts again
Bad
    ld r0, Newline
    out
    lea r0, Prompt
    puts
    brnzp Read

NZero    .FILL #-48          ; -'0'
NColon   .FILL #-58          ; -':'
NNewline .FILL #-10          ; -'\n'
Space    .FILL #32
Star     .FILL #42           ; '*'
Newline  .FILL #10
Prompt   .STRINGZ "Pyramid height (0-9): "

.END
