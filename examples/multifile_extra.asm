; extra file for examples/multifile.asm

.ORIG x3050

    lea r0, Message     ; x3050
    puts                ; x3051
    ret                 ; x3052

    .FILL #42           ; x3053

Message .STRINGZ "Hello from an extra file\n" ; x3053

.END
