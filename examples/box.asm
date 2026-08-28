; draws an n x m box using unicode box-drawing chars
; usage: ./box <width> <height> (single digits only)
;
; all box chars are U+25xx, encoded as 3 UTF-8 bytes each
; 0xE2 0x94 <byte3> the first two bytes are shared, so
; Put3 saves R0, emits the prefix, then emits R0
;
; r1 = width          r2 = height
; r3 = row counter    r4 = col counter

.ORIG x3000

; MARK: argument parsing

    ;;; read width digit ;;;

    ; getc returns ASCII
    ; subtract newline to detect end of input
    ; otherwise subtract '0' (48) to convert to a number

    getc
    add r5, r0, #-10       ; newline?
    brz Default            ; no args, use defaults
    ld r5, Neg48           ; r5 = -48
    add r1, r0, r5         ; r1 = digit value

    ;;; skip arg spaces ;;;

    ; argv is space joined
    ; subtract ' ' (32) to detect, skip it, and keep reading

SkipSp
    getc
    add r5, r0, #-10       ; newline?
    brz Default            ; no height arg, use defaults
    add r5, r0, #-16
    add r5, r5, #-16       ; r5 = r0 - 32 (space)
    brz SkipSp             ; repeat rest

    ;;; read height digit ;;;

    ; same ASCII to digit logic as width
    ; but no newline check needed

    ld r5, Neg48
    add r2, r0, r5         ; r2 = digit value
    br Ready

    ;;; set defaults ;;;

    ; jump here if args are malformed
    ; default is 8x3 (nice and even visually)

Default
    and r1, r1, #0
    add r1, r1, #8         ; width
    and r2, r2, #0
    add r2, r2, #3         ; height

; MARK: drawing

    ;;; inputs ready ;;;

Ready
    add r3, r2, #0         ; r3 = row counter

    ;;; top border ;;;

    ld r0, CharTL          ; top left corner
    jsr Put3               ; print

    ld r0, CharH           ; horizontal line
    add r4, r1, #0         ; r4 = col counter
Top
    jsr Put3               ; print
    add r4, r4, #-1        ; col--
    brp Top                ; loop width times

    ld r0, CharTR          ; top right corner
    jsr Put3               ; print

    jsr Newline            ; newline

    ;;; middle rows ;;;

Row
    add r3, r3, #0         ; rows left?
    brz Bottom

    ld r0, CharV           ; vertical line
    jsr Put3               ; print

    add r4, r1, #0         ; r4 = col counter
Mid
    ld r0, CharSp          ; space
    out                    ; print
    add r4, r4, #-1        ; col--
    brp Mid                ; loop width times

    ld r0, CharV           ; vertical line
    jsr Put3               ; print

    jsr Newline            ; newline

    add r3, r3, #-1        ; row--
    br Row                 ; next row

    ;;; bottom border ;;;

Bottom
    ld r0, CharBL          ; bottom left corner
    jsr Put3               ; print
    ld r0, CharH           ; horizontal line

    add r4, r1, #0         ; r4 = col counter
Bot
    jsr Put3               ; print
    add r4, r4, #-1        ; col--
    brp Bot                ; loop width times

    ld r0, CharBR          ; bottom right corner
    jsr Put3               ; print

    jsr Newline            ; newline

    ;;; done ;;;

    halt

; MARK: subroutines

;; print a box drawing char as 3 UTF-8 bytes 0xE2 0x94 <byte3> where the first
;; 2 bytes are always the same and the input is the third
;;
;; input:     R0 = third UTF-8 byte
;; modifies:  R5
Put3
    add r5, r0, #0         ; store third byte

    ld r0, Utf8_1          ; first byte
    out                    ; print

    ld r0, Utf8_2          ; second byte
    out                    ; print

    add r0, r5,  #0        ; load third byte
    out                    ; print

    ret

;; print a newline
Newline
    ld r0, NewlineChar
    out
    ret

; MARK: data

Neg48       .FILL #-48 ; ASCII digit to number
CharSp      .FILL x20  ; space
NewlineChar .FILL x0A  ; \n

Utf8_1      .FILL xE2  ; first byte of 3-byte UTF-8 prefix
Utf8_2      .FILL x94  ; second byte of 3-byte UTF-8 prefix

CharTL      .FILL x8C  ; top left     U+250C third byte
CharTR      .FILL x90  ; top right    U+2510 third byte
CharBL      .FILL x94  ; bottom left  U+2514 third byte
CharBR      .FILL x98  ; bottom right U+2518 third byte
CharH       .FILL x80  ; horizontal   U+2500 third byte
CharV       .FILL x82  ; vertical     U+2502 third byte

.END
