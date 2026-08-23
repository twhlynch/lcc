.ORIG x3000

    lea r1, Name        ; one-character buffer
    in                  ; prints Input> , reads, echoes
    str r0, r1, #0      ; buffer[0] = character
    and r2, r2, #0
    str r2, r1, #1      ; NUL terminator

    lea r0, Hello
    puts

    lea r0, Name
    puts

    lea r0, Packed      ; two characters per word
    putsp

    halt

Hello  .STRINGZ "\nHello, "
Name   .FILL #0
       .FILL #0
Packed .FILL #20234     ; "\n" + "O"
       .FILL #75        ; "K"

.END
