#!/usr/bin/env python3
"""dexc: compile methods of a DEX file to C, for the runtime's compiled-method dylibs (src/translation-layer-next/husk-tl-dvmc.h).

    dexc.py <file.dex | app.apk | lib.jar> <out dir> [--profile FILE]... [--all] [--match TEXT]... [--max N] [--chunk N]

For every DEX file in the input it writes <out dir>/<sig>/dexc-*.c and a build list; build.sh compiles them into
dexc-v<VERSION>-<sig>.dylib. Which methods:
  --profile FILE  the methods a TL_DVM_PROFILE run found hot (lines "<sig> <method_idx> <calls> <loops> ..."), hottest first
  --all           every method with code
  --match TEXT    methods whose "<class>.<name>" contains TEXT (e.g. a benchmark's class)
  --max N         at most N methods per DEX file (default 4000)

Each function does what the interpreter (interpret() in husk-tl-dvm.c) does for each instruction, with the Dalvik registers as
C locals. Methods with invoke-polymorphic, invoke-custom, const-method-handle/type or an unused opcode are left to the interpreter.
"""
import os
import struct
import sys
import zipfile

DVMC_VERSION = 3

# ---------------------------------------------------------------- DEX reading


def uleb(b, p):
    r = s = 0
    while True:
        x = b[p]; p += 1
        r |= (x & 0x7f) << s
        if not x & 0x80:
            return r, p
        s += 7


def sleb(b, p):
    r = s = 0
    while True:
        x = b[p]; p += 1
        r |= (x & 0x7f) << s
        s += 7
        if not x & 0x80:
            break
    if x & 0x40:
        r -= 1 << s
    return r, p


def mutf8(b, p):
    e = b.index(0, p)
    try:
        return b[p:e].decode('utf-8')
    except UnicodeDecodeError:
        return b[p:e].decode('utf-8', 'replace')


class Dex:
    def __init__(self, data, label):
        self.b = data
        self.label = label
        u32 = lambda o: struct.unpack_from('<I', data, o)[0]
        self.sig = data[12:32]
        self.nstr, self.str_off = u32(0x38), u32(0x3c)
        self.ntype, self.type_off = u32(0x40), u32(0x44)
        self.proto_off = u32(0x4c)
        self.field_off = u32(0x54)
        self.nmeth, self.meth_off = u32(0x58), u32(0x5c)
        self.ncls, self.cls_off = u32(0x60), u32(0x64)

    def u16(self, o): return struct.unpack_from('<H', self.b, o)[0]
    def u32(self, o): return struct.unpack_from('<I', self.b, o)[0]

    def string(self, i):
        p = self.u32(self.str_off + 4 * i)
        _, p = uleb(self.b, p)
        return mutf8(self.b, p)

    def type(self, i): return self.string(self.u32(self.type_off + 4 * i))

    def proto(self, i):
        o = self.proto_off + 12 * i
        ret, params = self.type(self.u32(o + 4)), self.u32(o + 8)
        ps = []
        if params:
            n = self.u32(params)
            ps = [self.type(self.u16(params + 4 + 2 * k)) for k in range(n)]
        return ps, ret

    def method_ref(self, i):
        o = self.meth_off + 8 * i
        return self.type(self.u16(o)), self.string(self.u32(o + 4)), self.proto(self.u16(o + 2))

    def field_type(self, i):
        return self.type(self.u16(self.field_off + 8 * i + 2))

    def methods(self):
        """(method_idx, access flags, code_off) of every method with code."""
        for c in range(self.ncls):
            data = self.u32(self.cls_off + 32 * c + 24)
            if not data:
                continue
            p = data
            nsf, p = uleb(self.b, p); nif, p = uleb(self.b, p); ndm, p = uleb(self.b, p); nvm, p = uleb(self.b, p)
            for _ in range(nsf + nif):
                _, p = uleb(self.b, p); _, p = uleb(self.b, p)
            for n in (ndm, nvm):
                idx = 0
                for _ in range(n):
                    d, p = uleb(self.b, p); idx += d
                    flags, p = uleb(self.b, p); code, p = uleb(self.b, p)
                    if code:
                        yield idx, flags, code


def dex_files(path):
    if path.endswith('.dex'):
        with open(path, 'rb') as f:
            yield Dex(f.read(), os.path.basename(path))
        return
    with zipfile.ZipFile(path) as z:
        i = 1
        while True:
            name = 'classes.dex' if i == 1 else f'classes{i}.dex'
            if name not in z.namelist():
                break
            yield Dex(z.read(name), f'{os.path.basename(path)}!{name}')
            i += 1

# ---------------------------------------------------------------- instructions

FMT = {}
def fmt(ops, f):
    for o in ops:
        FMT[o] = f
fmt([0x00, 0x0e] + list(range(0x3e, 0x44)) + [0x73, 0x79, 0x7a] + list(range(0xe3, 0xfa)), '10x')
fmt([0x01, 0x04, 0x07, 0x21] + list(range(0x7b, 0x90)) + list(range(0xb0, 0xd0)), '12x')
fmt([0x02, 0x05, 0x08], '22x')
fmt([0x03, 0x06, 0x09], '32x')
fmt(list(range(0x0a, 0x0e)) + [0x0f, 0x10, 0x11, 0x1d, 0x1e, 0x27], '11x')
fmt([0x12], '11n'); fmt([0x13, 0x16], '21s'); fmt([0x14, 0x17], '31i'); fmt([0x15, 0x19], '21h'); fmt([0x18], '51l')
fmt([0x1a, 0x1c, 0x1f, 0x22, 0xfe, 0xff] + list(range(0x60, 0x6e)), '21c')
fmt([0x1b], '31c')
fmt([0x20, 0x23] + list(range(0x52, 0x60)), '22c')
fmt([0x24, 0xfc] + list(range(0x6e, 0x73)), '35c')
fmt([0x25, 0xfd] + list(range(0x74, 0x79)), '3rc')
fmt([0x26, 0x2b, 0x2c], '31t')
fmt([0x28], '10t'); fmt([0x29], '20t'); fmt([0x2a], '30t')
fmt(list(range(0x2d, 0x32)) + list(range(0x44, 0x52)) + list(range(0x90, 0xb0)), '23x')
fmt(list(range(0x32, 0x38)), '22t'); fmt(list(range(0x38, 0x3e)), '21t')
fmt(list(range(0xd0, 0xd8)), '22s'); fmt(list(range(0xd8, 0xe3)), '22b')
fmt([0xfa], '45cc'); fmt([0xfb], '4rcc')
SIZE = {'10x': 1, '12x': 1, '11n': 1, '11x': 1, '10t': 1, '20t': 2, '22x': 2, '21t': 2, '21s': 2, '21h': 2, '21c': 2, '23x': 2,
        '22b': 2, '22t': 2, '22s': 2, '22c': 2, '30t': 3, '32x': 3, '31i': 3, '31t': 3, '31c': 3, '35c': 3, '3rc': 3,
        '45cc': 4, '4rcc': 4, '51l': 5}
UNSUPPORTED = set([0x73, 0x79, 0x7a] + list(range(0x3e, 0x44)) + list(range(0xe3, 0xfa)))
INVOKES = set(range(0x6e, 0x73)) | set(range(0x74, 0x79)) | {0xfa, 0xfb, 0xfc, 0xfd}


class Unsupported(Exception):
    pass


def s16(x): return x - 0x10000 if x & 0x8000 else x
def s32(x): return x - 0x100000000 if x & 0x80000000 else x


class Method:
    def __init__(self, dex, idx, flags, code_off):
        b = dex.b
        self.dex, self.idx, self.flags = dex, idx, flags
        self.regs, self.ins, self.outs, self.ntries = struct.unpack_from('<HHHH', b, code_off)
        self.ninsns = struct.unpack_from('<I', b, code_off + 12)[0]
        o = code_off + 16
        self.insns = list(struct.unpack_from(f'<{self.ninsns}H', b, o))
        self.tries = []                          # (start, count, [(type_idx | None, addr)])
        if self.ntries:
            t = o + 2 * self.ninsns + (2 if self.ninsns & 1 else 0)
            h0 = t + 8 * self.ntries
            for k in range(self.ntries):
                start, count, hoff = struct.unpack_from('<IHH', b, t + 8 * k)
                p = h0 + hoff
                size, p = sleb(b, p)
                hs = []
                for _ in range(abs(size)):
                    ty, p = uleb(b, p); addr, p = uleb(b, p)
                    hs.append((ty, addr))
                if size <= 0:
                    addr, p = uleb(b, p)
                    hs.append((None, addr))
                self.tries.append((start, count, hs))

    def walk(self):
        """(pc, opcode, units) of each instruction; payloads are skipped."""
        pc, ins = 0, self.insns
        while pc < self.ninsns:
            w = ins[pc]
            op = w & 0xff
            if op == 0 and w in (0x0100, 0x0200, 0x0300):
                if w == 0x0100: n = 4 + ins[pc + 1] * 2
                elif w == 0x0200: n = 2 + ins[pc + 1] * 4
                else: n = 4 + (ins[pc + 1] * (ins[pc + 2] | ins[pc + 3] << 16) + 1) // 2
                pc += n
                continue
            n = SIZE[FMT[op]]
            yield pc, op, ins[pc:pc + n]
            pc += n

    def covered(self, pc):
        return any(s <= pc < s + c for s, c, _ in self.tries)


# ---------------------------------------------------------------- C generation

PRELUDE = r'''/* Generated by tools/dexc/dexc.py: compiled Dalvik methods. Do not edit. */
#include <math.h>
#include <string.h>
#include "husk-tl-dvmc.h"
#pragma clang diagnostic ignored "-Wunused-function"
#pragma clang diagnostic ignored "-Wunused-label"
#pragma clang diagnostic ignored "-Wunused-variable"

extern const dvmc_api *dvmc_A __attribute__((visibility("hidden")));
#define A dvmc_A
#define RI(x) ((int32_t)(uint32_t)(x))
#define WI(x) ((uint64_t)(uint32_t)(int32_t)(x))
#define RJ(x) ((int64_t)(x))
#define WJ(x) ((uint64_t)(int64_t)(x))
#define RL(x) ((jobj *)(uintptr_t)(x))
#define WL(x) ((uint64_t)(uintptr_t)(x))
static inline float RF(uint64_t x) { uint32_t u = (uint32_t)x; float f; memcpy(&f, &u, 4); return f; }
static inline uint64_t WF(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static inline double RD(uint64_t x) { double d; memcpy(&d, &x, 8); return d; }
static inline uint64_t WD(double d) { uint64_t u; memcpy(&u, &d, 8); return u; }
static inline int32_t f2i(float f) { if (isnan(f)) return 0; if (f >= 2147483647.0f) return INT32_MAX; if (f <= -2147483648.0f) return INT32_MIN; return (int32_t)f; }
static inline int64_t f2l(double f) { if (isnan(f)) return 0; if (f >= 9223372036854775807.0) return INT64_MAX; if (f <= -9223372036854775808.0) return INT64_MIN; return (int64_t)f; }
static inline int32_t d2i(double f) { if (isnan(f)) return 0; if (f >= 2147483647.0) return INT32_MAX; if (f <= -2147483648.0) return INT32_MIN; return (int32_t)f; }
static inline int32_t idiv(int32_t a, int32_t b) { return a == INT32_MIN && b == -1 ? a : a / b; }
static inline int32_t irem(int32_t a, int32_t b) { return a == INT32_MIN && b == -1 ? 0 : a % b; }
static inline int64_t ldiv_(int64_t a, int64_t b) { return a == INT64_MIN && b == -1 ? a : a / b; }
static inline int64_t lrem(int64_t a, int64_t b) { return a == INT64_MIN && b == -1 ? 0 : a % b; }
static inline int fcmp(float a, float b, int nan) { return a < b ? -1 : a > b ? 1 : a == b ? 0 : nan; }
static inline int dcmp(double a, double b, int nan) { return a < b ? -1 : a > b ? 1 : a == b ? 0 : nan; }
/* an object's instance slots when the object has slot+1 of them (as dvm_slots_for), else NULL: the helper's case */
static inline jvalue *slot_of(jobj *o, uint32_t slot)
{
    uint32_t n = __atomic_load_n(&o->nfields, __ATOMIC_ACQUIRE);
    jvalue *f = __atomic_load_n(&o->fields, __ATOMIC_ACQUIRE);
    return f && slot < n ? &f[slot] : NULL;
}
static inline int fresh(const dvmc_field *c) { return __atomic_load_n(&c->gen, __ATOMIC_ACQUIRE) == *A->gen; }
'''

# a field's value in a slot (jvalue *s) read into / written from a register expression, by descriptor letter
def slot_read(t, s):
    return {'J': f'WJ({s}->j)', 'D': f'WJ({s}->j)', 'L': f'WL({s}->l)', 'Z': f'(uint64_t)(uint32_t){s}->z',
            'B': f'WI({s}->b)', 'C': f'(uint64_t)(uint32_t){s}->c', 'S': f'WI({s}->s)'}.get(t, f'(uint64_t)(uint32_t){s}->i')


def slot_write(t, s, v):
    if t in 'JD': return f'{s}->j = RJ({v});'
    if t == 'L': return f'{s}->l = RL({v});'
    f = {'Z': ('z', 'uint8_t'), 'B': ('b', 'int8_t'), 'C': ('c', 'uint16_t'), 'S': ('s', 'int16_t')}.get(t, ('i', 'int32_t'))
    return f'{s}->j = 0; {s}->{f[0]} = ({f[1]}){v};'


BIN = {0x0: ('+', 'I'), 0x1: ('-', 'I'), 0x2: ('*', 'I'), 0x3: ('/', 'I'), 0x4: ('%', 'I'), 0x5: ('&', 'I'), 0x6: ('|', 'I'),
       0x7: ('^', 'I'), 0x8: ('<<', 'I'), 0x9: ('>>', 'I'), 0xa: ('>>>', 'I'),
       0xb: ('+', 'J'), 0xc: ('-', 'J'), 0xd: ('*', 'J'), 0xe: ('/', 'J'), 0xf: ('%', 'J'), 0x10: ('&', 'J'), 0x11: ('|', 'J'),
       0x12: ('^', 'J'), 0x13: ('<<', 'J'), 0x14: ('>>', 'J'), 0x15: ('>>>', 'J'),
       0x16: ('+', 'F'), 0x17: ('-', 'F'), 0x18: ('*', 'F'), 0x19: ('/', 'F'), 0x1a: ('%', 'F'),
       0x1b: ('+', 'D'), 0x1c: ('-', 'D'), 0x1d: ('*', 'D'), 0x1e: ('/', 'D'), 0x1f: ('%', 'D')}


def binop(op, k, a, b):
    """C for an operation of kind k on register expressions a, b; returns (expr, needs zero check)."""
    if k == 'I':
        x, y = f'RI({a})', f'RI({b})'
        if op in '+-*': return f'WI((int32_t)((uint32_t){x} {op} (uint32_t){y}))', False
        if op == '/': return f'WI(idiv({x}, {y}))', True
        if op == '%': return f'WI(irem({x}, {y}))', True
        if op == '<<': return f'WI((int32_t)((uint32_t){x} << ({y} & 31)))', False
        if op == '>>': return f'WI({x} >> ({y} & 31))', False
        if op == '>>>': return f'WI((int32_t)((uint32_t){x} >> ({y} & 31)))', False
        return f'WI({x} {op} {y})', False
    if k == 'J':
        x, y = f'RJ({a})', f'RJ({b})'
        if op in '+-*': return f'WJ((int64_t)((uint64_t){x} {op} (uint64_t){y}))', False
        if op == '/': return f'WJ(ldiv_({x}, {y}))', True
        if op == '%': return f'WJ(lrem({x}, {y}))', True
        s = f'(RI({b}) & 63)'
        if op == '<<': return f'WJ((int64_t)((uint64_t){x} << {s}))', False
        if op == '>>': return f'WJ({x} >> {s})', False
        if op == '>>>': return f'WJ((int64_t)((uint64_t){x} >> {s}))', False
        return f'WJ({x} {op} {y})', False
    R, W = ('RF', 'WF') if k == 'F' else ('RD', 'WD')
    if op == '%': return f'{W}({"fmodf" if k == "F" else "fmod"}({R}({a}), {R}({b})))', False
    return f'{W}({R}({a}) {op} {R}({b}))', False


class Callee:
    """A method this dylib compiles, as a call site sees it: its frame, and whether it calls anything (a leaf runs without a
    frame on the Java stack, so a call into it can be inlined whole)."""
    def __init__(self, m):
        self.regs, self.ins = m.regs, m.ins
        self.leaf = not any(op in INVOKES for _, op, _ in m.walk())


class Gen:
    def __init__(self, m, module=None):
        self.m = m
        self.module = module or {}
        self.out = []
        self.targets = set()
        self.has_exc = bool(m.tries)
        self.handler_addrs = sorted({a for _, _, hs in m.tries for _, a in hs})
        self.targets.update(self.handler_addrs)

    def v(self, n):
        if n >= self.m.regs:
            raise Unsupported(f'register v{n} past {self.m.regs}')
        return f'v{n}'

    def at(self, pc):
        return f'A->at({pc}u); '

    def fail(self, pc):
        """what follows a failed step at pc: its handler, or out"""
        return f'{{ epc = {pc}; goto EXC; }}' if self.m.covered(pc) else 'goto FAIL;'

    def emit(self, s):
        self.out.append('    ' + s)

    def gen(self, name):
        m = self.m
        insns = list(m.walk())
        for pc, op, u in insns:
            if op in UNSUPPORTED:
                raise Unsupported(f'opcode {op:#x}')
            f = FMT[op]
            if f in ('10t', '20t', '30t', '21t', '22t'):
                off = {'10t': lambda: (u[0] >> 8) - (0x100 if u[0] & 0x8000 else 0), '20t': lambda: s16(u[1]),
                       '30t': lambda: s32(u[1] | u[2] << 16), '21t': lambda: s16(u[1]), '22t': lambda: s16(u[1])}[f]()
                self.targets.add(pc + off)
            if op in (0x2b, 0x2c):
                for _, t in self.switch_cases(pc, u):
                    self.targets.add(t)
        sync = bool(m.flags & 0x20)
        body = []
        self.out = body
        for pc, op, u in insns:
            if pc in self.targets:
                body.append(f'L{pc}:;')
            self.insn(pc, op, u)
        head = [f'__attribute__((visibility("hidden"))) bool {name}(struct dvm_method *m, uint64_t *regs, jvalue *ret)', '{']
        if m.regs:
            head.append('    uint64_t ' + ', '.join(f'v{i} = regs[{i}]' for i in range(m.regs)) + ';')
        head += ['    jvalue res; res.j = 0;', '    jobj *caught = NULL; uint32_t epc = 0;',
                 '    (void)res; (void)caught; (void)epc; (void)regs;']
        head.append('    jobj *sync = A->sync_enter(m, regs);' if sync else '    jobj *sync = NULL;')
        tail = ['EXC: {', '    uint32_t t; jobj *c = NULL;', '    if (A->handler(m, epc, &t, &c)) { caught = c; switch (t) {']
        tail += [f'        case {a}: goto L{a};' for a in self.handler_addrs]
        tail += ['        default: A->throw_obj(c); break; } }', '}', 'FAIL:', '    if (sync) A->monitor_exit(sync);',
                 '    return false;', 'DONE:', '    if (sync) A->monitor_exit(sync);', '    return true;', '}']
        return '\n'.join(head + body + tail) + '\n'

    def fast_path(self, cls, name, proto, kind, regs, pc, F):
        """C for a call to a library method that is cheaper inline: String.length/charAt, System.arraycopy, Math. Taken once
        the site resolved (its class initialized), as the method would have done."""
        ps, ret = proto
        sig = f'{cls}.{name}({"".join(ps)}){ret}'
        a = [f'w[{i}]' for i in range(len(regs))]
        if sig == 'Ljava/lang/String;.length()I' and kind == 0:
            return (f'int32_t n = A->string_length(RL(w[0])); '
                    f'if (n >= 0) res.j = (uint32_t)n; else if (!A->call_words(t->m, {pc}u, w, 1, &res)) {F}')
        if sig == 'Ljava/lang/String;.charAt(I)C' and kind == 0:
            return (f'if (RL(w[0])->kind == TL_K_STRING) {{ uint64_t c; {self.at(pc)}if (!A->string_char_at(RL(w[0]), RI(w[1]), &c)) {F} res.j = c; }} '
                    f'else if (!A->call_words(t->m, {pc}u, w, 2, &res)) {F}')
        if sig == 'Ljava/lang/System;.arraycopy(Ljava/lang/Object;ILjava/lang/Object;II)V' and kind == 3:
            return f'{self.at(pc)}if (!A->arraycopy(RL(w[0]), RI(w[1]), RL(w[2]), RI(w[3]), RI(w[4]))) {F} res.j = 0;'
        if cls == 'Ljava/lang/Math;' and kind == 3:
            m = {'sqrt(D)D': f'res.j = WD(sqrt(RD({a[0] if a else 0})));' if a else None,
                 'floor(D)D': f'res.j = WD(floor(RD({a[0]})));' if a else None,
                 'ceil(D)D': f'res.j = WD(ceil(RD({a[0]})));' if a else None,
                 'abs(I)I': f'{{ int32_t x = RI({a[0]}); res.j = WI(x < 0 ? (int32_t)(0u - (uint32_t)x) : x); }}' if a else None,
                 'abs(J)J': f'{{ int64_t x = RJ({a[0]}); res.j = WJ(x < 0 ? (int64_t)(0ull - (uint64_t)x) : x); }}' if a else None,
                 'min(II)I': f'res.j = WI(RI({a[0]}) < RI({a[1]}) ? RI({a[0]}) : RI({a[1]}));' if len(a) == 2 else None,
                 'max(II)I': f'res.j = WI(RI({a[0]}) > RI({a[1]}) ? RI({a[0]}) : RI({a[1]}));' if len(a) == 2 else None,
                 'min(JJ)J': f'res.j = WJ(RJ({a[0]}) < RJ({a[2]}) ? RJ({a[0]}) : RJ({a[2]}));' if len(a) == 4 else None,
                 'max(JJ)J': f'res.j = WJ(RJ({a[0]}) > RJ({a[2]}) ? RJ({a[0]}) : RJ({a[2]}));' if len(a) == 4 else None,
                 }.get(f'{name}({"".join(ps)}){ret}')
            return m
        return None

    def switch_cases(self, pc, u):
        ins = self.m.insns
        p = pc + s32(u[1] | u[2] << 16)
        size = ins[p + 1]
        out = []
        if ins[p] == 0x0100:
            first = s32(ins[p + 2] | ins[p + 3] << 16)
            for i in range(size):
                out.append((first + i, pc + s32(ins[p + 4 + 2 * i] | ins[p + 5 + 2 * i] << 16)))
        else:
            for i in range(size):
                k = s32(ins[p + 2 + 2 * i] | ins[p + 3 + 2 * i] << 16)
                t = ins[p + 2 + 2 * size + 2 * i] | ins[p + 3 + 2 * size + 2 * i] << 16
                out.append((k, pc + s32(t)))
        return out

    def insn(self, pc, op, u):
        e, v, d = self.emit, self.v, self.m.dex
        w = u[0]
        A4, B4, AA = (w >> 8) & 0xf, w >> 12, w >> 8
        F = self.fail(pc)
        nxt = pc + len(u)
        if op == 0x00: return
        if op in (0x01, 0x07): e(f'{v(A4)} = {"(uint32_t)" if op == 1 else ""}{v(B4)};'); return
        if op in (0x02, 0x08): e(f'{v(AA)} = {"(uint32_t)" if op == 2 else ""}{v(u[1])};'); return
        if op in (0x03, 0x09): e(f'{v(u[1])} = {"(uint32_t)" if op == 3 else ""}{v(u[2])};'); return
        if op in (0x04, 0x05, 0x06):
            a, b = (A4, B4) if op == 4 else (AA, u[1]) if op == 5 else (u[1], u[2])
            e(f'{{ uint64_t lo = {v(b)}, hi = {v(b + 1)}; {v(a)} = lo; {v(a + 1)} = hi; }}'); return
        if op == 0x0a: e(f'{v(AA)} = (uint32_t)res.i;'); return
        if op == 0x0b: e(f'{v(AA)} = (uint64_t)res.j;'); return
        if op == 0x0c: e(f'{v(AA)} = WL(res.l);'); return
        if op == 0x0d: e(f'{v(AA)} = WL(caught); caught = NULL;'); return
        if op == 0x0e: e('ret->j = 0; goto DONE;'); return
        if op == 0x0f: e(f'ret->j = 0; ret->i = RI({v(AA)}); goto DONE;'); return
        if op == 0x10: e(f'ret->j = RJ({v(AA)}); goto DONE;'); return
        if op == 0x11: e(f'ret->l = RL({v(AA)}); goto DONE;'); return
        if op == 0x12: e(f'{v(A4)} = WI({B4 - 16 if B4 & 8 else B4});'); return
        if op == 0x13: e(f'{v(AA)} = WI({s16(u[1])});'); return
        if op == 0x14: e(f'{v(AA)} = WI({s32(u[1] | u[2] << 16)});'); return
        if op == 0x15: e(f'{v(AA)} = WI({s32(u[1] << 16)});'); return
        if op == 0x16: e(f'{v(AA)} = WJ({s16(u[1])}LL);'); return
        if op == 0x17: e(f'{v(AA)} = WJ({s32(u[1] | u[2] << 16)}LL);'); return
        if op == 0x18:
            x = u[1] | u[2] << 16 | u[3] << 32 | u[4] << 48
            e(f'{v(AA)} = 0x{x:x}ULL;'); return
        if op == 0x19: e(f'{v(AA)} = 0x{u[1] << 48:x}ULL;'); return
        if op in (0x1a, 0x1b):
            idx = u[1] if op == 0x1a else u[1] | u[2] << 16
            e(f'{v(AA)} = WL(A->const_string(m, {idx}u));'); return
        if op == 0x1c: e(f'{self.at(pc)}{v(AA)} = WL(A->const_class(m, {u[1]}u));'); return
        if op == 0x1d: e(f'{{ {self.at(pc)}if (!A->monitor_enter(RL({v(AA)}))) {F} }}'); return
        if op == 0x1e: e(f'{{ {self.at(pc)}if (!A->monitor_exit(RL({v(AA)}))) {F} }}'); return
        # the cast's check first; only a failing one says where, and throws
        if op == 0x1f: e(f'if ({v(AA)} && !A->instance_of(m, RL({v(AA)}), {u[1]}u)) {{ {self.at(pc)}A->check_cast(m, RL({v(AA)}), {u[1]}u); {F} }}'); return
        if op in (0xfe, 0xff, 0xfc, 0xfd): e(f'{self.at(pc)}A->throw_unsupported(m, {op}); {F}'); return
        if op in (0xfa, 0xfb):
            if op == 0xfb: regs = [u[2] + i for i in range(AA)]
            else: regs = [(u[2] >> (4 * i)) & 0xf if i < 4 else A4 for i in range(B4)]
            ws = ', '.join(v(r) for r in regs) or '0'
            e(f'{{ uint64_t w[] = {{ {ws} }}; if (!A->invoke_polymorphic(m, {pc}u, {u[1]}u, {u[3]}u, w, {len(regs)}, &res)) {F} }}'); return
        if op == 0x20: e(f'{v(A4)} = WI(A->instance_of(m, RL({v(B4)}), {u[1]}u));'); return
        if op == 0x21:
            e(f'{{ jobj *a = RL({v(B4)}); if (!a) {{ {self.at(pc)}A->throw_npe("Attempt to get length of null array"); {F} }} '
              f'{v(A4)} = WI((int32_t)(a->kind == TL_K_OBJ_ARRAY ? a->oarr.len : a->arr.len)); }}'); return
        if op == 0x22: e(f'{{ {self.at(pc)}jobj *o = A->new_instance(m, {u[1]}u); if (!o) {F} {v(AA)} = WL(o); }}'); return
        if op == 0x23: e(f'{{ {self.at(pc)}jobj *o = A->new_array(m, RI({v(B4)}), {u[1]}u); if (!o) {F} {v(A4)} = WL(o); }}'); return
        if op in (0x24, 0x25):
            if op == 0x25: regs = [u[2] + i for i in range(AA)]
            else: regs = [(u[2] >> (4 * i)) & 0xf if i < 4 else A4 for i in range(B4)]
            ws = ', '.join(v(r) for r in regs) or '0'
            e(f'{{ uint64_t w[] = {{ {ws} }}; res.l = A->filled_new_array(m, {u[1]}u, w, {len(regs)}); }}'); return
        if op == 0x26:
            e(f'{self.at(pc)}if (!A->fill_array_data(m, RL({v(AA)}), {pc + s32(u[1] | u[2] << 16)}u)) {F}'); return
        if op == 0x27: e(f'{self.at(pc)}A->throw_obj(RL({v(AA)})); {F}'); return
        if op in (0x28, 0x29, 0x2a):
            off = (AA - 0x100 if AA & 0x80 else AA) if op == 0x28 else s16(u[1]) if op == 0x29 else s32(u[1] | u[2] << 16)
            e(f'goto L{pc + off};'); return
        if op in (0x2b, 0x2c):
            e(f'switch (RI({v(AA)})) {{')
            seen = set()
            for k, t in self.switch_cases(pc, u):
                if k in seen: continue
                seen.add(k)
                e(f'case {k}: goto L{t};')
            e('default: break; }'); return
        if op in (0x2d, 0x2e): e(f'{v(AA)} = WI(fcmp(RF({v(u[1] & 0xff)}), RF({v(u[1] >> 8)}), {-1 if op == 0x2d else 1}));'); return
        if op in (0x2f, 0x30): e(f'{v(AA)} = WI(dcmp(RD({v(u[1] & 0xff)}), RD({v(u[1] >> 8)}), {-1 if op == 0x2f else 1}));'); return
        if op == 0x31:
            a, b = v(u[1] & 0xff), v(u[1] >> 8)
            e(f'{v(AA)} = WI(RJ({a}) < RJ({b}) ? -1 : RJ({a}) > RJ({b}));'); return
        if 0x32 <= op <= 0x37:
            a, b = v(A4), v(B4)
            c = {0x32: f'{a} == {b}', 0x33: f'{a} != {b}', 0x34: f'RI({a}) < RI({b})', 0x35: f'RI({a}) >= RI({b})',
                 0x36: f'RI({a}) > RI({b})', 0x37: f'RI({a}) <= RI({b})'}[op]
            e(f'if ({c}) goto L{pc + s16(u[1])};'); return
        if 0x38 <= op <= 0x3d:
            a = v(AA)
            c = {0x38: f'{a} == 0', 0x39: f'{a} != 0', 0x3a: f'RI({a}) < 0', 0x3b: f'RI({a}) >= 0', 0x3c: f'RI({a}) > 0',
                 0x3d: f'RI({a}) <= 0'}[op]
            e(f'if ({c}) goto L{pc + s16(u[1])};'); return
        if 0x44 <= op <= 0x51:
            put = op >= 0x4b
            k = op - 7 if put else op
            arr, idx, val = v(u[1] & 0xff), v(u[1] >> 8), v(AA)
            check = (f'jobj *a = RL({arr}); int32_t i = RI({idx}); '
                     f'if (!a || (uint32_t)i >= (a->kind == TL_K_OBJ_ARRAY ? a->oarr.len : a->arr.len)) {{ {self.at(pc)}A->throw_index(a, i); {F} }}')
            ct = {0x44: 'int32_t', 0x45: 'int64_t', 0x47: 'uint8_t', 0x48: 'int8_t', 0x49: 'uint16_t', 0x4a: 'int16_t'}
            if k == 0x46:
                if put: e(f'{{ {check} if (!{val}) a->oarr.v[i] = NULL; else if (!A->aput_object(a, i, RL({val}))) {{ {self.at(pc)}{F} }} }}')
                else: e(f'{{ {check} {val} = WL(a->oarr.v[i]); }}')
                return
            t = ct[k]
            if put:
                conv = f'RJ({val})' if k == 0x45 else f'({t}){val}' if k != 0x44 else f'RI({val})'
                e(f'{{ {check} (({t} *)a->arr.data)[i] = {conv}; }}')
            else:
                rd = f'(({t} *)a->arr.data)[i]'
                e(f'{{ {check} {val} = {"WJ(" + rd + ")" if k == 0x45 else "WI(" + rd + ")"}; }}')
            return
        if 0x52 <= op <= 0x5f:
            put = op >= 0x59
            t = d.field_type(u[1]); t = 'L' if t[0] == '[' else t[0]
            o, r = v(B4), v(A4)
            e(f'{{ static dvmc_field fc; jobj *o = RL({o}); jvalue *s = o && fresh(&fc) ? slot_of(o, fc.slot) : NULL;')
            if put: e(f'  if (s) {{ {slot_write(t, "s", r)} }}')
            else: e(f'  if (s) {r} = {slot_read(t, "s")};')
            e(f'  else {{ uint64_t x = {r}; {self.at(pc)}if (!A->field(m, {u[1]}u, false, {"true" if put else "false"}, o, &x, &fc)) {F} {"" if put else r + " = x;"} }} }}')
            return
        if 0x60 <= op <= 0x6d:
            put = op >= 0x67
            t = d.field_type(u[1]); t = 'L' if t[0] == '[' else t[0]
            r = v(AA)
            e(f'{{ static dvmc_field fc; if (fresh(&fc)) {{ jvalue *s = fc.place; ' +
              (slot_write(t, 's', r) if put else f'{r} = {slot_read(t, "s")};') + ' }')
            e(f'  else {{ uint64_t x = {r}; {self.at(pc)}if (!A->field(m, {u[1]}u, true, {"true" if put else "false"}, NULL, &x, &fc)) {F} {"" if put else r + " = x;"} }} }}')
            return
        if 0x6e <= op <= 0x72 or 0x74 <= op <= 0x78:
            rng = op >= 0x74
            kind = op - (0x74 if rng else 0x6e)
            if rng: regs = [u[2] + i for i in range(AA)]
            else: regs = [(u[2] >> (4 * i)) & 0xf if i < 4 else A4 for i in range(B4)]
            cls, name, _ = d.method_ref(u[1])
            swap = kind == 2 and cls == 'Ljava/lang/String;' and name == '<init>'
            ws = ', '.join(v(r) for r in regs)
            arr = f'uint64_t w[] = {{ {ws} }}; ' if regs else ''
            wp, n = ('w' if regs else 'NULL'), len(regs)
            e(f'{{ {arr}jobj *so = NULL, *sn = NULL; (void)so; (void)sn; static dvmc_site cs;')
            if not swap:
                # the site's resolved target: called directly while the app is the same (and, virtual, the receiver's class is)
                hit = 't && t->gen == *A->gen'
                if kind in (0, 4):
                    hit += f' && RL(w[0]) && RL(w[0])->kind != TL_K_CLASS && (const void *)RL(w[0])->cls == t->rcls'
                e(f'  const dvmc_target *t = __atomic_load_n(&cs.t, __ATOMIC_ACQUIRE);')
                fast = self.fast_path(cls, name, d.method_ref(u[1])[2], kind, regs, pc, F)
                callee = self.module.get(u[1]) if kind in (0, 2, 3) else None
                if fast:
                    e(f'  if ({hit}) {{ {fast} }}')
                elif callee and callee.ins == n:
                    # a method this dylib compiles: a plain C call (inlined when small), its frame built here
                    first = callee.regs - callee.ins
                    fr = ' '.join(f'f[{first + i}] = w[{i}];' for i in range(n))
                    e(f'  if ({hit} && t->fn == M{u[1]}) {{ uint64_t f[{max(callee.regs, 1)}] = {{ 0 }}; {fr} res.j = 0;')
                    if callee.leaf:
                        e(f'    if (!M{u[1]}(t->m, f, &res)) {F} }}')
                    else:
                        e(f'    if (!A->enter(t->m, {pc}u)) {F} bool ok = M{u[1]}(t->m, f, &res); A->leave(); if (!ok) {F} }}')
                    e(f'  else if ({hit}) {{ if (!A->call_words(t->m, {pc}u, {wp}, {n}, &res)) {F} }}')
                else:
                    e(f'  if ({hit}) {{ if (!A->call_words(t->m, {pc}u, {wp}, {n}, &res)) {F} }}')
                e(f'  else if (!A->invoke(m, {pc}u, {kind}, {u[1]}u, {wp}, {n}, &res, &so, &sn, &cs)) {F}')
            else:
                e(f'  if (!A->invoke(m, {pc}u, {kind}, {u[1]}u, {wp}, {n}, &res, &so, &sn, NULL)) {F}')
                e('  if (so) { ' + ' '.join(f'if (v{i} == WL(so)) v{i} = WL(sn);' for i in range(self.m.regs)) + ' }')
            e('}')
            return
        if 0x7b <= op <= 0x8f:
            a, b = v(A4), v(B4)
            x = {0x7b: f'WI((int32_t)(0u - (uint32_t)RI({b})))', 0x7c: f'WI(~RI({b}))', 0x7d: f'WJ((int64_t)(0ull - (uint64_t)RJ({b})))', 0x7e: f'WJ(~RJ({b}))',
                 0x7f: f'WF(-RF({b}))', 0x80: f'WD(-RD({b}))', 0x81: f'WJ(RI({b}))', 0x82: f'WF((float)RI({b}))',
                 0x83: f'WD((double)RI({b}))', 0x84: f'WI((int32_t)RJ({b}))', 0x85: f'WF((float)RJ({b}))',
                 0x86: f'WD((double)RJ({b}))', 0x87: f'WI(f2i(RF({b})))', 0x88: f'WJ(f2l(RF({b})))',
                 0x89: f'WD((double)RF({b}))', 0x8a: f'WI(d2i(RD({b})))', 0x8b: f'WJ(f2l(RD({b})))',
                 0x8c: f'WF((float)RD({b}))', 0x8d: f'WI((int8_t)RI({b}))', 0x8e: f'WI((uint16_t)RI({b}))',
                 0x8f: f'WI((int16_t)RI({b}))'}[op]
            e(f'{a} = {x};'); return
        if 0x90 <= op <= 0xcf:
            if op < 0xb0: dst, s1, s2 = v(AA), v(u[1] & 0xff), v(u[1] >> 8); k = op - 0x90
            else: dst, s1, s2 = v(A4), v(A4), v(B4); k = op - 0xb0
            sym, kind = BIN[k]
            x, z = binop(sym, kind, s1, s2)
            if z:
                zc = f'RI({s2}) == 0' if kind == 'I' else f'RJ({s2}) == 0'
                e(f'if ({zc}) {{ {self.at(pc)}A->throw_div_zero(); {F} }}')
            e(f'{dst} = {x};'); return
        if 0xd0 <= op <= 0xe2:
            if op <= 0xd7: dst, src, lit, k = v(A4), v(B4), s16(u[1]), op - 0xd0
            else: dst, src, lit, k = v(AA), v(u[1] & 0xff), ((u[1] >> 8) - 0x100 if u[1] & 0x8000 else u[1] >> 8), op - 0xd8
            a = f'RI({src})'
            L = f'((int32_t){lit})'
            x = {0: f'WI((int32_t)((uint32_t){a} + (uint32_t){L}))', 1: f'WI((int32_t)((uint32_t){L} - (uint32_t){a}))',
                 2: f'WI((int32_t)((uint32_t){a} * (uint32_t){L}))', 3: f'WI(idiv({a}, {L}))', 4: f'WI(irem({a}, {L}))',
                 5: f'WI({a} & {L})', 6: f'WI({a} | {L})', 7: f'WI({a} ^ {L})', 8: f'WI((int32_t)((uint32_t){a} << ({L} & 31)))',
                 9: f'WI({a} >> ({L} & 31))', 10: f'WI((int32_t)((uint32_t){a} >> ({L} & 31)))'}[k]
            if k in (3, 4) and lit == 0:
                e(f'{self.at(pc)}A->throw_div_zero(); {F}'); return
            e(f'{dst} = {x};'); return
        raise Unsupported(f'opcode {op:#x}')


# ---------------------------------------------------------------- driver

def read_profile(paths):
    hot = {}
    for p in paths:
        for line in open(p, encoding='utf-8', errors='replace'):
            f = line.split()
            if len(f) < 4: continue
            try:
                key, score = (f[0], int(f[1])), int(f[2]) + int(f[3]) // 4
            except ValueError:
                continue
            hot[key] = max(hot.get(key, 0), score)
    return hot


HOT_SCORE = 50          # calls + loops / 4 in the profiles: below it a method is built small (-Os), not fast


def main():
    args = sys.argv[1:]
    def opt(name, many=False, flag=False):
        vals = []
        while name in args:
            i = args.index(name)
            if flag: del args[i]; return True
            vals.append(args[i + 1]); del args[i:i + 2]
        return vals if many else (vals[0] if vals else None) if not flag else False
    profiles = opt('--profile', many=True)
    everything = opt('--all', flag=True)
    matches = opt('--match', many=True)
    limit = int(opt('--max') or 4000)
    chunk = int(opt('--chunk') or 400)
    if len(args) != 2:
        sys.exit(__doc__)
    src, out = args
    hot = read_profile(profiles)
    for dex in dex_files(src):
        sig = dex.sig[:8].hex()
        chosen = []
        for idx, flags, code in dex.methods():
            score = hot.get((sig, idx))
            cls, name, _ = dex.method_ref(idx)
            label = f'{cls[1:-1]}.{name}'
            if score is None and not everything and not any(t in label for t in matches):
                continue
            chosen.append((-(score or 0), idx, flags, code))
        chosen.sort()
        chosen = chosen[:limit]
        if not chosen:
            print(f'{dex.label}: nothing to compile')
            continue
        d = os.path.join(out, sig)
        os.makedirs(d, exist_ok=True)
        done, skipped, files = [], {}, []
        # hot methods (HOT_SCORE and up) are built for speed, the rest -- run, but rarely -- for size (build.sh: dexc-cold-*.c)
        scores = {idx: -neg for neg, idx, _, _ in chosen}
        bins = {False: [], True: []}
        def flush(cold):
            cur = bins[cold]
            if not cur: return
            fn = os.path.join(d, f'dexc-{"cold-" if cold else ""}{len(files):03d}.c')
            with open(fn, 'w', encoding='utf-8') as f:
                f.write(PRELUDE)
                f.write(''.join(f'bool M{i}(struct dvm_method *, uint64_t *, jvalue *) __attribute__((visibility("hidden")));\n' for i in sorted(module)))
                f.write('\n'.join(cur))
            files.append(fn); cur.clear()
        methods = {idx: Method(dex, idx, flags, code) for _, idx, flags, code in chosen}
        module = {}
        for idx, m in methods.items():
            try:
                Gen(m).gen(f'M{idx}')
                module[idx] = Callee(m)
            except Unsupported:
                pass
        for idx in sorted(methods):
            m = methods[idx]
            cls, name, (ps, ret) = dex.method_ref(idx)
            try:
                body = Gen(m, module).gen(f'M{idx}')
            except Unsupported as x:
                skipped[str(x).split(' past')[0]] = skipped.get(str(x).split(' past')[0], 0) + 1
                continue
            cold = scores.get(idx, 0) < HOT_SCORE
            bins[cold].append(f'/* {cls[1:-1]}.{name}({"".join(ps)}){ret} */\n{body}')
            done.append(idx)
            if len(bins[cold]) >= chunk: flush(cold)
        flush(False); flush(True)
        sigbytes = ', '.join(f'0x{x:02x}' for x in dex.sig)
        with open(os.path.join(d, 'dexc-module.c'), 'w', encoding='utf-8') as f:
            f.write('/* Generated by tools/dexc/dexc.py. Do not edit. */\n#include "husk-tl-dvmc.h"\n\n')
            f.write('__attribute__((visibility("hidden"))) const dvmc_api *dvmc_A;\n')
            for idx in done:
                f.write(f'bool M{idx}(struct dvm_method *, uint64_t *, jvalue *) __attribute__((visibility("hidden")));\n')
            f.write('\nstatic const dvmc_entry entries[] = {\n')
            for idx in done:
                f.write(f'    {{ {idx}u, M{idx} }},\n')
            f.write('};\n\nstatic void bind(const dvmc_api *api) { dvmc_A = api; }\n\n')
            f.write('__attribute__((visibility("default"))) const dvmc_module dvmc_exports = {\n')
            f.write(f'    {DVMC_VERSION}, {{ {sigbytes} }}, {len(done)}u, entries, bind,\n}};\n')
        files.append(os.path.join(d, 'dexc-module.c'))
        with open(os.path.join(d, 'name'), 'w') as f:
            f.write(f'dexc-v{DVMC_VERSION}-{sig}.dylib\n')
        print(f'{dex.label}: {len(done)} methods compiled, {sum(skipped.values())} left to the interpreter '
              f'({sum(1 for i in done if scores.get(i, 0) >= HOT_SCORE)} hot) '
              f'{dict(sorted(skipped.items(), key=lambda x: -x[1])[:5]) if skipped else ""} -> {d}')


if __name__ == '__main__':
    main()
