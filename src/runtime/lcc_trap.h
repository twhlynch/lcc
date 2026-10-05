/*
 * lcc trap ABI
 *
 * every trap handler receives one pointer to this context. lcc scans trap set
 * sources for LCC_TRAP declarations to learn each vector's mnemonic and
 * symbol. The compiled handlers are linked into the executable.
 *
 * lcc force-includes this header when compiling trap sets and the runtime, so
 * the macros are always available. including it explicitly is harmless.
 */
#ifndef LCC_TRAP_H
#define LCC_TRAP_H

typedef struct lcc_trap_ctx // NOLINT(modernize-use-using)
{
	/* 65536 word address space */
	unsigned short *memory;
	/* R0-R7 */
	unsigned short *reg;
	/* PC of the next instruction */
	unsigned short pc;
	/* condition code value */
	unsigned short *cc;
} lcc_trap_ctx;

#ifdef __cplusplus
#define LCC_EXTERN extern "C"
#else
#define LCC_EXTERN
#endif

/*
 * declares a trap handler for vector `vect` with the mnemonic `name`, e.g.
 * LCC_TRAP(0x28, chat). lcc finds these declarations by scanning the source,
 * so keep each invocation on one line. the handler body follows the macro call
 * as a normal function definition.
 */
#define LCC_TRAP(vect, name) LCC_EXTERN void lcc_trap_##name(lcc_trap_ctx *ctx) // NOLINT

/*
 * extra flags appended to the link command when the set is used, e.g.
 * LCC_LINK(-lmcpp). one flag per comma-separated argument. Expands to nothing.
 * lcc finds it by scanning the source like LCC_TRAP.
 */
#define LCC_LINK(...)

#endif
