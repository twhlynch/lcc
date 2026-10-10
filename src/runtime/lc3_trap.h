/*
 * lcc trap ABI
 *
 * every trap handler receives one pointer to this context. lcc scans trap set
 * sources for LC3_TRAP declarations to learn each vector's mnemonic and
 * symbol. The compiled handlers are linked into the executable.
 *
 * lcc force-includes this header when compiling trap sets and the runtime, so
 * the macros are always available. including it explicitly is harmless.
 */
#ifndef LC3_TRAP_H
#define LC3_TRAP_H

typedef struct lc3_trap_ctx // NOLINT(modernize-use-using)
{
	/* 65536 word address space */
	unsigned short *memory;
	/* R0-R7 */
	unsigned short *reg;
	/* PC of the next instruction */
	unsigned short pc;
	/* condition code value */
	unsigned short *cc;
} lc3_trap_ctx;

#ifdef __cplusplus
#define LC3_EXTERN extern "C"
#else
#define LC3_EXTERN
#endif

/*
 * declares a trap handler for vector `vect` with the mnemonic `name`, e.g.
 * LC3_TRAP(0x28, chat). lcc finds these declarations by scanning the source,
 * so keep each invocation on one line. the handler body follows the macro call
 * as a normal function definition.
 */
#define LC3_TRAP(vect, name) LC3_EXTERN void lc3_trap_##name(lc3_trap_ctx *ctx) // NOLINT

/*
 * extra flags appended to the link command when the set is used, e.g.
 * LC3_LINK(-lmcpp). one flag per comma-separated argument. Expands to nothing.
 * lcc finds it by scanning the source like LC3_TRAP.
 */
#define LC3_LINK(...)

#endif
