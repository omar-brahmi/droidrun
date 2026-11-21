/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * A garbage collector for the Java objects of Husk's Dalvik runtime: until it, nothing a Java app made was ever freed, and an app
 * that makes strings and arrays as fast as an ad SDK or a video player does used up the phone's address space within a minute.
 *
 * Conservative, non-moving mark and sweep, stopping the world:
 *  - every object comes from obj_alloc (husk-tl-jni.c), which registers it here;
 *  - the roots are every word of the process's own writable memory -- thread stacks and registers, globals, the malloc heap, the
 *    mmaps of Android libraries -- EXCEPT the memory of Java objects themselves (the jobj, its fields, its array storage, its
 *    string text). So anything C code, Android native code, JNI tables or the interpreter's frames hold stays alive without each
 *    holder being known; only objects that nothing outside the Java heap reaches, and no live object reaches, are garbage;
 *  - from the roots, marking follows instance fields and object-array elements.
 * A word that is not a pointer but looks like one keeps an object alive: memory left over, never an object freed in use.
 *
 * TL_GC=0 turns it off, TL_GC=dry marks and reports without freeing; TL_GC_EVERY=<objects made between collections>.
 */
#include "husk-tl-jni.h"

#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <setjmp.h>
#include <signal.h>
#include <unistd.h>

void tl_log_line(const char *fmt, ...);
extern const void *_dyld_get_shared_cache_range(size_t *length) __attribute__((weak_import));   /* dyld, not in its public headers */

#define GC_TAG 250                      /* VM tag of the collector's own memory: never scanned (the registry names every object) */
#define DATA_TAG 251                    /* memory that holds no pointers (tl_gc_alloc_data): never scanned either */
#define DATA_MAP_MIN (64u << 10)        /* smaller blocks come from malloc */
#define EMPTY ((uintptr_t)0)
#define GONE ((uintptr_t)1)

static void *gc_map(size_t bytes)
{
    void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, VM_MAKE_TAG(GC_TAG), 0);
    return p == MAP_FAILED ? NULL : p;
}

/* ------------------------------------------------------------ registry: every live object, open addressing */

static pthread_mutex_t g_reg = PTHREAD_MUTEX_INITIALIZER;
static uintptr_t *g_tab;                /* object addresses; EMPTY, GONE (a removed one) */
static size_t g_cap, g_count, g_used;   /* g_used: slots not EMPTY */
static uint64_t g_made;                 /* objects registered since the last collection */
static int g_mode = -1;                 /* 0 off, 1 dry, 2 on */
static uint64_t g_every = 300000;
static uint64_t g_due = 300000;         /* objects made before the next collection: twice those alive after the last, g_every at least */

static inline size_t hash_ptr(uintptr_t p, size_t mask) { p >>= 4; p ^= p >> 17; p *= 0xed5ad4bbu; p ^= p >> 11; return (size_t)p & mask; }

static bool reg_grow(void)
{
    size_t ncap = g_cap ? g_cap * 2 : (1u << 20);
    uintptr_t *n = gc_map(ncap * sizeof(uintptr_t));
    if (!n) return false;
    size_t mask = ncap - 1;
    for (size_t i = 0; i < g_cap; i++) {
        uintptr_t p = g_tab[i];
        if (p <= GONE) continue;
        size_t h = hash_ptr(p, mask);
        while (n[h]) h = (h + 1) & mask;
        n[h] = p;
    }
    if (g_tab) munmap(g_tab, g_cap * sizeof(uintptr_t));
    g_tab = n; g_cap = ncap; g_used = g_count;
    return true;
}

static void mode_init(void)
{
    const char *m = getenv("TL_GC");
    g_mode = !m ? 2 : !strcmp(m, "0") ? 0 : !strcmp(m, "dry") ? 1 : 2;
    if (getenv("TL_GC_EVERY")) { long v = atol(getenv("TL_GC_EVERY")); if (v > 1000) g_every = (uint64_t)v; }
    g_due = g_every;
    tl_log_line("gc: %s, a collection every %llu objects", g_mode == 0 ? "off" : g_mode == 1 ? "dry run (nothing freed)" : "on",
                (unsigned long long)g_every);
}

static void collect(void);

void tl_gc_register(jobj *o)
{
    if (!o) return;
    pthread_mutex_lock(&g_reg);
    if (g_mode < 0) mode_init();
    if ((g_used + 1) * 2 > g_cap && !reg_grow()) { pthread_mutex_unlock(&g_reg); return; }   /* unregistered: never freed */
    size_t mask = g_cap - 1, h = hash_ptr((uintptr_t)o, mask);
    while (g_tab[h] > GONE) h = (h + 1) & mask;
    if (g_tab[h] == EMPTY) g_used++;
    g_tab[h] = (uintptr_t)o;
    g_count++;
    bool due = g_mode > 0 && ++g_made >= g_every;
    pthread_mutex_unlock(&g_reg);
    (void)due;
}

/* Before an object is made (obj_alloc): the collection runs here, where the thread holds no half-made object. */
void tl_gc_before_alloc(void)
{
    if (g_mode > 0 && __atomic_load_n(&g_made, __ATOMIC_RELAXED) >= __atomic_load_n(&g_due, __ATOMIC_RELAXED)) collect();
}

/* An object freed elsewhere (tl_jni_unref, before the Java runtime is up). */
void *tl_gc_alloc_data(size_t bytes)
{
    if (bytes < DATA_MAP_MIN) return calloc(1, bytes ? bytes : 1);
    void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, VM_MAKE_TAG(DATA_TAG), 0);
    return p == MAP_FAILED ? NULL : p;
}

void tl_gc_free_data(void *p, size_t bytes)
{
    if (!p) return;
    if (bytes < DATA_MAP_MIN) free(p); else munmap(p, bytes);
}

void tl_gc_forget(jobj *o)
{
    if (!o || !g_tab) return;
    pthread_mutex_lock(&g_reg);
    size_t mask = g_cap - 1, h = hash_ptr((uintptr_t)o, mask);
    for (size_t n = 0; g_tab[h] != EMPTY && n < g_cap; n++, h = (h + 1) & mask)
        if (g_tab[h] == (uintptr_t)o) { g_tab[h] = GONE; g_count--; break; }
    pthread_mutex_unlock(&g_reg);
}

static inline size_t reg_find(uintptr_t p)      /* the slot of the object at p, or SIZE_MAX */
{
    size_t mask = g_cap - 1, h = hash_ptr(p, mask);
    for (size_t n = 0; n < 64; n++, h = (h + 1) & mask) {
        uintptr_t v = g_tab[h];
        if (v == p) return h;
        if (v == EMPTY) return SIZE_MAX;
    }
    for (size_t n = 64; n < g_cap; n++, h = (h + 1) & mask) {      /* a long probe run: rare */
        uintptr_t v = g_tab[h];
        if (v == p) return h;
        if (v == EMPTY) return SIZE_MAX;
    }
    return SIZE_MAX;
}

/* ------------------------------------------------------------ one collection */

typedef struct { uintptr_t lo, hi; } range;

/* The memory a Java object owns: never a root. Pointer-free blocks are listed too, so scanning skips them. */
typedef struct {
    range *own; size_t nown, capown;               /* sorted by lo */
    uintptr_t *okey; uint32_t *oval; size_t ocap;  /* start of an owned block -> its object's slot (fields, arrays, text) */
    uint8_t *mark;                                 /* by registry slot */
    uint32_t *work; size_t nwork, capwork;
    uintptr_t lo, hi;                              /* the lowest and highest object address */
    uintptr_t olo, ohi;                            /* the lowest and highest owned block start */
    thread_t *stopped; size_t nstopped, capstopped;
    size_t marked, roots_words;
} gcstate;

static gcstate S;

static inline void own_add(uintptr_t lo, size_t bytes)
{
    if (!lo || !bytes || S.nown >= S.capown) return;
    S.own[S.nown].lo = lo; S.own[S.nown].hi = lo + bytes; S.nown++;
}

static inline void okey_add(uintptr_t start, uint32_t slot)
{
    if (!start) return;
    if (start < S.olo) S.olo = start;
    if (start > S.ohi) S.ohi = start;
    size_t mask = S.ocap - 1, h = hash_ptr(start, mask);
    for (size_t n = 0; n < S.ocap; n++, h = (h + 1) & mask)
        if (!S.okey[h]) { S.okey[h] = start; S.oval[h] = slot; return; }
}

static inline size_t okey_find(uintptr_t p)
{
    size_t mask = S.ocap - 1, h = hash_ptr(p, mask);
    for (size_t n = 0; n < S.ocap; n++, h = (h + 1) & mask) {
        if (S.okey[h] == p) return S.oval[h];
        if (!S.okey[h]) return SIZE_MAX;
    }
    return SIZE_MAX;
}

/* Roots are found by several threads at once (scan_parallel); each keeps the objects it marks in a work list of its own, and the
 * marks are taken with an atomic exchange, so an object goes into exactly one list. */
typedef struct { uint32_t *work; size_t nwork, capwork, marked, words, unreadable; uintptr_t first_fault; } marker;

static inline void mark_slot_in(marker *k, size_t slot)
{
    if (__atomic_load_n(&S.mark[slot], __ATOMIC_RELAXED)) return;
    if (__atomic_exchange_n(&S.mark[slot], 1, __ATOMIC_RELAXED)) return;
    k->marked++;
    if (k->nwork < k->capwork) k->work[k->nwork++] = (uint32_t)slot;
    else S.mark[slot] = 2;                          /* the work list is full: traced in a later pass */
}

static inline void consider_in(marker *k, uintptr_t w)
{
    if (w < S.lo || w > S.hi || (w & 7)) {
        /* not an object, but it may be the start of an object's fields, array or text (JNI's Get*Elements hand those out) */
        if (w < S.olo || w > S.ohi) return;
    } else {
        size_t s = reg_find(w);
        if (s != SIZE_MAX) { mark_slot_in(k, s); return; }
        if (w < S.olo || w > S.ohi) return;
    }
    size_t s = okey_find(w);
    if (s != SIZE_MAX) mark_slot_in(k, s);
}

static marker M0;                                   /* the collecting thread's: the registers and the trace */
static inline void consider(uintptr_t w) { consider_in(&M0, w); }

static void scan_words_in(marker *k, uintptr_t lo, uintptr_t hi)
{
    lo = (lo + 7) & ~(uintptr_t)7;
    for (uintptr_t p = lo; p + 8 <= hi; p += 8) consider_in(k, *(const uintptr_t *)p);
    k->words += (hi - lo) / 8;
}
static inline void scan_words(uintptr_t lo, uintptr_t hi) { scan_words_in(&M0, lo, hi); }

/* [lo, hi) less the owned blocks inside it */
static void scan_range_in(marker *k, uintptr_t lo, uintptr_t hi)
{
    size_t a = 0, b = S.nown;
    while (a < b) { size_t m = (a + b) / 2; if (S.own[m].hi <= lo) a = m + 1; else b = m; }
    uintptr_t p = lo;
    for (size_t i = a; i < S.nown && S.own[i].lo < hi && p < hi; i++) {
        if (S.own[i].lo > p) scan_words_in(k, p, S.own[i].lo < hi ? S.own[i].lo : hi);
        if (S.own[i].hi > p) p = S.own[i].hi;
    }
    if (p < hi) scan_words_in(k, p, hi);
}

/* LSD radix sort of the owned blocks by start, 16 bits a pass over the bits that differ (a heapsort of a few million blocks took
 * longer than the rest of the pause). tmp: as many ranges, made before the world stopped; counts: 65536 entries. */
static void sort_own(range *tmp, size_t *counts)
{
    range *v = S.own; size_t n = S.nown;
    uintptr_t lo = UINTPTR_MAX, hi = 0;
    for (size_t i = 0; i < n; i++) { if (v[i].lo < lo) lo = v[i].lo; if (v[i].lo > hi) hi = v[i].lo; }
    if (n < 2) return;
    uintptr_t span = hi - lo;
    range *src = v, *dst = tmp;
    for (int shift = 0; shift < 64 && (span >> shift); shift += 16) {
        memset(counts, 0, 65536 * sizeof(size_t));
        for (size_t i = 0; i < n; i++) counts[((src[i].lo - lo) >> shift) & 0xffff]++;
        size_t sum = 0;
        for (size_t d = 0; d < 65536; d++) { size_t c = counts[d]; counts[d] = sum; sum += c; }
        for (size_t i = 0; i < n; i++) dst[counts[((src[i].lo - lo) >> shift) & 0xffff]++] = src[i];
        range *t = src; src = dst; dst = t;
    }
    if (src != v) memcpy(v, src, n * sizeof(range));
}

/* from the objects in k's work list, everything they reach (each object is traced by the one thread whose list it went into) */
static void trace_in(marker *k)
{
    while (k->nwork) {
        jobj *o = (jobj *)g_tab[k->work[--k->nwork]];
        if (o->fields) scan_words_in(k, (uintptr_t)o->fields, (uintptr_t)(o->fields + o->nfields));
        if (o->kind == TL_K_OBJ_ARRAY && o->oarr.v) scan_words_in(k, (uintptr_t)o->oarr.v, (uintptr_t)(o->oarr.v + o->oarr.len));
        consider_in(k, (uintptr_t)o->native);
    }
}
static void trace_parallel(void);

static void trace(void)
{
    trace_parallel();
    for (;;) {
        while (M0.nwork) {
            jobj *o = (jobj *)g_tab[M0.work[--M0.nwork]];
            if (o->fields) scan_words((uintptr_t)o->fields, (uintptr_t)(o->fields + o->nfields));
            if (o->kind == TL_K_OBJ_ARRAY && o->oarr.v) scan_words((uintptr_t)o->oarr.v, (uintptr_t)(o->oarr.v + o->oarr.len));
            consider((uintptr_t)o->native);                      /* an implementation's state may be another object */
        }
        /* objects marked while a work list was full */
        bool more = false;
        for (size_t i = 0; i < g_cap && M0.nwork < M0.capwork; i++) if (S.mark[i] == 2) { S.mark[i] = 1; M0.work[M0.nwork++] = (uint32_t)i; more = true; }
        if (!more) break;
    }
}

/* ---- the roots, scanned by several threads: the pages to scan are listed first (runs), then each thread takes the next one */

#define GC_WORKERS_MAX 8
#define RUN_MAX_BYTES (1u << 20)                    /* a long run is cut, so the threads share it */
typedef struct { uintptr_t lo, hi; } run;
static struct {
    run *runs; size_t nruns, caprun;
    size_t next;                                    /* the next run to take, by __atomic_fetch_add */
    bool overflow;                                  /* more runs than room: the collecting thread scans the rest alone */
    size_t tag_bytes[256];                          /* what the roots were, by VM tag (for the log: what to leave out next) */
} R;

/* ---- a page that faults when read (memory the process listed as readable and writable, then could not read: seen on an iPhone in
 * Majed Sport, a whole region at once) is left out of the roots: the scan goes on after it, rather than the app ending. Nothing the
 * app can read is there either. */
/* volatile, and fenced: the handler reads it, which the compiler does not see -- without them it dropped the store that set it as
   a dead one (set, then cleared, with nothing reading it between), and a fault in the scan ended the app as before */
static __thread sigjmp_buf *volatile t_scan_jump;
static __thread volatile uintptr_t t_scan_fault;
static struct sigaction g_prev_segv, g_prev_bus;
static void scan_fault(int sig, siginfo_t *info, void *uc)
{
    sigjmp_buf *j = t_scan_jump;
    if (j) { t_scan_jump = NULL; t_scan_fault = (uintptr_t)(info ? info->si_addr : NULL); siglongjmp(*j, 1); }
    struct sigaction *prev = sig == SIGBUS ? &g_prev_bus : &g_prev_segv;
    if ((prev->sa_flags & SA_SIGINFO) && prev->sa_sigaction) prev->sa_sigaction(sig, info, uc);
    else if (prev->sa_handler != SIG_DFL && prev->sa_handler != SIG_IGN && prev->sa_handler) prev->sa_handler(sig);
    else signal(sig, SIG_DFL);                                  /* nothing else wants it: it faults again and ends */
}
/* on top of whatever handler is there (the loader's and the crash reporter's, which it hands the other faults to): again at each
 * collection, since a library may have put its own on top meanwhile */
static void scan_fault_install(void)
{
    struct sigaction cur, sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = scan_fault;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, NULL, &cur) == 0 && cur.sa_sigaction != scan_fault) sigaction(SIGSEGV, &sa, &g_prev_segv);
    if (sigaction(SIGBUS, NULL, &cur) == 0 && cur.sa_sigaction != scan_fault) sigaction(SIGBUS, &sa, &g_prev_bus);
}
static void scan_range_guarded(marker *k, uintptr_t lo, uintptr_t hi)
{
    const uintptr_t page = (uintptr_t)vm_page_size;
    volatile uintptr_t p = lo;
    while (p < hi) {
        sigjmp_buf jb;
        if (sigsetjmp(jb, 1) == 0) {
            t_scan_jump = &jb;
            __atomic_signal_fence(__ATOMIC_SEQ_CST);
            scan_range_in(k, p, hi);
            __atomic_signal_fence(__ATOMIC_SEQ_CST);
            t_scan_jump = NULL;
            return;
        }
        /* faulted: past the page that did, or past the whole range when the address is not in it */
        uintptr_t f = t_scan_fault;
        if (!k->first_fault) k->first_fault = f ? f : p;
        uintptr_t next = f >= p && f < hi ? (f & ~(page - 1)) + page : hi;
        k->unreadable += next - p < page ? next - p : page;
        p = next;
    }
}

static void scan_runs(marker *k)
{
    for (;;) {
        size_t i = __atomic_fetch_add(&R.next, 1, __ATOMIC_RELAXED);
        if (i >= R.nruns) break;
        scan_range_guarded(k, R.runs[i].lo, R.runs[i].hi);
    }
}

/* Worker threads, made once and waiting: they are left running when the world stops (they touch only the collector's state). */
static struct {
    int n;
    pthread_t t[GC_WORKERS_MAX];
    thread_t port[GC_WORKERS_MAX];
    marker m[GC_WORKERS_MAX];
    pthread_mutex_t mu; pthread_cond_t go, done;
    unsigned round, finished;
    int job;                                        /* what a round is: JOB_SCAN, or a pass of the tables (JOB_COUNT, JOB_FILL) */
} W = { .mu = PTHREAD_MUTEX_INITIALIZER, .go = PTHREAD_COND_INITIALIZER, .done = PTHREAD_COND_INITIALIZER };
enum { JOB_SCAN, JOB_COUNT, JOB_FILL, JOB_TRACE };
static void table_part(int part, int pass);

static void *worker(void *arg)
{
    int me = (int)(intptr_t)arg;
    unsigned seen = 0;
    pthread_mutex_lock(&W.mu);
    for (;;) {
        while (W.round == seen) pthread_cond_wait(&W.go, &W.mu);
        seen = W.round;
        pthread_mutex_unlock(&W.mu);
        if (W.job == JOB_SCAN) scan_runs(&W.m[me]);
        else if (W.job == JOB_TRACE) trace_in(&W.m[me]);
        else table_part(me + 1, W.job);
        pthread_mutex_lock(&W.mu);
        W.finished++;
        pthread_cond_signal(&W.done);
    }
    return NULL;
}

static void workers_start(void)
{
    static bool started;
    if (started) return;
    started = true;
    int want = 4;
    const char *e = getenv("TL_GC_THREADS");
    if (e) want = atoi(e);
    int ncpu = (int)sysconf(_SC_NPROCESSORS_ONLN);
    if (want > ncpu - 1) want = ncpu - 1;
    if (want > GC_WORKERS_MAX) want = GC_WORKERS_MAX;
    for (int i = 0; i < want; i++) {
        if (pthread_create(&W.t[W.n], NULL, worker, (void *)(intptr_t)W.n)) break;
        W.port[W.n] = pthread_mach_thread_np(W.t[W.n]);
        W.n++;
    }
}

static bool is_worker(thread_t t) { for (int i = 0; i < W.n; i++) if (W.port[i] == t) return true; return false; }

/* Every writable, resident (or paged-out) page of the process, less the collector's own memory, device memory and the shared cache:
 * listed as runs of pages, then scanned by the workers and this thread. */
static void list_runs(uintptr_t cache_lo, uintptr_t cache_hi, char *vec, size_t vecbytes);
static void scan_memory(uintptr_t cache_lo, uintptr_t cache_hi, char *vec, size_t vecbytes)
{
    R.nruns = 0; R.next = 0; R.overflow = false;
    memset(R.tag_bytes, 0, sizeof(R.tag_bytes));
    list_runs(cache_lo, cache_hi, vec, vecbytes);
    /* TL_GC_TEST_UNREADABLE=1: a block that cannot be read, among the roots, to see the scan go past it (the Mac harness) */
    static void *test_block; static int test_on = -1;
    if (test_on < 0) test_on = getenv("TL_GC_TEST_UNREADABLE") != NULL;
    if (test_on) {
        if (!test_block) { test_block = mmap(NULL, 3 << 20, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); if (test_block == MAP_FAILED) test_block = NULL; }
        if (test_block) add_run((uintptr_t)test_block, (uintptr_t)test_block + (3 << 20));
    }
    pthread_mutex_lock(&W.mu);
    W.finished = 0; W.job = JOB_SCAN; W.round++;
    pthread_cond_broadcast(&W.go);
    pthread_mutex_unlock(&W.mu);
    scan_runs(&M0);
    pthread_mutex_lock(&W.mu);
    while (W.finished < (unsigned)W.n) pthread_cond_wait(&W.done, &W.mu);
    pthread_mutex_unlock(&W.mu);
    /* what each thread marked stays in its work list: the trace starts from there, on every thread (trace_parallel) */
}

/* the trace, by every collector thread at once, each from the roots it found; what is left (a list that was full) after, here */
static void trace_parallel(void)
{
    if (W.n) {
        pthread_mutex_lock(&W.mu);
        W.finished = 0; W.job = JOB_TRACE; W.round++;
        pthread_cond_broadcast(&W.go);
        pthread_mutex_unlock(&W.mu);
        trace_in(&M0);
        pthread_mutex_lock(&W.mu);
        while (W.finished < (unsigned)W.n) pthread_cond_wait(&W.done, &W.mu);
        pthread_mutex_unlock(&W.mu);
    }
    for (int i = 0; i < W.n; i++) {
        marker *k = &W.m[i];
        for (size_t j = 0; j < k->nwork; j++) {                  /* none, unless a worker stopped early */
            if (M0.nwork < M0.capwork) M0.work[M0.nwork++] = k->work[j];
            else S.mark[k->work[j]] = 2;
        }
        M0.marked += k->marked; M0.words += k->words; M0.unreadable += k->unreadable; k->unreadable = 0;
        if (!M0.first_fault) M0.first_fault = k->first_fault;
        k->first_fault = 0;
        k->nwork = 0; k->marked = 0; k->words = 0;
    }
}

/* a run of pages to scan; one that does not fit the list is scanned here, by this thread alone */
static void add_run(uintptr_t lo, uintptr_t hi)
{
    for (uintptr_t p = lo; p < hi; p += RUN_MAX_BYTES) {
        uintptr_t e = hi - p > RUN_MAX_BYTES ? p + RUN_MAX_BYTES : hi;
        if (R.nruns < R.caprun) { R.runs[R.nruns].lo = p; R.runs[R.nruns].hi = e; R.nruns++; }
        else { R.overflow = true; scan_range_guarded(&M0, p, e); }
    }
}

static void list_runs(uintptr_t cache_lo, uintptr_t cache_hi, char *vec, size_t vecbytes)
{
    vm_address_t addr = 0;
    natural_t depth = 0;
    for (;;) {
        vm_size_t size = 0;
        vm_region_submap_info_data_64_t info; mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &addr, &size, &depth, (vm_region_recurse_info_t)&info, &cnt) != KERN_SUCCESS) break;
        if (info.is_submap) { depth++; continue; }
        uintptr_t lo = (uintptr_t)addr, hi = (uintptr_t)(addr + size);
        addr += size;
        if ((info.protection & (VM_PROT_READ | VM_PROT_WRITE)) != (VM_PROT_READ | VM_PROT_WRITE)) continue;
        if (info.user_tag == GC_TAG || info.user_tag == DATA_TAG) continue;
        /* shared and aliased memory is scanned too: the loader maps Android libraries' data with vm_remap, and their globals (JNI
           global references, cached strings) are roots. Only device memory is left out. */
        if (info.user_tag == VM_MEMORY_IOKIT || info.user_tag == VM_MEMORY_IOSURFACE || info.user_tag == VM_MEMORY_IOACCELERATOR) continue;
        if (hi > cache_lo && lo < cache_hi) continue;
        if (info.pages_resident == 0 && info.pages_swapped_out == 0) continue;
        const size_t page = (size_t)vm_page_size;
        for (uintptr_t c = lo; c < hi; ) {
            size_t chunk = hi - c; if (chunk > vecbytes * page) chunk = vecbytes * page;
            if (mincore((void *)c, chunk, vec) != 0) { c += chunk; continue; }
            for (size_t i = 0; i < chunk / page; ) {
                if (!(vec[i] & (MINCORE_INCORE | MINCORE_PAGED_OUT))) { i++; continue; }
                size_t j = i; while (j < chunk / page && (vec[j] & (MINCORE_INCORE | MINCORE_PAGED_OUT))) j++;
                add_run(c + i * page, c + j * page);
                R.tag_bytes[info.user_tag & 255] += (j - i) * page;
                i = j;
            }
            c += chunk;
        }
    }
}

/* ---- the tables (owned blocks, block starts), built by the workers and this thread, each over a slice of the registry: a pass
 * that counts each slice's blocks, then one that writes them where the counts say. (One thread walked a million objects inside
 * the pause, 120-200 ms of it on the iPhone.) */
static struct {
    size_t count[GC_WORKERS_MAX + 1], base[GC_WORKERS_MAX + 1];
    uintptr_t lo[GC_WORKERS_MAX + 1], hi[GC_WORKERS_MAX + 1], olo[GC_WORKERS_MAX + 1], ohi[GC_WORKERS_MAX + 1];
    int parts;
} T;

static inline void okey_put(uintptr_t start, uint32_t slot, uintptr_t *olo, uintptr_t *ohi)
{
    if (start < *olo) *olo = start;
    if (start > *ohi) *ohi = start;
    size_t mask = S.ocap - 1, h = hash_ptr(start, mask);
    for (size_t n = 0; n < S.ocap; n++, h = (h + 1) & mask) {
        uintptr_t zero = 0;
        if (__atomic_compare_exchange_n(&S.okey[h], &zero, start, false, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) { S.oval[h] = slot; return; }
    }
}

static void table_part(int part, int pass)
{
    size_t a = g_cap * (size_t)part / (size_t)T.parts, b = g_cap * (size_t)(part + 1) / (size_t)T.parts;
    size_t n = 0, at = T.base[part], end = S.capown;
    uintptr_t lo = UINTPTR_MAX, hi = 0, olo = UINTPTR_MAX, ohi = 0;
    #define OWN(start, bytes) do { uintptr_t s_ = (uintptr_t)(start); size_t b_ = (bytes);         if (s_ && b_) { n++; if (pass == JOB_FILL && at < end) { S.own[at].lo = s_; S.own[at].hi = s_ + b_; at++; } } } while (0)
    #define KEY(start) do { if (pass == JOB_FILL && (start)) okey_put((uintptr_t)(start), (uint32_t)i, &olo, &ohi); } while (0)
    for (size_t i = a; i < b; i++) {
        uintptr_t p = g_tab[i];
        if (p <= GONE) continue;
        jobj *o = (jobj *)p;
        if (p < lo) lo = p;
        if (p > hi) hi = p;
        OWN(p, sizeof(jobj));
        if (o->fields) { OWN(o->fields, o->nfields * sizeof(jvalue)); KEY(o->fields); }
        if (o->monitor) OWN(o->monitor, 64);
        switch (o->kind) {
        case TL_K_STRING:
            if (o->str.u16) { OWN(o->str.u16, (size_t)o->str.len16 * 2); KEY(o->str.u16); }
            if (o->str.utf8) { OWN(o->str.utf8, pass == JOB_FILL ? strlen(o->str.utf8) + 1 : 1); KEY(o->str.utf8); }
            break;
        case TL_K_PRIM_ARRAY:
            if (o->arr.data) { OWN(o->arr.data, (size_t)o->arr.len * o->arr.esz); KEY(o->arr.data); }
            break;
        case TL_K_OBJ_ARRAY:
            if (o->oarr.v) { OWN(o->oarr.v, (size_t)o->oarr.len * sizeof(jobj *)); KEY(o->oarr.v); }
            break;
        default: break;
        }
    }
    #undef OWN
    #undef KEY
    if (pass == JOB_COUNT) { T.count[part] = n; T.lo[part] = lo; T.hi[part] = hi; }
    else { T.count[part] = at - T.base[part]; T.olo[part] = olo; T.ohi[part] = ohi; }
}

/* one pass over every slice: the workers' slices and this thread's (part 0) */
static void table_pass(int pass)
{
    pthread_mutex_lock(&W.mu);
    W.finished = 0; W.job = pass; W.round++;
    pthread_cond_broadcast(&W.go);
    pthread_mutex_unlock(&W.mu);
    table_part(0, pass);
    pthread_mutex_lock(&W.mu);
    while (W.finished < (unsigned)W.n) pthread_cond_wait(&W.done, &W.mu);
    pthread_mutex_unlock(&W.mu);
}

static void build_tables(void)
{
    T.parts = W.n + 1;
    table_pass(JOB_COUNT);
    size_t at = 0;
    S.lo = UINTPTR_MAX; S.hi = 0; S.olo = UINTPTR_MAX; S.ohi = 0;
    for (int p = 0; p < T.parts; p++) {
        T.base[p] = at; at += T.count[p];
        if (T.lo[p] < S.lo) S.lo = T.lo[p];
        if (T.hi[p] > S.hi) S.hi = T.hi[p];
    }
    table_pass(JOB_FILL);
    /* the slices' blocks, end to end (a slice past the room is cut, as one that was full always was: its blocks are scanned) */
    size_t n = 0;
    for (int p = 0; p < T.parts; p++) {
        if (T.base[p] != n && T.count[p]) memmove(&S.own[n], &S.own[T.base[p]], T.count[p] * sizeof(range));
        n += T.count[p];
        if (T.olo[p] < S.olo) S.olo = T.olo[p];
        if (T.ohi[p] > S.ohi) S.ohi = T.ohi[p];
    }
    S.nown = n;
}

static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }

static void free_object(jobj *o)
{
    switch (o->kind) {
    case TL_K_STRING: free(o->str.utf8); free(o->str.u16); break;
    case TL_K_PRIM_ARRAY: free(o->arr.data); break;
    case TL_K_OBJ_ARRAY: free(o->oarr.v); break;
    default: break;
    }
    if (o->monitor) {
        struct { pthread_mutex_t mu; pthread_cond_t cv; } *m = o->monitor;
        pthread_mutex_destroy(&m->mu); pthread_cond_destroy(&m->cv); free(o->monitor);
    }
    free(o->fields);
    free(o);
}

static pthread_mutex_t g_run = PTHREAD_MUTEX_INITIALIZER;

/* ---- the collector's tables, kept between collections (grown when the heap grows) */
enum { P_OWN, P_SORT, P_COUNTS, P_OKEY, P_OVAL, P_MARK, P_WORK, P_RUNS, P_STOPPED, P_VEC, P_SWEEP, P_WORKER, P_COUNT = P_WORKER + GC_WORKERS_MAX };

/* ---- the sweeper: the garbage is freed on a thread of the collector's own, not on the app's thread that started the collection
 * (a million objects took it 1-3 s more after the pause: a stall, if that thread was the UI's). The next collection waits for it. */
static struct {
    pthread_mutex_t mu; pthread_cond_t go;
    jobj **list; size_t n;
    bool started;
} SW = { .mu = PTHREAD_MUTEX_INITIALIZER, .go = PTHREAD_COND_INITIALIZER };
static atomic_bool g_sweeping;
static void free_object(jobj *o);
static void *sweeper(void *arg)
{
    (void)arg;
    pthread_setname_np("husk-gc-sweep");
    pthread_mutex_lock(&SW.mu);
    for (;;) {
        while (!SW.n) pthread_cond_wait(&SW.go, &SW.mu);
        jobj **list = SW.list; size_t n = SW.n;
        pthread_mutex_unlock(&SW.mu);
        for (size_t i = 0; i < n; i++) free_object(list[i]);
        pthread_mutex_lock(&SW.mu);
        SW.n = 0;
        atomic_store(&g_sweeping, false);
    }
    return NULL;
}
static bool sweeper_start(void)
{
    if (SW.started) return true;
    pthread_t t;
    if (pthread_create(&t, NULL, sweeper, NULL)) return false;
    pthread_detach(t);
    SW.started = true;
    return true;
}
static struct { void *p; size_t cap, used; } g_pool[P_COUNT];

static void *pool(int id, size_t bytes)
{
    if (g_pool[id].cap < bytes) {
        if (g_pool[id].p) munmap(g_pool[id].p, g_pool[id].cap);
        size_t cap = bytes + bytes / 4;                         /* room to grow before mapping again */
        cap = (cap + 16383) & ~(size_t)16383;
        g_pool[id].p = gc_map(cap);
        g_pool[id].cap = g_pool[id].p ? cap : 0;
    }
    g_pool[id].used = bytes;
    return g_pool[id].p;
}

/* touch every page of the part used: one write per page (zero, where it is still zero) */
static void prefault(int id)
{
    volatile uint8_t *p = g_pool[id].p;
    if (!p) return;
    for (size_t o = 0; o < g_pool[id].used; o += 16384) p[o] = p[o];
}

static void collect(void)
{
    if (atomic_load(&g_sweeping)) return;                     /* the last collection's garbage is still being freed */
    if (pthread_mutex_trylock(&g_run) != 0) return;            /* another thread is collecting */
    double t0 = now_ms();
    pthread_mutex_lock(&g_reg);
    if (g_made < g_due) { pthread_mutex_unlock(&g_reg); pthread_mutex_unlock(&g_run); return; }
    g_made = 0;

    /* everything the collection needs, made before the world stops (nothing may allocate while it is stopped) */
    memset(&S, 0, sizeof(S));
    workers_start();
    scan_fault_install();
    S.capown = g_count * 3 + 1024;
    S.ocap = 1; while (S.ocap < g_count * 4 + 1024) S.ocap <<= 1;
    S.capwork = g_count + 1024;
    const size_t vecbytes = 1 << 16;
    /* the tables stay mapped from one collection to the next, and what has to start empty is cleared here, before the world
     * stops: fresh pages zero-filled on first touch inside the pause cost up to 1.5 s */
    S.own = pool(P_OWN, S.capown * sizeof(range));
    range *sort_tmp = pool(P_SORT, S.capown * sizeof(range));
    size_t *sort_counts = pool(P_COUNTS, 65536 * sizeof(size_t));
    S.okey = pool(P_OKEY, S.ocap * sizeof(uintptr_t)); S.oval = pool(P_OVAL, S.ocap * sizeof(uint32_t));
    S.mark = pool(P_MARK, g_cap);
    if (S.okey) memset(S.okey, 0, S.ocap * sizeof(uintptr_t));
    if (S.mark) memset(S.mark, 0, g_cap);
    memset(&M0, 0, sizeof(M0));
    M0.capwork = S.capwork; M0.work = pool(P_WORK, M0.capwork * sizeof(uint32_t));
    bool workers_ok = true;
    for (int i = 0; i < W.n; i++) {
        memset(&W.m[i], 0, sizeof(W.m[i]));
        W.m[i].capwork = S.capwork; W.m[i].work = pool(P_WORKER + i, W.m[i].capwork * sizeof(uint32_t));
        workers_ok &= W.m[i].work != NULL;
    }
    R.caprun = 1 << 20; R.runs = pool(P_RUNS, R.caprun * sizeof(run));
    S.capstopped = 8192; S.stopped = pool(P_STOPPED, S.capstopped * sizeof(thread_t));
    char *vec = pool(P_VEC, vecbytes);
    size_t capsweep = g_count + 1024;
    jobj **sweep = sweeper_start() ? pool(P_SWEEP, capsweep * sizeof(jobj *)) : NULL;
    size_t nsweep = 0;
    /* the pages of the tables this collection uses, made resident now */
    for (int k = 0; k < P_COUNT; k++) prefault(k);
    size_t cache_len = 0; uintptr_t cache_lo = 0, cache_hi = 0;
    if (_dyld_get_shared_cache_range) { cache_lo = (uintptr_t)_dyld_get_shared_cache_range(&cache_len); cache_hi = cache_lo + cache_len; }
    thread_act_array_t threads = NULL; mach_msg_type_number_t nthreads = 0;
    bool ok = S.own && sort_tmp && sort_counts && S.okey && S.oval && S.mark && M0.work && workers_ok && R.runs && S.stopped && vec;

    size_t before = g_count, freed = 0, freed_bytes = 0;
    double t_stop = 0, t_mark = 0, t_tables = 0, t_roots = 0;
    if (ok) {
        /* stop the world: every thread but this one, again until no new one has started meanwhile */
        thread_t self = mach_thread_self();
        S.olo = UINTPTR_MAX; S.ohi = 0;
        for (int round = 0; round < 8; round++) {
            if (task_threads(mach_task_self(), &threads, &nthreads) != KERN_SUCCESS) { threads = NULL; nthreads = 0; break; }
            size_t added = 0;
            for (mach_msg_type_number_t i = 0; i < nthreads; i++) {
                bool known = threads[i] == self || is_worker(threads[i]);  /* the workers only touch the collector's memory */
                for (size_t k = 0; k < S.nstopped && !known; k++) known = S.stopped[k] == threads[i];
                if (known || S.nstopped >= S.capstopped) { mach_port_deallocate(mach_task_self(), threads[i]); continue; }
                if (thread_suspend(threads[i]) == KERN_SUCCESS) { S.stopped[S.nstopped++] = threads[i]; added++; }
                else mach_port_deallocate(mach_task_self(), threads[i]);
            }
            vm_deallocate(mach_task_self(), (vm_address_t)threads, nthreads * sizeof(thread_t));
            threads = NULL; nthreads = 0;
            if (!added && round) break;
        }
        t_stop = now_ms();

        /* the memory Java objects own, and the lowest and highest object: the registry walked by all the collector's threads */
        build_tables();
        sort_own(sort_tmp, sort_counts);
        t_tables = now_ms();

        /* the roots: the other threads' registers, then all of the process's own memory but the Java heap */
        for (size_t i = 0; i < S.nstopped; i++) {
            arm_thread_state64_t st; mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
            if (thread_get_state(S.stopped[i], ARM_THREAD_STATE64, (thread_state_t)&st, &sc) != KERN_SUCCESS) continue;
            for (int r = 0; r < 29; r++) consider((uintptr_t)st.__x[r]);
            consider((uintptr_t)arm_thread_state64_get_fp(st));
            consider((uintptr_t)arm_thread_state64_get_lr(st));
        }
        __builtin_unwind_init();                                 /* this thread's callee-saved registers, onto its stack */
        scan_memory(cache_lo, cache_hi, vec, vecbytes);
        t_roots = now_ms();
        trace();
        t_mark = now_ms();

        /* the class objects stay: their classes are not unloaded */
        for (size_t i = 0; i < g_cap; i++) {
            uintptr_t p = g_tab[i];
            if (p <= GONE || S.mark[i]) continue;
            jobj *o = (jobj *)p;
            if (o->kind == TL_K_CLASS) continue;
            freed++;
            freed_bytes += 80 + o->nfields * sizeof(jvalue) + (o->kind == TL_K_STRING ? (size_t)o->str.len16 * 2 : 0)
                         + (o->kind == TL_K_PRIM_ARRAY ? (size_t)o->arr.len * o->arr.esz : 0)
                         + (o->kind == TL_K_OBJ_ARRAY ? (size_t)o->oarr.len * 8 : 0);
            S.mark[i] = 3;                                       /* garbage */
        }
        for (size_t i = 0; i < S.nstopped; i++) { thread_resume(S.stopped[i]); mach_port_deallocate(mach_task_self(), S.stopped[i]); }
        mach_port_deallocate(mach_task_self(), self);

        /* free outside the stop (free takes malloc's locks, which a stopped thread may have held) */
        if (g_mode == 2) {
            for (size_t i = 0; i < g_cap; i++) {
                if (S.mark[i] != 3) continue;
                jobj *o = (jobj *)g_tab[i];
                g_tab[i] = GONE; g_count--;
                if (sweep && nsweep < capsweep) sweep[nsweep++] = o;     /* out of the registry now; freed by the sweeper */
                else free_object(o);
            }
        }
    }
    size_t marked = M0.marked, roots_mb = M0.words * 8 >> 20, unreadable = M0.unreadable;
    /* the next collection after twice the live objects are made; three times when this pause was long (a big heap, slow to stop
       and scan): fewer stops for some more memory, of which the phone has room (PrimeTV paused 400-800 ms every few seconds) */
    if (ok) {
        bool slow = t_mark - t_stop > 250;
        uint64_t d = (uint64_t)marked * (slow ? 3 : 2), cap = slow ? 4500000 : 3000000;
        if (d < g_every) d = g_every;
        if (d > cap) d = cap;
        __atomic_store_n(&g_due, d, __ATOMIC_RELAXED);
    }
    /* (the tables stay for the next collection) */
    if (nsweep) {
        pthread_mutex_lock(&SW.mu);
        atomic_store(&g_sweeping, true);
        SW.list = sweep; SW.n = nsweep;
        pthread_cond_signal(&SW.go);
        pthread_mutex_unlock(&SW.mu);
    }
    pthread_mutex_unlock(&g_reg);
    pthread_mutex_unlock(&g_run);
    double t1 = now_ms();
    if (!ok) { tl_log_line("gc: could not collect (no memory for its tables, or no thread list)"); return; }
    if (unreadable) {
        /* what it was: the region, its VM tag and protection, for leaving it out by name next time */
        vm_address_t a = (vm_address_t)M0.first_fault; vm_size_t sz = 0; natural_t depth = 0;
        vm_region_submap_info_data_64_t info; mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        bool known = vm_region_recurse_64(mach_task_self(), &a, &sz, &depth, (vm_region_recurse_info_t)&info, &cnt) == KERN_SUCCESS;
        tl_log_line("gc: %zu KiB of memory listed as readable faulted when read (first at %#lx%s, VM tag %d, protection %d/%d, region "
                    "%#lx + %lu KiB): left out of the roots", unreadable >> 10, (unsigned long)M0.first_fault, known ? "" : ", region gone",
                    known ? (int)info.user_tag : -1, known ? info.protection : -1, known ? info.max_protection : -1,
                    (unsigned long)a, (unsigned long)(sz >> 10));
    }
    {   /* the three largest kinds of root memory */
        char top[160] = ""; size_t used[3] = { 0 }; int tags[3] = { -1, -1, -1 };
        for (int k = 0; k < 3; k++)
            for (int g = 0; g < 256; g++)
                if (R.tag_bytes[g] > used[k] && g != tags[0] && g != tags[1]) { used[k] = R.tag_bytes[g]; tags[k] = g; }
        for (int k = 0, o = 0; k < 3 && tags[k] >= 0; k++) o += snprintf(top + o, sizeof(top) - o, "%stag %d %zu MiB", k ? ", " : "", tags[k], used[k] >> 20);
        tl_log_line("gc: roots by VM tag: %s", top);
    }
    tl_log_line("gc: %zu threads stopped; %zu objects, %zu live, %zu %s (%zu MiB), %zu MiB of roots scanned by %d threads; "
                "paused %.0f ms (tables %.0f, roots %.0f, trace %.0f), total %.0f ms",
                S.nstopped, before, marked, freed, g_mode == 2 ? "freed" : "would be freed", freed_bytes >> 20, roots_mb, W.n + 1,
                t_mark - t_stop, t_tables - t_stop, t_roots - t_tables, t_mark - t_roots, t1 - t0);
}
