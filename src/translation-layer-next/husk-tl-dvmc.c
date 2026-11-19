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
 * compiling go to the file, one per line: "<dex signature hex> <method_idx> <calls> <loops> <class>.<name><sig>".
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

void dvmc_dex_added(dvm_dex *d)
{
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

static pthread_mutex_t g_prof_lock = PTHREAD_MUTEX_INITIALIZER;
static dvm_method **g_seen; static size_t g_nseen, g_capseen;
static const char *g_prof_path;

static void prof_write(void)
{
    pthread_mutex_lock(&g_prof_lock);
    char tmp[PATH_MAX]; snprintf(tmp, sizeof(tmp), "%s.tmp", g_prof_path);
    FILE *f = fopen(tmp, "w");
    if (f) {
        for (size_t i = 0; i < g_nseen; i++) {
            dvm_method *m = g_seen[i];
            uint32_t calls = m->calls, loops = m->loops;
            if (calls < 50 && loops < 1000) continue;                  /* too cold to be worth compiling */
            char hex[17]; sig_hex(m->cls->dex, hex);
            fprintf(f, "%s %u %u %u %s.%s%s\n", hex, m->idx, calls, loops, m->cls->name, m->name, m->sig);
        }
        fclose(f);
        rename(tmp, g_prof_path);
    }
    pthread_mutex_unlock(&g_prof_lock);
}

static void *prof_thread(void *arg)
{
    (void)arg;
    for (;;) { sleep(10); prof_write(); }
    return NULL;
}

__attribute__((constructor)) static void prof_init(void)
{
    g_prof_path = getenv("TL_DVM_PROFILE");
    if (!g_prof_path || !*g_prof_path) return;
    g_dvm_profile = 1;
    pthread_t t; pthread_create(&t, NULL, prof_thread, NULL); pthread_detach(t);
    atexit(prof_write);
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
