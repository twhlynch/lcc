; draw a polygon with a set side length, count, and width

.ORIG x3000

    ld r0 PenWidth
    width                ; set pen width

    ld r2, ShapeSides
    brnz Done            ; needs at least one side

    dims                 ; r0 = columns, r1 = rows
    add r6, r1, #-1      ; r6 = the line above the last row

    and r4, r4, #0       ; half the columns to get the center
HalfLoop
    add r0, r0, #-2
    brn HalfDone
    add r4, r4, #1
    brnzp HalfLoop

HalfDone
    ld r5, ShapeLength
    not r5, r5
    add r5, r5, #1       ; r5 = -Length
    add r4, r4, r5       ; half the first side, to center the shape

    and r0, r0, #0
    pen                  ; pen up

    add r0, r4, #0       ; start at bottom center
    add r1, r6, #0
    jump

    and r0, r0, #0
    add r0, r0, #1
    pen                  ; pen down

    ; r1 angle = 360 / Sides
    and r1, r1, #0
    ld r4, WholeTurn

DivLoop
    not r5, r2
    add r5, r5, #1       ; r5 = -Sides
    add r5, r4, r5       ; how much turn is left after one more side
    brn DivDone
    add r4, r5, #0       ; spend it
    add r1, r1, #1       ; one more side worth of turn
    brnzp DivLoop

DivDone
    and r3, r3, #0
    add r3, r3, #1       ; colors cycle starting at 1

DrawLoop
    and r0, r3, xF       ; masks the color to 0-15
    color

    ld r0, ShapeLength
    move

    add r0, r1, #0
    turn

    add r3, r3, #1       ; next colour
    add r2, r2, #-1
    brp DrawLoop

Done
    halt


ShapeLength .FILL #10 ; length of each side
ShapeSides  .FILL #6  ; sides of the polygon. 3 triangle, 4 square, etc
PenWidth    .FILL #1  ; width of lines

WholeTurn .FILL #360

.END
