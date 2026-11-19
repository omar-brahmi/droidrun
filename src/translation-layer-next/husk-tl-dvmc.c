/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Compiled Dalvik methods: finding the dylib tools/dexc/dexc.py made for a DEX file, and the call profile it is made from.
 * See husk-tl-dvmc.h.
 *
 * The dylib for a DEX file is dexc-v<DVMC_VERSION>-<its signature's first 8 bytes in hex>.dylib, looked for in
 *  - TL_DEXC_DIR (Mac harnesses), then
 *  - the folders the app gave tl_ld_set_aot_dir, then
 *  - the app bundle's Frameworks folder, where the packager puts it.
 * dlopen loads it as any signed library, so it needs no JIT. TL_DEXC=0 leaves every method interpreted.
 *
 * TL_DVM_PROFILE=<file>: the interpreter counts each method's calls and backward branches, and every 10 s the methods worth
 * compiling go to the file, one per line: "<dex signature hex> <method_idx> <calls> <loops> <class>.<name><sig>", added to
 * what the file held from earlier runs. Settings › Compiled Code › Record Hot Methods sets it on the iPhone.
 */
#define _DARWIN_C_SOURCE
#include "husk-tl-dvm-internal.h"
#include "husk-tl-dvmc.h"

#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

void tl_log_line(const char *fmt, ...);
const char *tl_ld_aot_dirs(void);

static void sig_hex(const dvm_dex *d, char out[17])
{
    for (int i = 0; i < 8; i++) snprintf(out + 2 * i, 3, "%02x", d->b[12 + i]);
}

static const dvmc_module *open_module(const char *dir, const char *file, const dvm_dex *d)
{
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/%s", dir, file);
    if (access(path, R_OK)) return NULL;
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!h) { tl_log_line("dvmc: %s: %s", path, dlerror()); return NULL; }
    const dvmc_module *mod = dlsym(h, "dvmc_exports");
    if (!mod || mod->version != DVMC_VERSION || memcmp(mod->signature, d->b + 12, 20)) {
        tl_log_line("dvmc: %s was made for another DEX file or runtime version; not used", path);
        dlclose(h);
        return NULL;
    }
    mod->bind(dvm_compiled_api());
    return mod;
}

static void prof_start(void);

void dvmc_dex_added(dvm_dex *d)
{
    prof_start();
    static int off = -1;
    if (off < 0) off = getenv("TL_DEXC") && !strcmp(getenv("TL_DEXC"), "0");
    if (off) return;
    char hex[17], file[64];
    sig_hex(d, hex);
    snprintf(file, sizeof(file), "dexc-v%d-%s.dylib", DVMC_VERSION, hex);
    char dirs[4096] = "";
    const char *env = getenv("TL_DEXC_DIR"), *aot = tl_ld_aot_dirs();
    if (env) snprintf(dirs, sizeof(dirs), "%s:", env);
    if (aot) { size_t l = strlen(dirs); snprintf(dirs + l, sizeof(dirs) - l, "%s:", aot); }
    {   /* <bundle>/Frameworks, next to the executable */
        char exe[PATH_MAX]; uint32_t n = sizeof(exe);
        if (!_NSGetExecutablePath(exe, &n)) {
            char *slash = strrchr(exe, '/');
            if (slash) { *slash = 0; size_t l = strlen(dirs); snprintf(dirs + l, sizeof(dirs) - l, "%s/Frameworks", exe); }
        }
    }
    for (char *s = dirs, *e; *s && !d->compiled; s = *e ? e + 1 : e) {
        e = strchr(s, ':'); if (!e) e = s + strlen(s);
        char dir[PATH_MAX]; snprintf(dir, sizeof(dir), "%.*s", (int)(e - s), s);
        if (dir[0]) d->compiled = open_module(dir, file, d);
    }
    if (d->compiled) tl_log_line("dvmc: %s: %u methods compiled ahead of time (%s)", d->name, d->compiled->count, file);
}

void *dvmc_lookup(const dvm_dex *d, uint32_t midx)
{
    const dvmc_module *mod = d->compiled;
    if (!mod) return NULL;
    uint32_t lo = 0, hi = mod->count;
    while (lo < hi) {
        uint32_t mid = (lo + hi) / 2;
        if (mod->entries[mid].midx < midx) lo = mid + 1; else hi = mid;
    }
    return lo < mod->count && mod->entries[lo].midx == midx ? (void *)mod->entries[lo].fn : NULL;
}

/* ---- the profile */

/* The file keeps what earlier runs counted (the app recorded over several launches, other apps too): it is read when recording
 * starts, and each write adds this run's counts to those lines. */
typedef struct prev { char key[32]; uint32_t calls, loops; char *label; bool used; } prev;

static pthread_mutex_t g_prof_lock = PTHREAD_MUTEX_INITIALIZER;
static dvm_method **g_seen; static size_t g_nseen, g_capseen;
static prev *g_prev; static size_t g_nprev, g_capprev;           /* open addressing by key, g_capprev a power of two */
static char *g_prof_path;
/* what is written: every method that ran (the default: all of them are compiled ahead of time, the hottest at -O2, the rest
 * small), or only those called / looping at least this much (TL_DVM_PROFILE_MIN=calls[,loops]) */
static uint32_t g_min_calls = 1, g_min_loops = 1;

static size_t prev_slot(const char *key)
{
    uint32_t h = 2166136261u;
    for (const char *s = key; *s; s++) { h ^= (unsigned char)*s; h *= 16777619u; }
    size_t i = h & (g_capprev - 1);
    while (g_prev[i].key[0] && strcmp(g_prev[i].key, key)) i = (i + 1) & (g_capprev - 1);
    return i;
}

static prev *prev_get(const char *key, bool add)
{
    if (add && (g_nprev + 1) * 2 > g_capprev) {
        prev *old = g_prev; size_t n = g_capprev;
        g_capprev = n ? n * 2 : 8192;
        g_prev = calloc(g_capprev, sizeof(*g_prev));
        for (size_t i = 0; i < n; i++) if (old[i].key[0]) g_prev[prev_slot(old[i].key)] = old[i];
        free(old);
    }
    if (!g_capprev) return NULL;
    size_t i = prev_slot(key);
    if (!g_prev[i].key[0]) {
        if (!add) return NULL;
        snprintf(g_prev[i].key, sizeof(g_prev[i].key), "%s", key);
        g_nprev++;
    }
    return &g_prev[i];
}

/* this run's count of m added to the earlier runs' (fold: and kept as earlier, the method being dropped) */
static void method_key(dvm_method *m, char *key, size_t n) { char hex[17]; sig_hex(m->cls->dex, hex); snprintf(key, n, "%s %u", hex, m->idx); }

static void prof_write_locked(bool fold)
{
    for (size_t i = 0; i < g_capprev; i++) g_prev[i].used = false;
    char tmp[PATH_MAX]; snprintf(tmp, sizeof(tmp), "%s.tmp", g_prof_path);
    FILE *f = fopen(tmp, "w");
    for (size_t i = 0; i < g_nseen; i++) {
        dvm_method *m = g_seen[i];
        char key[32]; method_key(m, key, sizeof(key));
        prev *p = prev_get(key, fold);
        uint32_t calls = m->calls + (p ? p->calls : 0), loops = m->loops + (p ? p->loops : 0);
        if (p) p->used = true;
        if (fold && p) {
            p->calls = calls; p->loops = loops;
            if (!p->label) { char l[1024]; snprintf(l, sizeof(l), "%s.%s%s", m->cls->name, m->name, m->sig); p->label = strdup(l); }
            m->calls = m->loops = 0;    /* counted from 0 again: a boot class path method stays, and registers again */
        }
        if (f && (calls >= g_min_calls || loops >= g_min_loops))
            fprintf(f, "%s %u %u %s.%s%s\n", key, calls, loops, m->cls->name, m->name, m->sig);
    }
    for (size_t i = 0; f && i < g_capprev; i++)
        if (g_prev[i].key[0] && !g_prev[i].used && (g_prev[i].calls >= g_min_calls || g_prev[i].loops >= g_min_loops))
            fprintf(f, "%s %u %u %s\n", g_prev[i].key, g_prev[i].calls, g_prev[i].loops, g_prev[i].label ? g_prev[i].label : "?");
    if (f) { fclose(f); rename(tmp, g_prof_path); }
    if (fold) g_nseen = 0;
}

static void prof_write(void)
{
    pthread_mutex_lock(&g_prof_lock);
    prof_write_locked(false);
    pthread_mutex_unlock(&g_prof_lock);
}

static void *prof_thread(void *arg)
{
    (void)arg;
    for (;;) { sleep(10); prof_write(); }
    return NULL;
}

/* Recording starts when the runtime adds its first DEX file: the app sets TL_DVM_PROFILE just before it starts an app
 * (CompiledCode.swift), after this library's constructors ran. */
static void prof_start(void)
{
    static bool started;
    if (started) return;
    started = true;
    const char *path = getenv("TL_DVM_PROFILE");
    if (!path || !*path) return;
    g_prof_path = strdup(path);
    const char *min = getenv("TL_DVM_PROFILE_MIN");
    if (min && *min) { unsigned c = 1, l = 0; int n = sscanf(min, "%u,%u", &c, &l); g_min_calls = c ? c : 1; g_min_loops = n == 2 && l ? l : g_min_calls * 20; }
    FILE *f = fopen(g_prof_path, "r");
    if (f) {
        char line[2048], hex[24], label[1500]; unsigned idx, calls, loops;
        while (fgets(line, sizeof(line), f)) {
            if (sscanf(line, "%23s %u %u %u %1499s", hex, &idx, &calls, &loops, label) < 4) continue;
            char key[32]; snprintf(key, sizeof(key), "%s %u", hex, idx);
            prev *p = prev_get(key, true);
            p->calls += calls; p->loops += loops;
            if (!p->label) p->label = strdup(label);
        }
        fclose(f);
    }
    tl_log_line("dvmc: recording hot methods to %s (%zu from earlier runs)", g_prof_path, g_nprev);
    g_dvm_profile = 1;
    pthread_t t; pthread_create(&t, NULL, prof_thread, NULL); pthread_detach(t);
    atexit(prof_write);
}

/* The app's classes are about to be dropped: their counts go into the earlier runs' and the methods are forgotten. */
void dvmc_profile_drop_app(void)
{
    if (!g_dvm_profile) return;
    pthread_mutex_lock(&g_prof_lock);
    prof_write_locked(true);
    pthread_mutex_unlock(&g_prof_lock);
}

void dvmc_count_call(dvm_method *m)
{
    if (m->calls++ == 0) {
        pthread_mutex_lock(&g_prof_lock);
        if (g_nseen == g_capseen) {
            g_capseen = g_capseen ? g_capseen * 2 : 4096;
            g_seen = realloc(g_seen, g_capseen * sizeof(*g_seen));
        }
        g_seen[g_nseen++] = m;
        pthread_mutex_unlock(&g_prof_lock);
    }
}
