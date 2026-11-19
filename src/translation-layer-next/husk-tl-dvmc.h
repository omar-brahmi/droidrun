/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Compiled Dalvik methods: the interface between the runtime and the code tools/dexc/dexc.py generates.
 *
 * dexc.py turns the bytecode of chosen methods of one DEX file into C, one function per method, with the semantics of the
 * interpreter in husk-tl-dvm.c instruction for instruction. clang compiles that C into a dylib named after the DEX file's
 * signature (dexc-v<VERSION>-<first 8 signature bytes in hex>.dylib); the app ships it in its Frameworks folder, signed with the
 * app, so it runs without JIT. When the runtime adds a DEX file it looks for that dylib; each method it links then runs the
 * compiled function instead of the interpreter. A method dexc.py cannot compile (invoke-polymorphic, invoke-custom, method
 * handles) stays interpreted.
 *
 * A compiled function keeps the Dalvik registers in C locals: the collector scans thread registers and stacks, so objects they
 * hold stay alive. Everything that needs the runtime's tables (resolving, calls, allocation, exceptions) goes through dvmc_api,
 * which the runtime hands the dylib once, so the dylib links against nothing of the app.
 */
#ifndef HUSK_TL_DVMC_H
#define HUSK_TL_DVMC_H

#include <stdbool.h>
#include <stdint.h>

#include "husk-tl-jni.h"

#define DVMC_VERSION 3

struct dvm_method;

/* A compiled method: the same contract as the interpreter's. regs: the frame (regs[m->regs - m->ins ..] hold this and the
 * arguments); the result goes to *ret. Returns false when it threw (the exception is pending). */
typedef bool (*dvmc_fn)(struct dvm_method *m, uint64_t *regs, jvalue *ret);

/* A field access site's cache, filled by api->field on first use and while the app stays the same (gen). */
typedef struct dvmc_field {
    uint32_t gen;                       /* *api->gen when filled; 0 never */
    uint8_t how;                        /* DVMC_F_* */
    char type;                          /* the field's descriptor letter, '[' read as 'L' */
    uint32_t slot;                      /* DVMC_F_SLOT: index into the object's slots */
    jvalue *place;                      /* DVMC_F_STATIC: the static's storage (its class initialized) */
} dvmc_field;

enum { DVMC_F_HELPER = 0, DVMC_F_SLOT = 1, DVMC_F_STATIC = 2 };

/* What a call site resolved to, for api->call_words next time: never changed once made (a site that sees another receiver class
 * keeps its first one and takes the slow path for the others), replaced only when *api->gen moves on. */
typedef struct dvmc_target {
    uint32_t gen;
    const void *rcls;                   /* virtual and interface calls: the receiver's class (jobj.cls) it holds for; else NULL */
    struct dvm_method *m;
    dvmc_fn fn;                         /* m's compiled function, or NULL: the site calls it directly when it is one it knows */
} dvmc_target;

typedef struct dvmc_site { const dvmc_target *t; } dvmc_site;

typedef struct dvmc_api {
    uint32_t version;
    const volatile uint32_t *gen;       /* changes when the app's classes are dropped: field caches filled before are stale */
    /* invoke-kind (kind 0 virtual, 1 super, 2 direct, 3 static, 4 interface) with the argument registers' values, wide ones as
     * two words (the second ignored), as the bytecode lists them. *swap_old/new: a String constructor replaced the
     * placeholder object (every register holding old must then hold new). */
    bool (*invoke)(struct dvm_method *caller, uint32_t pc, int kind, uint32_t midx, const uint64_t *w, int n, jvalue *result,
                   jobj **swap_old, jobj **swap_new, dvmc_site *site);
    /* a call through a site's dvmc_target: the arguments go into the callee's frame as they are (the result normalized) */
    bool (*call_words)(struct dvm_method *target, uint32_t pc, const uint64_t *w, int n, jvalue *result);
    /* a field access the inline paths do not cover; fills *c when the site can use them next time */
    bool (*field)(struct dvm_method *m, uint32_t idx, bool is_static, bool put, jobj *o, uint64_t *reg, dvmc_field *c);
    jobj *(*const_string)(struct dvm_method *m, uint32_t idx);
    jobj *(*const_class)(struct dvm_method *m, uint32_t type_idx);
    bool (*check_cast)(struct dvm_method *m, jobj *o, uint32_t type_idx);           /* false: threw */
    int32_t (*instance_of)(struct dvm_method *m, jobj *o, uint32_t type_idx);
    jobj *(*new_instance)(struct dvm_method *m, uint32_t type_idx);                 /* NULL: threw */
    jobj *(*new_array)(struct dvm_method *m, int32_t n, uint32_t type_idx);         /* NULL: threw */
    jobj *(*filled_new_array)(struct dvm_method *m, uint32_t type_idx, const uint64_t *w, int n);
    bool (*fill_array_data)(struct dvm_method *m, jobj *a, uint32_t payload_pc);     /* the payload at that code unit */
    bool (*aput_object)(jobj *a, int32_t i, jobj *v);                                /* the ArrayStoreException check */
    bool (*monitor_enter)(jobj *o);
    bool (*monitor_exit)(jobj *o);
    bool (*throw_obj)(jobj *e);                                                       /* throw: always false */
    bool (*throw_npe)(const char *what);
    bool (*throw_index)(jobj *a, int32_t i);
    bool (*throw_div_zero)(void);
    bool (*throw_neg_size)(int32_t n);
    /* the handler for the pending exception at pc: true with *target and the exception taken off (*caught); false: none here */
    bool (*handler)(struct dvm_method *m, uint32_t pc, uint32_t *target, jobj **caught);
    /* a synchronized method: enters the monitor of its class or of this (regs as the method got them); monitor_exit leaves it */
    jobj *(*sync_enter)(struct dvm_method *m, uint64_t *regs);
    /* a direct call of a compiled method: its frame on the Java stack (false: StackOverflowError thrown, nothing pushed), and off.
     * Methods that call nothing are called without one. */
    bool (*enter)(struct dvm_method *callee, uint32_t caller_pc);
    void (*leave)(void);
    void (*at)(uint32_t pc);            /* the instruction about to throw, for the stack trace's line number */
    /* String.length() and String.charAt(int) of a non-null string; char_at false: StringIndexOutOfBoundsException thrown */
    int32_t (*string_length)(jobj *s);
    bool (*string_char_at)(jobj *s, int32_t i, uint64_t *out);
    bool (*arraycopy)(jobj *src, int32_t sp, jobj *dst, int32_t dp, int32_t n);     /* System.arraycopy */
    /* invoke-polymorphic(/range) with its registers' values (the receiver first), and the call site's proto */
    bool (*invoke_polymorphic)(struct dvm_method *m, uint32_t pc, uint32_t midx, uint32_t proto, const uint64_t *w, int n, jvalue *result);
    bool (*throw_unsupported)(struct dvm_method *m, int op);   /* invoke-custom, const-method-handle/type: as the interpreter */
} dvmc_api;

typedef struct dvmc_entry { uint32_t midx; dvmc_fn fn; } dvmc_entry;

/* What the dylib exports as dvmc_exports: its DEX file's signature, and its methods sorted by method_idx. */
typedef struct dvmc_module {
    uint32_t version;
    uint8_t signature[20];
    uint32_t count;
    const dvmc_entry *entries;
    void (*bind)(const dvmc_api *api);
} dvmc_module;

#endif
