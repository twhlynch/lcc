# Building a custom Trap library

When you compile with `-dynamic`, the generated binary calls into `liblc3` at
runtime for trap instructions. Each trap is a separate C function, so you can
override traps by providing your own implementation in a custom library.

## Example

Suppose you want `putn` to print numbers in hex instead of decimal.

Start by copying the default runtime and modifying it:

```sh
cp src/runtime/lc3_runtime.c liblc3_custom.c
```

Edit `liblc3_custom.c` and change `lc3_putn`:

```c
void lc3_putn(unsigned short word)
{
    if (!at_newline)
    {
        (void)putchar('\n');
        at_newline = 1;
    }
    (void)printf("0x%04X\n", (unsigned int)word);
    //            ^^^^^^ This part changed!
    (void)fflush(stdout);
}
```

## Building the library

Compile your custom library as a shared library:

```sh
# macOS
clang -shared -o liblc3.dylib liblc3_custom.c -install_name @rpath/liblc3.dylib

# Linux
clang -shared -o liblc3.so liblc3_custom.c -fPIC
```

## Compiling an LC3 program

Write an LC3 program that uses `putn`, for example `demo.asm`:

```asm
.ORIG x3000
    add r0 r0 #10
    putn
.END
```

Compile it with `-dynamic` and `-L` pointing to your library:

```sh
lcc demo.asm -dynamic -L.
```

When `-L` is specified, lcc skips auto-generating `liblc3` and links
directly against the library in the given path.

## Running

```sh
./demo
```

Output with the default liblc3: `10`
Output with your custom liblc3: `0x000A`

## Installing

To make your custom library available to all dynamically linked binaries:

```sh
# macOS
sudo cp liblc3.dylib /usr/local/lib/

# Linux
sudo cp liblc3.so /usr/local/lib/
```

After this, any binary compiled with `-dynamic` (without `-L`) will use your
custom library (unless there is another liblc3 in the current directory).
