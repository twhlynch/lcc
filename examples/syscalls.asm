; write a file, print its size, read it back, seek into it, then delete it
; lcc examples/syscalls.asm -traps src/runtime/sets/syscalls.c

.ORIG x3000

    lea r0, Fname
    ld r1, Wmode
    open
    brn Fail
    st r0, Fd

    ld r0, Fd
    lea r1, Msg
    ld r2, Mlen
    write
    brn Fail

    ld r0, Fd
    close
    brn Fail

    ; read the file back and print it
    lea r0, Fname
    ld r1, Rmode
    open
    brn Fail
    st r0, Fd

    ld r0, Fd
    size
    brn Fail
    putn
    ld r0, Nl
    out

    ld r0, Fd
    lea r1, Buf
    ld r2, Mlen
    read
    brn Fail

    lea r3, Buf
    add r3, r3, r0
    and r0, r0, #0
    str r0, r3, #0
    lea r0, Buf
    puts
    ld r0, Nl
    out

    ; seek past the first character and print the rest
    ld r0, Fd
    ld r1, One
    and r2, r2, #0
    and r3, r3, #0
    seek
    brn Fail

    ld r0, Fd
    lea r1, Buf
    ld r2, Rest
    read
    brn Fail

    lea r3, Buf
    add r3, r3, r0
    and r0, r0, #0
    str r0, r3, #0
    lea r0, Buf
    puts
    ld r0, Nl
    out

    ld r0, Fd
    close
    brn Fail

    lea r0, Fname
    remove
    brn Fail
    halt

Fail
    lea r0, Errmsg
    puts
    halt

Fname  .STRINGZ ".lcc-test/note.txt"
Msg    .STRINGZ "lcc"
Errmsg .STRINGZ "error"
Fd     .FILL #0
Buf    .BLKW #8
Wmode  .FILL #1
Rmode  .FILL #0
Mlen   .FILL #3
Rest   .FILL #2
One    .FILL #1
Nl     .FILL #10

.END
