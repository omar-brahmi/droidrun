/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Streams AVPlayer cannot open, turned into HLS it can, on the phone (husk-tl-dvm-avplayer.m asks tl_av_resolve first):
 *  - a raw MPEG-TS stream (IPTV live channels, .ts files): read once from the server, cut into ~2 s segments at key frames with the
 *    PAT and PMT in front of each, and offered as a live HLS playlist from a server on 127.0.0.1;
 *  - DASH (.mpd) with SegmentTemplate (numbers or a SegmentTimeline) or SegmentList: the MPD rewritten as an HLS master playlist
 *    and media playlists of fMP4 segments (EXT-X-MAP), refreshed while a live MPD changes. ClearKey-encrypted DASH (CENC 'cenc' or
 *    'cbcs') is decrypted here with the keys the app gave its player (tl_av_clearkey), its segments served from this server as
 *    plain fMP4.
 * Anything else (HLS, MP4, MP3...) goes to AVPlayer as it is. Other DRM, RTMP and RTSP are left to the app's own player.
 */
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonCryptor.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

void tl_log_line(const char *fmt, ...);

/* ======================================================================== the local server */

static int g_port;
static pthread_once_t g_server_once = PTHREAD_ONCE_INIT;

typedef struct { NSData *body; NSString *type; int status; NSString *extra; id stream; int64_t stream_len; } reply;   /* stream: an HFile sent whole as it arrives */
static reply handle_path(NSString *path, int64_t range_lo, int64_t range_hi);

static NSData *hfile_chunk(id f, int64_t off, size_t max);   /* the bytes of an HFile from off, once some have arrived */

static bool send_all(int fd, const void *b, size_t n)
{
    const uint8_t *p = b;
    while (n) { ssize_t w = send(fd, p, n, 0); if (w <= 0) return false; p += w; n -= (size_t)w; }
    return true;
}

static void *serve_one(void *arg)
{
    int fd = (int)(intptr_t)arg;
    @autoreleasepool {
        char req[4096]; size_t n = 0;
        while (n < sizeof(req) - 1) {
            ssize_t r = recv(fd, req + n, sizeof(req) - 1 - n, 0);
            if (r <= 0) break;
            n += (size_t)r; req[n] = 0;
            if (strstr(req, "\r\n\r\n")) break;
        }
        req[n] = 0;
        char method[8] = { 0 }, path[2048] = { 0 };
        reply rp = { nil, nil, 400, nil, nil, 0 };
        long long lo = -1, hi = -1;
        const char *rg = strcasestr(req, "\nRange: bytes=");
        if (rg) { if (sscanf(rg + 14 /* past the newline and "Range: bytes=" */, "%lld-%lld", &lo, &hi) < 1) lo = -1; }
        if (sscanf(req, "%7s %2047s", method, path) == 2) rp = handle_path([NSString stringWithUTF8String:path], lo, hi);
        const char *why = rp.status == 200 ? "OK" : rp.status == 206 ? "Partial Content" : rp.status == 416 ? "Range Not Satisfiable" : "Not Found";
        NSString *head = [NSString stringWithFormat:@"HTTP/1.1 %d %s\r\nContent-Type: %@\r\nContent-Length: %lu\r\n%@Cache-Control: no-cache\r\nConnection: close\r\n\r\n",
                          rp.status, why, rp.type ? rp.type : @"text/plain", (unsigned long)(rp.stream ? (unsigned long)rp.stream_len : rp.body.length), rp.extra ? rp.extra : @""];
        if (getenv("TL_AVSTREAM_TRACE") || strstr(path, "/media.")) {
            char first[200]; snprintf(first, sizeof(first), "%s", req); first[strcspn(first, "\r\n")] = 0;
            tl_log_line("avstream: %s [range %lld-%lld] -> %d, %lu bytes", first, lo, hi, rp.status, (unsigned long)rp.body.length);
            if (strstr(path, "/media.") && getenv("TL_AVSTREAM_TRACE")) {
                char flat[900]; size_t k = 0;
                for (size_t i = 0; req[i] && k + 4 < sizeof(flat); i++) { if (req[i] == 13) continue; if (req[i] == 10) { flat[k++] = 32; flat[k++] = 124; flat[k++] = 32; } else flat[k++] = req[i]; }
                flat[k] = 0;
                tl_log_line("avstream: request was: %s", flat);
            }
        }
        bool sent = send_all(fd, head.UTF8String, strlen(head.UTF8String));
        if (sent && rp.body.length && strcmp(method, "HEAD")) send_all(fd, rp.body.bytes, rp.body.length);
        /* a whole file, sent as it downloads, until AVPlayer has had enough and closes */
        for (int64_t off = 0; sent && rp.stream && strcmp(method, "HEAD") && off < rp.stream_len; ) {
            @autoreleasepool {
                NSData *d = hfile_chunk(rp.stream, off, 1 << 20);
                if (!d.length) break;
                sent = send_all(fd, d.bytes, d.length);
                off += (int64_t)d.length;
            }
            if (getenv("TL_AVSTREAM_TRACE") && (!sent || off >= rp.stream_len)) tl_log_line("avstream: whole file: %lld of %lld bytes sent%s", (long long)off, (long long)rp.stream_len, sent ? "" : " (closed by AVPlayer)");
        }
    }
    close(fd);
    return NULL;
}

static void *server_main(void *arg)
{
    int ls = (int)(intptr_t)arg;
    for (;;) {
        int fd = accept(ls, NULL, NULL);
        if (fd < 0) continue;
        int one = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        pthread_t t; pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
        pthread_attr_setstacksize(&at, 512 << 10);
        if (pthread_create(&t, &at, serve_one, (void *)(intptr_t)fd) != 0) close(fd);
        pthread_attr_destroy(&at);
    }
    return NULL;
}

static void server_start(void)
{
    int ls = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = { .sin_len = sizeof(a), .sin_family = AF_INET, .sin_port = 0, .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    int one = 1; setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (ls < 0 || bind(ls, (struct sockaddr *)&a, sizeof(a)) || listen(ls, 32)) { tl_log_line("avstream: no local server"); return; }
    socklen_t l = sizeof(a); getsockname(ls, (struct sockaddr *)&a, &l);
    g_port = ntohs(a.sin_port);
    pthread_t t; pthread_create(&t, NULL, server_main, (void *)(intptr_t)ls); pthread_detach(t);
    tl_log_line("avstream: local server on 127.0.0.1:%d", g_port);
}

/* ======================================================================== raw MPEG-TS -> live HLS */

#define TS 188
#define KEEP 12

@interface HTsRelay : NSObject <NSURLSessionDataDelegate>
@end

@implementation HTsRelay {
@public
    pthread_mutex_t mu; pthread_cond_t cv;
    NSURLSession *session; NSURLSessionDataTask *task;
    NSMutableData *carry, *cur;
    NSMutableArray<NSData *> *segs; NSMutableArray<NSNumber *> *durs;
    uint64_t first_seq;                 /* the sequence number of segs[0] */
    uint64_t wanted;                    /* the highest segment AVPlayer asked for */
    uint8_t pat[TS], pmt[TS]; bool have_pat, have_pmt; int pmt_pid;
    int64_t seg_pts0, last_pts; double seg_wall0;
    bool ended, failed, paused;
    double last_access;
}

- (instancetype)initWithURL:(NSURL *)url headers:(NSDictionary *)hdr
{
    if (!(self = [super init])) return nil;
    pthread_mutex_init(&mu, NULL); pthread_cond_init(&cv, NULL);
    carry = [NSMutableData data]; cur = [NSMutableData data];
    segs = [NSMutableArray array]; durs = [NSMutableArray array];
    pmt_pid = -1; seg_pts0 = -1; last_pts = -1; seg_wall0 = CFAbsoluteTimeGetCurrent(); last_access = seg_wall0;
    NSURLSessionConfiguration *c = [NSURLSessionConfiguration defaultSessionConfiguration];
    c.timeoutIntervalForRequest = 30;
    session = [NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:nil];
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:url];
    for (NSString *k in hdr) [rq setValue:hdr[k] forHTTPHeaderField:k];
    task = [session dataTaskWithRequest:rq];
    [task resume];
    return self;
}

static int64_t pes_pts(const uint8_t *p, size_t n)
{
    if (n < 14 || p[0] || p[1] || p[2] != 1) return -1;
    uint8_t sid = p[3];
    if (!((sid >= 0xE0 && sid <= 0xEF) || (sid >= 0xC0 && sid <= 0xDF))) return -1;
    if (!(p[7] & 0x80)) return -1;
    return ((int64_t)(p[9] & 0x0E) << 29) | ((int64_t)p[10] << 22) | ((int64_t)(p[11] & 0xFE) << 14) | ((int64_t)p[12] << 7) | (p[13] >> 1);
}

- (void)cutSegment
{
    if (!cur.length) return;
    double d;
    if (seg_pts0 >= 0 && last_pts > seg_pts0) d = (double)(last_pts - seg_pts0) / 90000.0;
    else d = CFAbsoluteTimeGetCurrent() - seg_wall0;
    if (d < 0.1) d = 0.1;
    [segs addObject:[cur copy]]; [durs addObject:@(d)];
    /* segments AVPlayer is past go; the rest wait for it (reading pauses when it is far behind) */
    while (segs.count > 40 || (segs.count > 3 && first_seq + 3 < wanted)) { [segs removeObjectAtIndex:0]; [durs removeObjectAtIndex:0]; first_seq++; }
    cur = [NSMutableData data];
    if (have_pat) [cur appendBytes:pat length:TS];
    if (have_pmt) [cur appendBytes:pmt length:TS];
    seg_pts0 = -1; seg_wall0 = CFAbsoluteTimeGetCurrent();
    pthread_cond_broadcast(&cv);
}

- (void)packet:(const uint8_t *)b
{
    int pid = ((b[1] & 0x1F) << 8) | b[2];
    bool pusi = b[1] & 0x40;
    int afc = (b[3] >> 4) & 3;
    size_t off = 4;
    bool rai = false;
    if (afc & 2) { uint8_t alen = b[4]; if (alen > 0) rai = (b[5] & 0x40) != 0; off = 5 + alen; }
    if (pid == 0 && pusi && off < TS) {
        memcpy(pat, b, TS); have_pat = true;
        size_t s = off + 1 + b[off];                       /* the pointer field */
        if (s + 12 <= TS) {
            for (size_t e = s + 8; e + 4 <= TS && e + 4 <= s + 3 + (((b[s + 1] & 0x0F) << 8) | b[s + 2]) - 4; e += 4) {
                int prog = (b[e] << 8) | b[e + 1];
                if (prog) { pmt_pid = ((b[e + 2] & 0x1F) << 8) | b[e + 3]; break; }
            }
        }
    } else if (pid == pmt_pid && pusi) { memcpy(pmt, b, TS); have_pmt = true; }
    int64_t pts = (pusi && (afc & 1) && off < TS) ? pes_pts(b + off, TS - off) : -1;
    if (pts >= 0) {
        bool video = b[off + 3] >= 0xE0 && b[off + 3] <= 0xEF;
        if (video || last_pts < 0) {
            double media = seg_pts0 >= 0 ? (double)(pts - seg_pts0) / 90000.0 : 0;
            double wall = CFAbsoluteTimeGetCurrent() - seg_wall0;
            bool due = (seg_pts0 >= 0 && media >= 2.0 && (rai || media >= 6.0)) || (seg_pts0 < 0 && wall >= 6.0);
            if (due && cur.length > 2 * TS) [self cutSegment];
            if (seg_pts0 < 0 || pts < seg_pts0) seg_pts0 = pts;
            last_pts = pts;
        }
    }
    [cur appendBytes:b length:TS];
}

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)data
{
    pthread_mutex_lock(&mu);
    [carry appendData:data];
    const uint8_t *p = carry.bytes; size_t n = carry.length, i = 0;
    while (i + TS <= n) {
        if (p[i] != 0x47 || (i + 2 * TS <= n && p[i + TS] != 0x47)) { i++; continue; }   /* find the packet boundary again */
        [self packet:p + i];
        i += TS;
    }
    [carry replaceBytesInRange:NSMakeRange(0, i) withBytes:NULL length:0];
    /* a file read faster than it plays: wait while AVPlayer is far behind */
    if (!paused && first_seq + segs.count > wanted + KEEP) { paused = true; [t suspend]; }
    pthread_mutex_unlock(&mu);
}

- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)e
{
    pthread_mutex_lock(&mu);
    if (e && e.code != NSURLErrorCancelled) { failed = segs.count == 0; tl_log_line("avstream: TS source ended: %s", e.localizedDescription.UTF8String); }
    [self cutSegment];
    ended = true;
    pthread_cond_broadcast(&cv);
    pthread_mutex_unlock(&mu);
}

- (NSData *)playlist
{
    pthread_mutex_lock(&mu);
    last_access = CFAbsoluteTimeGetCurrent();
    struct timespec until; clock_gettime(CLOCK_REALTIME, &until); until.tv_sec += 20;
    while (segs.count < 3 && !ended) if (pthread_cond_timedwait(&cv, &mu, &until)) break;
    double target = 1;
    for (NSNumber *d in durs) if (d.doubleValue > target) target = d.doubleValue;
    NSMutableString *m = [NSMutableString stringWithFormat:@"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:%d\n#EXT-X-MEDIA-SEQUENCE:%llu\n",
                          (int)ceil(target), (unsigned long long)first_seq];
    /* a file (its length known) plays from its start; a live channel from its live edge, as AVPlayer does by itself */
    if (task.response.expectedContentLength > 0) [m appendString:@"#EXT-X-PLAYLIST-TYPE:EVENT\n#EXT-X-START:TIME-OFFSET=0,PRECISE=YES\n"];
    for (NSUInteger i = 0; i < segs.count; i++) [m appendFormat:@"#EXTINF:%.3f,\n%llu.ts\n", durs[i].doubleValue, (unsigned long long)(first_seq + i)];
    if (ended) [m appendString:@"#EXT-X-ENDLIST\n"];
    pthread_mutex_unlock(&mu);
    return [m dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)segment:(uint64_t)seq
{
    pthread_mutex_lock(&mu);
    last_access = CFAbsoluteTimeGetCurrent();
    if (seq > wanted) wanted = seq;
    NSData *d = seq >= first_seq && seq < first_seq + segs.count ? segs[(NSUInteger)(seq - first_seq)] : nil;
    if (paused && first_seq + segs.count <= wanted + KEEP) { paused = false; [task resume]; }
    pthread_mutex_unlock(&mu);
    return d;
}

- (void)stop { [task cancel]; [session invalidateAndCancel]; }
@end

/* ======================================================================== a file, with byte ranges */

/* AVPlayer reads an MP4 by byte ranges and gives up on a server that cannot serve them, or that turns its requests away. This
   reads the file once, in order, with the app's headers, into a temporary file, and serves AVPlayer the ranges it asks for as soon
   as they have arrived. */
@interface HFile : NSObject <NSURLSessionDataDelegate>
@end

@implementation HFile {
@public
    pthread_mutex_t mu; pthread_cond_t cv;
    NSURLSession *session; NSURLSessionDataTask *task;
    int fd; char path[600];
    int64_t have, total;
    bool done, failed;
    NSString *mime;
}

- (instancetype)initWithURL:(NSURL *)url headers:(NSDictionary *)hdr
{
    if (!(self = [super init])) return nil;
    pthread_mutex_init(&mu, NULL); pthread_cond_init(&cv, NULL);
    total = -1;
    snprintf(path, sizeof(path), "%s/husk-av-XXXXXX", NSTemporaryDirectory().fileSystemRepresentation);
    fd = mkstemp(path);
    NSURLSessionConfiguration *c = [NSURLSessionConfiguration defaultSessionConfiguration];
    c.timeoutIntervalForRequest = 30;
    session = [NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:nil];
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:url];
    for (NSString *k in hdr) [rq setValue:hdr[k] forHTTPHeaderField:k];
    task = [session dataTaskWithRequest:rq];
    [task resume];
    return self;
}

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveResponse:(NSURLResponse *)r completionHandler:(void (^)(NSURLSessionResponseDisposition))done_
{
    pthread_mutex_lock(&mu);
    total = r.expectedContentLength > 0 ? r.expectedContentLength : -1;
    mime = r.MIMEType;
    pthread_cond_broadcast(&cv);
    pthread_mutex_unlock(&mu);
    done_(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)data
{
    pthread_mutex_lock(&mu);
    if (fd >= 0) pwrite(fd, data.bytes, data.length, have);
    have += (int64_t)data.length;
    pthread_cond_broadcast(&cv);
    pthread_mutex_unlock(&mu);
}

- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)e
{
    pthread_mutex_lock(&mu);
    done = true;
    if (e && have == 0) failed = true;
    if (total < 0 || (e && have < total)) total = have;
    pthread_cond_broadcast(&cv);
    pthread_mutex_unlock(&mu);
}

/* bytes [lo, hi] (hi -1: to the end), once they are here */
- (reply)serve:(int64_t)lo to:(int64_t)hi
{
    reply r = { nil, nil, 404, nil, nil, 0 };
    pthread_mutex_lock(&mu);
    struct timespec until; clock_gettime(CLOCK_REALTIME, &until); until.tv_sec += 60;
    while (total < 0 && !done) if (pthread_cond_timedwait(&cv, &mu, &until)) break;
    int64_t len = total;
    if (failed || len <= 0) { pthread_mutex_unlock(&mu); return r; }
    if (lo < 0) {
        /* no Range: the whole file, 200, sent as it arrives (serve_one); AVPlayer asks for ranges after it has seen this */
        pthread_mutex_unlock(&mu);
        r.status = 200; r.stream = self; r.stream_len = len; r.type = mime ? mime : @"video/mp4";
        r.extra = @"Accept-Ranges: bytes\r\n";
        return r;
    }
    if (hi < 0 || hi >= len) hi = len - 1;
    if (lo >= len) { pthread_mutex_unlock(&mu); r.status = 416; r.extra = [NSString stringWithFormat:@"Content-Range: bytes */%lld\r\n", (long long)len]; return r; }
    if (hi - lo + 1 > (8 << 20)) hi = lo + (8 << 20) - 1;          /* at most 8 MiB an answer: AVPlayer asks again for the rest */
    while (have <= hi && !done) if (pthread_cond_timedwait(&cv, &mu, &until)) break;
    if (have <= hi) hi = have - 1;
    pthread_mutex_unlock(&mu);
    if (hi < lo) return r;
    NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)(hi - lo + 1)];
    ssize_t got = pread(fd, d.mutableBytes, d.length, lo);
    if (got <= 0) return r;
    d.length = (NSUInteger)got;
    r.body = d; r.type = mime ? mime : @"video/mp4";
    r.status = 206;
    r.extra = [NSString stringWithFormat:@"Accept-Ranges: bytes\r\nContent-Range: bytes %lld-%lld/%lld\r\n", (long long)lo, (long long)(lo + got - 1), (long long)len];
    return r;
}

- (NSData *)chunkAt:(int64_t)off max:(size_t)max
{
    pthread_mutex_lock(&mu);
    struct timespec until; clock_gettime(CLOCK_REALTIME, &until); until.tv_sec += 60;
    while (have <= off && !done && fd >= 0) if (pthread_cond_timedwait(&cv, &mu, &until)) break;
    int64_t n = have - off;
    int f = fd;
    pthread_mutex_unlock(&mu);
    if (n <= 0 || f < 0) return nil;
    if (n > (int64_t)max) n = (int64_t)max;
    NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)n];
    ssize_t got = pread(f, d.mutableBytes, d.length, off);
    if (got <= 0) return nil;
    d.length = (NSUInteger)got;
    return d;
}

- (void)stop { [task cancel]; [session invalidateAndCancel]; pthread_mutex_lock(&mu); if (fd >= 0) { close(fd); fd = -1; unlink(path); } pthread_cond_broadcast(&cv); pthread_mutex_unlock(&mu); }
@end

static NSData *hfile_chunk(id f, int64_t off, size_t max) { return [(HFile *)f chunkAt:off max:max]; }

/* ======================================================================== ClearKey */

static pthread_mutex_t g_key_lock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary<NSData *, NSData *> *g_keys;          /* KID (16 bytes, or empty: any) -> key (16 bytes) */
static NSString *g_license; static NSDictionary *g_license_hdr;  /* a ClearKey license server, for KIDs no key was given for */
static NSMutableSet<NSData *> *g_asked;                          /* KIDs the license server was asked for already */

static NSData *key_bytes(id v)          /* base64url, as a JSON Web Key has it, or 32 hex digits */
{
    if (![v isKindOfClass:[NSString class]]) return nil;
    NSString *s = v;
    if (s.length == 32 && [s rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet]].location == NSNotFound) {
        uint8_t b[16];
        for (int i = 0; i < 16; i++) b[i] = (uint8_t)strtoul([[s substringWithRange:NSMakeRange(2 * i, 2)] UTF8String], NULL, 16);
        return [NSData dataWithBytes:b length:16];
    }
    NSMutableString *t = [[[s stringByReplacingOccurrencesOfString:@"-" withString:@"+"] stringByReplacingOccurrencesOfString:@"_" withString:@"/"] mutableCopy];
    while (t.length % 4) [t appendString:@"="];
    return [[NSData alloc] initWithBase64EncodedString:t options:NSDataBase64DecodingIgnoreUnknownCharacters];
}

static NSString *b64url(NSData *d)
{
    NSString *s = [d base64EncodedStringWithOptions:0];
    s = [[s stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [s stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

/* {"keys":[{"kty":"oct","kid":"...","k":"..."}]}: a JSON Web Key set, which a ClearKey license is. The keys it held. */
static int add_keys(NSData *json)
{
    if (!json) return 0;
    id o = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    NSArray *keys = [o isKindOfClass:[NSDictionary class]] ? o[@"keys"] : nil;
    if (![keys isKindOfClass:[NSArray class]]) return 0;
    int n = 0;
    pthread_mutex_lock(&g_key_lock);
    if (!g_keys) g_keys = [NSMutableDictionary dictionary];
    for (NSDictionary *k in keys) {
        if (![k isKindOfClass:[NSDictionary class]]) continue;
        NSData *key = key_bytes(k[@"k"]), *kid = key_bytes(k[@"kid"]);
        if (key.length != 16) continue;
        g_keys[kid.length == 16 ? kid : [NSData data]] = key;
        n++;
    }
    pthread_mutex_unlock(&g_key_lock);
    return n;
}

/* ClearKey keys (a JSON Web Key set) and/or the license server the app gave its player (husk.AvPlayer.nClearKey) */
void tl_av_clearkey(NSString *keys, NSString *license, NSDictionary *hdr);
void tl_av_clearkey(NSString *keys, NSString *license, NSDictionary *hdr)
{
    int n = keys ? add_keys([keys dataUsingEncoding:NSUTF8StringEncoding]) : 0;
    pthread_mutex_lock(&g_key_lock);
    if (license.length) { g_license = license; g_license_hdr = hdr; }
    pthread_mutex_unlock(&g_key_lock);
    if (keys) tl_log_line("avstream: ClearKey: %d key(s) from the app", n);
    if (license.length) tl_log_line("avstream: ClearKey license server: %s", license.UTF8String);
}

static bool have_clearkey(void)
{
    pthread_mutex_lock(&g_key_lock);
    bool r = g_keys.count || g_license;
    pthread_mutex_unlock(&g_key_lock);
    return r;
}

static NSData *post_json(NSString *url, NSDictionary *hdr, id body)
{
    NSURL *u = [NSURL URLWithString:url];
    if (!u) return nil;
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:u cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    rq.HTTPMethod = @"POST";
    rq.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [rq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    for (NSString *k in hdr) [rq setValue:hdr[k] forHTTPHeaderField:k];
    __block NSData *out = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:rq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSInteger code = [r isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)r).statusCode : 200;
        if (!e && code < 400) out = d;
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
    return out;
}

/* the key for kid: given by the app, else asked of its license server (once), else the app's only key */
static NSData *key_for(const uint8_t kid[16])
{
    NSData *k = [NSData dataWithBytes:kid length:16];
    pthread_mutex_lock(&g_key_lock);
    NSData *key = g_keys[k];
    NSString *lic = nil; NSDictionary *lh = nil;
    if (!key && g_license && ![g_asked containsObject:k]) {
        if (!g_asked) g_asked = [NSMutableSet set];
        [g_asked addObject:k];
        lic = g_license; lh = g_license_hdr;
    }
    pthread_mutex_unlock(&g_key_lock);
    if (lic) {
        int n = add_keys(post_json(lic, lh, @{ @"kids": @[ b64url(k) ], @"type": @"temporary" }));
        tl_log_line("avstream: ClearKey license server answered with %d key(s)", n);
        pthread_mutex_lock(&g_key_lock); key = g_keys[k]; pthread_mutex_unlock(&g_key_lock);
    }
    if (!key) {
        pthread_mutex_lock(&g_key_lock);
        key = g_keys[[NSData data]];
        if (!key && g_keys.count == 1) key = g_keys.allValues.firstObject;
        pthread_mutex_unlock(&g_key_lock);
    }
    return key;
}

/* ======================================================================== CENC: encrypted fMP4 made plain */

#define FOURCC(s) ((uint32_t)(uint8_t)(s)[0] << 24 | (uint32_t)(uint8_t)(s)[1] << 16 | (uint32_t)(uint8_t)(s)[2] << 8 | (uint32_t)(uint8_t)(s)[3])
static uint16_t be16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint64_t be64(const uint8_t *p) { return (uint64_t)be32(p) << 32 | be32(p + 4); }
static void put32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v; }

/* the box at p (n bytes left): its type, header and whole size */
static bool box_at(const uint8_t *p, size_t n, uint32_t *type, size_t *hdr, size_t *size)
{
    if (n < 8) return false;
    uint64_t s = be32(p);
    *hdr = 8; *type = be32(p + 4);
    if (s == 1) { if (n < 16) return false; s = be64(p + 8); *hdr = 16; }
    else if (s == 0) s = n;
    if (s < *hdr || s > n) return false;
    *size = (size_t)s;
    return true;
}
#define EACH_BOX(p, n, o, ty, h, sz) for (size_t o = 0, h = 0, sz = 0; o < (n); o += sz) { uint32_t ty; if (!box_at((p) + o, (n) - o, &ty, &h, &sz)) break;
#define END_BOXES }

typedef struct {
    bool on;                            /* the track is encrypted */
    uint32_t scheme;                    /* 'cenc', 'cbcs' */
    uint8_t kid[16];
    uint8_t iv_size, const_iv_size, const_iv[16];
    uint8_t crypt, skip;                /* the cbcs pattern, in 16-byte blocks */
    uint32_t default_size;              /* trex's default sample size */
} tcrypt;

static void read_sinf(const uint8_t *p, size_t n, tcrypt *t, uint32_t *orig)
{
    EACH_BOX(p, n, o, ty, h, sz)
        const uint8_t *b = p + o + h; size_t bn = sz - h;
        if (ty == FOURCC("frma") && bn >= 4) *orig = be32(b);
        else if (ty == FOURCC("schm") && bn >= 8) t->scheme = be32(b + 4);
        else if (ty == FOURCC("schi")) read_sinf(b, bn, t, orig);
        else if (ty == FOURCC("tenc") && bn >= 24) {
            if (b[0] >= 1) { t->crypt = b[5] >> 4; t->skip = b[5] & 15; }
            t->on = b[6] != 0; t->iv_size = b[7]; memcpy(t->kid, b + 8, 16);
            if (t->on && !t->iv_size && bn >= 25 && b[24] <= 16 && bn >= 25u + b[24]) { t->const_iv_size = b[24]; memcpy(t->const_iv, b + 25, b[24]); }
        }
    END_BOXES
}

/* An init segment: its encrypted sample entry (encv/enca) becomes the original format again, its sinf and the pssh boxes become
   'free' (same sizes, nothing moves), and what the track's encryption is goes into *t. */
static void init_clear(uint8_t *p, size_t n, tcrypt *t)
{
    EACH_BOX(p, n, o, ty, h, sz)
        uint8_t *b = p + o + h; size_t bn = sz - h;
        if (ty == FOURCC("moov") || ty == FOURCC("trak") || ty == FOURCC("mdia") || ty == FOURCC("minf") || ty == FOURCC("stbl") || ty == FOURCC("mvex"))
            init_clear(b, bn, t);
        else if (ty == FOURCC("pssh")) put32(p + o + 4, FOURCC("free"));
        else if (ty == FOURCC("trex") && bn >= 24) t->default_size = be32(b + 16);
        else if (ty == FOURCC("stsd") && bn >= 8) {
            uint8_t *e = b + 8; size_t en = bn - 8;
            EACH_BOX(e, en, q, et, eh, es)
                if (et != FOURCC("encv") && et != FOURCC("enca")) continue;
                size_t fixed = et == FOURCC("encv") ? 78 : 28;
                if (et == FOURCC("enca") && es >= eh + 10) { uint16_t v = be16(e + q + eh + 8); fixed += v == 1 ? 16 : v == 2 ? 36 : 0; }
                if (es <= eh + fixed) continue;
                uint8_t *c = e + q + eh + fixed; size_t cn = es - eh - fixed;
                uint32_t orig = 0;
                EACH_BOX(c, cn, r, ct, ch, cs)
                    if (ct == FOURCC("sinf")) { read_sinf(c + r + ch, cs - ch, t, &orig); put32(c + r + 4, FOURCC("free")); }
                END_BOXES
                if (orig) put32(e + q + 4, orig);
            END_BOXES
        }
    END_BOXES
}

/* AES-CBC over the encrypted range of a cbcs subsample: crypt blocks of each crypt+skip, from a fresh IV; a partial block stays clear */
static void cbc_range(const tcrypt *t, const uint8_t *key, const uint8_t iv[16], uint8_t *p, size_t n)
{
    CCCryptorRef c;
    if (CCCryptorCreate(kCCDecrypt, kCCAlgorithmAES, 0, key, 16, iv, &c) != kCCSuccess) return;
    size_t blocks = n / 16, crypt = t->crypt, skip = t->skip;
    if (!crypt) { crypt = blocks; skip = 0; }
    for (size_t b = 0; b < blocks; b += crypt + skip) {
        size_t k = crypt < blocks - b ? crypt : blocks - b, moved;
        CCCryptorUpdate(c, p + 16 * b, 16 * k, p + 16 * b, 16 * k, &moved);
    }
    CCCryptorRelease(c);
}

/* one sample, in place: subsamples (clear, encrypted) as senc lists them (6 bytes each), or all of it encrypted */
static void sample_clear(const tcrypt *t, const uint8_t *key, const uint8_t *iv, size_t ivn, uint8_t *p, size_t n, const uint8_t *sub, unsigned nsub)
{
    uint8_t ivb[16] = { 0 };
    memcpy(ivb, iv, ivn < 16 ? ivn : 16);
    bool cbcs = t->scheme == FOURCC("cbcs");
    CCCryptorRef ctr = NULL;
    if (!cbcs && CCCryptorCreateWithMode(kCCDecrypt, kCCModeCTR, kCCAlgorithmAES, ccNoPadding, ivb, key, 16, NULL, 0, 0, kCCModeOptionCTR_BE, &ctr) != kCCSuccess) return;
    size_t off = 0;
    for (unsigned i = 0; i < (nsub ? nsub : 1) && off < n; i++) {
        size_t clear = nsub ? be16(sub + 6 * i) : 0, enc = nsub ? be32(sub + 6 * i + 2) : n;
        if (clear > n - off) clear = n - off;
        off += clear;
        if (enc > n - off) enc = n - off;
        if (enc) {
            size_t moved;
            if (cbcs) cbc_range(t, key, ivb, p + off, enc);              /* the key stream of CTR runs on across subsamples */
            else CCCryptorUpdate(ctr, p + off, enc, p + off, enc, &moved);
        }
        off += enc;
    }
    if (ctr) CCCryptorRelease(ctr);
}

static const uint8_t k_piff_senc[16] = { 0xa2, 0x39, 0x4f, 0x52, 0x5a, 0x9b, 0x4f, 0x14, 0xa2, 0x44, 0x6c, 0x42, 0x7c, 0x64, 0x8d, 0xf4 };

/* the samples of one track fragment, in place in the whole segment (file, fn); the encryption boxes become 'free'. Samples made plain. */
static int traf_clear(uint8_t *file, size_t fn, size_t moof_at, size_t mdat_data, uint8_t *p, size_t n, const tcrypt *t, const uint8_t *key)
{
    const uint8_t *tfhd = NULL, *senc = NULL, *trun[32];
    size_t tfhd_n = 0, senc_n = 0, trun_n[32];
    int ntrun = 0; bool piff = false;
    EACH_BOX(p, n, o, ty, h, sz)
        uint8_t *b = p + o + h; size_t bn = sz - h;
        if (ty == FOURCC("tfhd")) { tfhd = b; tfhd_n = bn; }
        else if (ty == FOURCC("trun") && ntrun < 32) { trun[ntrun] = b; trun_n[ntrun++] = bn; }
        else if (ty == FOURCC("senc")) { senc = b; senc_n = bn; put32(p + o + 4, FOURCC("free")); }
        else if (ty == FOURCC("uuid") && bn >= 16 && !memcmp(b, k_piff_senc, 16)) { senc = b + 16; senc_n = bn - 16; piff = true; put32(p + o + 4, FOURCC("free")); }
        else if (ty == FOURCC("saiz") || ty == FOURCC("saio")) put32(p + o + 4, FOURCC("free"));
        else if ((ty == FOURCC("sbgp") || ty == FOURCC("sgpd")) && bn >= 8 && be32(b + 4) == FOURCC("seig")) put32(p + o + 4, FOURCC("free"));
    END_BOXES
    if (!tfhd || tfhd_n < 8 || !ntrun) return 0;
    uint32_t tf = be32(tfhd) & 0xffffff;
    size_t q = 8;
    uint64_t base = moof_at; bool have_base = false;
    if (tf & 0x1) { if (tfhd_n < q + 8) return 0; base = be64(tfhd + q); q += 8; have_base = true; }
    if (tf & 0x2) q += 4;
    if (tf & 0x8) q += 4;
    uint32_t dsize = t->default_size;
    if (tf & 0x10) { if (tfhd_n < q + 4) return 0; dsize = be32(tfhd + q); }
    uint32_t sflags = 0, scount = 0;
    const uint8_t *sp = NULL, *se = NULL;
    if (senc && senc_n >= 8) {
        sflags = be32(senc) & 0xffffff; sp = senc + 4;
        if (piff && (sflags & 1)) sp += 20;           /* PIFF: its own AlgorithmID, IV size and KID; the track's are used */
        se = senc + senc_n;
        if (sp + 4 <= se) { scount = be32(sp); sp += 4; } else sp = NULL;
    }
    if (!sp && t->iv_size) return 0;                  /* the IVs are elsewhere (saio only): not read here */
    size_t pos = 0; bool pos_set = false;
    uint32_t si = 0; int done = 0;
    for (int r = 0; r < ntrun; r++) {
        const uint8_t *tr = trun[r]; size_t tn = trun_n[r];
        if (tn < 8) break;
        uint32_t f = be32(tr) & 0xffffff, cnt = be32(tr + 4);
        size_t k = 8;
        if (f & 0x1) { if (tn < k + 4) break; pos = (size_t)((int64_t)base + (int32_t)be32(tr + k)); k += 4; pos_set = true; }
        else if (!pos_set) { pos = have_base ? (size_t)base : mdat_data; pos_set = true; }
        if (f & 0x4) k += 4;
        size_t per = ((f & 0x100) ? 4 : 0) + ((f & 0x200) ? 4 : 0) + ((f & 0x400) ? 4 : 0) + ((f & 0x800) ? 4 : 0);
        for (uint32_t i = 0; i < cnt; i++, si++) {
            if (k + per > tn) return done;
            size_t size = (f & 0x200) ? be32(tr + k + ((f & 0x100) ? 4 : 0)) : dsize;
            k += per;
            const uint8_t *iv = t->const_iv, *sub = NULL; size_t ivn = t->const_iv_size; unsigned ns = 0;
            if (sp) {
                if (si >= scount) return done;
                if (t->iv_size) { if (sp + t->iv_size > se) return done; iv = sp; ivn = t->iv_size; sp += t->iv_size; }
                if (sflags & 2) { if (sp + 2 > se) return done; ns = be16(sp); sp += 2; if (sp + 6u * ns > se) return done; sub = sp; sp += 6u * ns; }
            }
            if (pos > fn || size > fn - pos) return done;
            sample_clear(t, key, iv, ivn, file + pos, size, sub, ns);
            pos += size; done++;
        }
    }
    return done;
}

/* A media segment, in place. Samples made plain. */
static int segment_clear(uint8_t *p, size_t n, const tcrypt *t, const uint8_t *key)
{
    int done = 0;
    EACH_BOX(p, n, o, ty, h, sz)
        if (ty != FOURCC("moof")) continue;
        size_t mdat_data = o + sz; uint32_t nt; size_t nh, ns;
        if (box_at(p + o + sz, n - o - sz, &nt, &nh, &ns) && nt == FOURCC("mdat")) mdat_data += nh;
        uint8_t *m = p + o + h; size_t mn = sz - h;
        EACH_BOX(m, mn, q, mt, mh, ms)
            if (mt == FOURCC("pssh")) put32(m + q + 4, FOURCC("free"));
            else if (mt == FOURCC("traf")) done += traf_clear(p, n, o, mdat_data, m + q + mh, ms - mh, t, key);
        END_BOXES
    END_BOXES
    return done;
}

/* ======================================================================== DASH -> HLS */

@interface HNode : NSObject
@property NSString *name; @property NSDictionary<NSString *, NSString *> *attrs; @property NSMutableArray<HNode *> *kids;
@property NSMutableString *text; @property (weak) HNode *parent;
@end
@implementation HNode
- (HNode *)kid:(NSString *)n { for (HNode *k in self.kids) if ([k.name isEqualToString:n]) return k; return nil; }
- (NSArray<HNode *> *)all:(NSString *)n { NSMutableArray *r = [NSMutableArray array]; for (HNode *k in self.kids) if ([k.name isEqualToString:n]) [r addObject:k]; return r; }
@end

@interface HXml : NSObject <NSXMLParserDelegate> { @public HNode *root, *at; }
@end
@implementation HXml
- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)e namespaceURI:(NSString *)ns qualifiedName:(NSString *)q attributes:(NSDictionary *)a
{
    HNode *n = [HNode new]; n.name = e; n.attrs = a; n.kids = [NSMutableArray array]; n.text = [NSMutableString string]; n.parent = at;
    if (at) [at.kids addObject:n]; else root = n;
    at = n;
}
- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)e namespaceURI:(NSString *)ns qualifiedName:(NSString *)q { at = at.parent; }
- (void)parser:(NSXMLParser *)p foundCharacters:(NSString *)s { [at.text appendString:s]; }
@end

static double iso_duration(NSString *s)      /* PT1H2M3.5S */
{
    if (!s) return 0;
    double t = 0, v = 0; bool time = false; NSScanner *sc = [NSScanner scannerWithString:s];
    while (!sc.isAtEnd) {
        if ([sc scanString:@"P" intoString:NULL]) continue;
        if ([sc scanString:@"T" intoString:NULL]) { time = true; continue; }
        if (![sc scanDouble:&v]) { sc.scanLocation++; continue; }
        NSString *u = nil; [sc scanCharactersFromSet:[NSCharacterSet letterCharacterSet] intoString:&u];
        if ([u isEqualToString:@"D"]) t += v * 86400; else if ([u isEqualToString:@"H"]) t += v * 3600;
        else if ([u isEqualToString:@"M"]) t += time ? v * 60 : v * 30 * 86400; else if ([u isEqualToString:@"S"]) t += v;
    }
    return t;
}

static double iso_date(NSString *s)
{
    if (!s) return 0;
    NSISO8601DateFormatter *f = [NSISO8601DateFormatter new];
    f.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *d = [f dateFromString:s];
    if (!d) { f.formatOptions = NSISO8601DateFormatWithInternetDateTime; d = [f dateFromString:s]; }
    return d ? d.timeIntervalSince1970 : 0;
}

static NSString *fill_template(NSString *t, NSString *rep, NSString *bw, uint64_t number, uint64_t time)
{
    NSMutableString *o = [NSMutableString string];
    NSScanner *sc = [NSScanner scannerWithString:t]; sc.charactersToBeSkipped = nil;
    while (!sc.isAtEnd) {
        NSString *lit = nil; [sc scanUpToString:@"$" intoString:&lit]; if (lit) [o appendString:lit];
        if (sc.isAtEnd) break;
        sc.scanLocation++;
        NSString *id = nil; [sc scanUpToString:@"$" intoString:&id]; if (!sc.isAtEnd) sc.scanLocation++;
        if (!id.length) { [o appendString:@"$"]; continue; }
        NSString *name = id, *fmt = @"%llu";
        NSRange pr = [id rangeOfString:@"%"];
        if (pr.location != NSNotFound) { name = [id substringToIndex:pr.location]; fmt = [[id substringFromIndex:pr.location] stringByReplacingOccurrencesOfString:@"d" withString:@"llu"]; }
        if ([name isEqualToString:@"RepresentationID"]) [o appendString:rep ? rep : @""];
        else if ([name isEqualToString:@"Bandwidth"]) [o appendString:bw ? bw : @""];
        else if ([name isEqualToString:@"Number"]) [o appendFormat:fmt, (unsigned long long)number];
        else if ([name isEqualToString:@"Time"]) [o appendFormat:fmt, (unsigned long long)time];
        else [o appendFormat:@"$%@$", id];
    }
    return o;
}

typedef struct { NSString *url; double dur; } dseg;

@interface HDash : NSObject @end
@implementation HDash {
@public
    NSURL *mpd_url; NSDictionary *hdr;
    NSString *master, *vlist, *alist;
    double fetched, refresh; bool dynamic, ok;
    NSString *why;
    pthread_mutex_t mu;
    /* encrypted (ClearKey): segments are served from here, decrypted, under names of their own ("v12.m4s", "vinit3.mp4") */
    bool enc;
    NSMutableDictionary<NSString *, NSString *> *u2k, *k2u, *nu2k, *nk2u;
    uint64_t nkey;
    NSString *init_url[2];              /* v, a */
    tcrypt tc[2]; bool tc_known[2], told;
}

static NSData *fetch(NSURL *u, NSDictionary *hdr, NSURL **final)
{
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:u cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    for (NSString *k in hdr) [rq setValue:hdr[k] forHTTPHeaderField:k];
    __block NSData *out = nil; __block NSURL *fin = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:rq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSInteger code = [r isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)r).statusCode : 200;
        if (!e && code < 400) { out = d; fin = r.URL; }
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC));
    if (final) *final = fin ? fin : u;
    return out;
}

static NSURL *base_of(HNode *n, NSURL *doc)
{
    NSMutableArray *chain = [NSMutableArray array];
    for (HNode *k = n; k; k = k.parent) { HNode *b = [k kid:@"BaseURL"]; if (b) [chain insertObject:b atIndex:0]; }
    NSURL *u = doc;
    for (HNode *b in chain) {
        NSString *t = [b.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) u = [NSURL URLWithString:t relativeToURL:u].absoluteURL;
    }
    return u;
}

static HNode *inherit(HNode *rep, NSString *name)        /* SegmentTemplate/SegmentList on the Representation, else its set, else the Period */
{
    for (HNode *k = rep; k; k = k.parent) { HNode *t = [k kid:name]; if (t) return t; }
    return nil;
}

static NSString *attr_up(HNode *n, NSString *a) { for (HNode *k = n; k; k = k.parent) if (k.attrs[a]) return k.attrs[a]; return nil; }

/* one Representation as an HLS media playlist; NO when its segments cannot be described */
/* the name a segment is served under (encrypted streams), the same for as long as the MPD lists it */
- (NSString *)name:(NSString *)u list:(int)w init:(bool)ini
{
    pthread_mutex_lock(&mu);
    NSString *k = u2k[u];
    if (!k) k = [NSString stringWithFormat:ini ? @"%cinit%llu.mp4" : @"%c%llu.m4s", w ? 'a' : 'v', (unsigned long long)++nkey];
    nu2k[u] = k; nk2u[k] = u;
    if (ini) init_url[w] = u;
    pthread_mutex_unlock(&mu);
    return k;
}

- (NSString *)mediaList:(HNode *)rep doc:(NSURL *)doc now:(double)now ast:(double)ast period:(double)pstart total:(double)total depth:(double)depth list:(int)w
{
    NSURL *base = base_of(rep, doc);
    NSString *rid = rep.attrs[@"id"], *bw = rep.attrs[@"bandwidth"];
    NSMutableArray<NSValue *> *list = [NSMutableArray array];
    NSMutableArray *urls = [NSMutableArray array], *durs = [NSMutableArray array];
    NSString *init = nil;
    uint64_t first_number = 0;
    HNode *st = inherit(rep, @"SegmentTemplate");
    HNode *sl = inherit(rep, @"SegmentList");
    if (st) {
        double ts = st.attrs[@"timescale"] ? st.attrs[@"timescale"].doubleValue : 1;
        uint64_t start = st.attrs[@"startNumber"] ? (uint64_t)st.attrs[@"startNumber"].longLongValue : 1;
        NSString *media = st.attrs[@"media"];
        if (st.attrs[@"initialization"]) init = [NSURL URLWithString:fill_template(st.attrs[@"initialization"], rid, bw, 0, 0) relativeToURL:base].absoluteString;
        if (!media) return nil;
        HNode *tl = [st kid:@"SegmentTimeline"];
        if (tl) {
            uint64_t t = 0, num = start;
            for (HNode *s in [tl all:@"S"]) {
                if (s.attrs[@"t"]) t = (uint64_t)s.attrs[@"t"].longLongValue;
                uint64_t d = (uint64_t)s.attrs[@"d"].longLongValue; long long r = s.attrs[@"r"] ? s.attrs[@"r"].longLongValue : 0;
                if (r < 0) r = 0;   /* "until the next S or the period end": one */
                for (long long i = 0; i <= r; i++) {
                    [urls addObject:[NSURL URLWithString:fill_template(media, rid, bw, num, t) relativeToURL:base].absoluteString];
                    [durs addObject:@((double)d / ts)];
                    t += d; num++;
                }
            }
        } else {
            double d = st.attrs[@"duration"].doubleValue / ts;
            if (d <= 0) return nil;
            uint64_t n0 = start, n1;
            if (dynamic) {
                double elapsed = now - ast - pstart;
                uint64_t last = start + (uint64_t)floor(elapsed / d) - 1;
                double keep = depth > 0 ? depth : 30;
                uint64_t count = (uint64_t)ceil(keep / d);
                n0 = last + 1 > start + count ? last + 1 - count : start;
                n1 = last;
            } else n1 = start + (uint64_t)ceil(total / d) - 1;
            for (uint64_t n = n0; n <= n1 && urls.count < 20000; n++) {
                [urls addObject:[NSURL URLWithString:fill_template(media, rid, bw, n, (uint64_t)((n - start) * d * ts)) relativeToURL:base].absoluteString];
                [durs addObject:@(d)];
            }
            first_number = n0;
        }
    } else if (sl) {
        double ts = sl.attrs[@"timescale"] ? sl.attrs[@"timescale"].doubleValue : 1, d = sl.attrs[@"duration"].doubleValue / ts;
        HNode *in = [sl kid:@"Initialization"];
        if (in.attrs[@"sourceURL"]) init = [NSURL URLWithString:in.attrs[@"sourceURL"] relativeToURL:base].absoluteString;
        for (HNode *s in [sl all:@"SegmentURL"]) {
            if (!s.attrs[@"media"]) return nil;
            [urls addObject:[NSURL URLWithString:s.attrs[@"media"] relativeToURL:base].absoluteString];
            [durs addObject:@(d > 0 ? d : 2)];
        }
    } else return nil;           /* SegmentBase: one file indexed by its sidx -- not described here */
    if (!urls.count) return nil;
    (void)list;
    /* a live timeline keeps only its last half minute or so, as a live HLS playlist does */
    NSUInteger from = 0;
    if (dynamic && urls.count > 15) from = urls.count - 15;
    double target = 1;
    for (NSUInteger i = from; i < durs.count; i++) if ([durs[i] doubleValue] > target) target = [durs[i] doubleValue];
    NSMutableString *m = [NSMutableString stringWithFormat:@"#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:%d\n#EXT-X-MEDIA-SEQUENCE:%llu\n",
                          (int)ceil(target), (unsigned long long)(first_number + from)];
    if (!dynamic) [m appendString:@"#EXT-X-PLAYLIST-TYPE:VOD\n"];
    if (init) [m appendFormat:@"#EXT-X-MAP:URI=\"%@\"\n", enc ? [self name:init list:w init:true] : init];
    for (NSUInteger i = from; i < urls.count; i++) [m appendFormat:@"#EXTINF:%.3f,\n%@\n", [durs[i] doubleValue], enc ? [self name:urls[i] list:w init:false] : urls[i]];
    if (!dynamic) [m appendString:@"#EXT-X-ENDLIST\n"];
    return m;
}

- (BOOL)load
{
    NSURL *doc = nil;
    NSData *d = fetch(mpd_url, hdr, &doc);
    if (!d) { why = @"the MPD did not load"; return NO; }
    HXml *x = [HXml new];
    NSXMLParser *p = [[NSXMLParser alloc] initWithData:d]; p.delegate = x;
    if (![p parse] || !x->root) { why = @"the MPD is not XML"; return NO; }
    HNode *mpd = x->root;
    dynamic = [mpd.attrs[@"type"] isEqualToString:@"dynamic"];
    double ast = iso_date(mpd.attrs[@"availabilityStartTime"]), total = iso_duration(mpd.attrs[@"mediaPresentationDuration"]);
    double depth = iso_duration(mpd.attrs[@"timeShiftBufferDepth"]);
    refresh = iso_duration(mpd.attrs[@"minimumUpdatePeriod"]); if (refresh <= 0) refresh = 4;
    HNode *period = [mpd all:@"Period"].lastObject;     /* a live MPD's current period is its last */
    if (!period) { why = @"no Period"; return NO; }
    double pstart = iso_duration(period.attrs[@"start"]);
    HNode *bestv = nil, *besta = nil; double bvb = -1, bab = -1;
    bool protected_ = false;
    for (HNode *as in [period all:@"AdaptationSet"]) {
        if ([as kid:@"ContentProtection"]) protected_ = true;
        for (HNode *rep in [as all:@"Representation"]) {
            if ([rep kid:@"ContentProtection"]) protected_ = true;
            NSString *mime = attr_up(rep, @"mimeType"), *ct = attr_up(rep, @"contentType");
            bool video = [mime hasPrefix:@"video"] || [ct isEqualToString:@"video"], audio = [mime hasPrefix:@"audio"] || [ct isEqualToString:@"audio"];
            double b = rep.attrs[@"bandwidth"].doubleValue;
            /* the best picture that is not past 1080p, the best sound */
            if (video && rep.attrs[@"height"].intValue <= 1080 && b > bvb) { bvb = b; bestv = rep; }
            if (audio && b > bab) { bab = b; besta = rep; }
        }
    }
    if (!bestv && !besta) { why = @"no audio or video representation"; return NO; }
    if (protected_ && !have_clearkey()) { why = @"encrypted (DRM), and the app gave no ClearKey keys"; return NO; }
    enc = protected_;
    pthread_mutex_lock(&mu);
    nu2k = [NSMutableDictionary dictionary]; nk2u = [NSMutableDictionary dictionary];
    pthread_mutex_unlock(&mu);
    double now = [NSDate date].timeIntervalSince1970;
    NSString *v = bestv ? [self mediaList:bestv doc:doc now:now ast:ast period:pstart total:total depth:depth list:0] : nil;
    NSString *a = besta ? [self mediaList:besta doc:doc now:now ast:ast period:pstart total:total depth:depth list:1] : nil;
    if ((bestv && !v) || (!bestv && !a)) { why = @"segments described in a way not supported (SegmentBase)"; return NO; }
    NSMutableString *m = [NSMutableString stringWithString:@"#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"];
    NSMutableArray *codecs = [NSMutableArray array];
    if (bestv && attr_up(bestv, @"codecs")) [codecs addObject:attr_up(bestv, @"codecs")];
    if (a && attr_up(besta, @"codecs")) [codecs addObject:attr_up(besta, @"codecs")];
    if (v && a) [m appendString:@"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"a.m3u8\"\n"];
    [m appendFormat:@"#EXT-X-STREAM-INF:BANDWIDTH=%.0f", (bvb > 0 ? bvb : 0) + (bab > 0 ? bab : 0)];
    if (codecs.count) [m appendFormat:@",CODECS=\"%@\"", [codecs componentsJoinedByString:@","]];
    if (bestv && bestv.attrs[@"width"]) [m appendFormat:@",RESOLUTION=%@x%@", bestv.attrs[@"width"], bestv.attrs[@"height"]];
    if (v && a) [m appendString:@",AUDIO=\"aud\""];
    [m appendFormat:@"\n%@\n", v ? @"v.m3u8" : @"a.m3u8"];
    pthread_mutex_lock(&mu);
    master = m; vlist = v; alist = a; fetched = now; ok = YES;
    u2k = nu2k; k2u = nk2u;
    pthread_mutex_unlock(&mu);
    return YES;
}

/* what the track of list w (0 v, 1 a) is encrypted with, from its init segment (made plain in d, when given) */
- (tcrypt)crypt:(int)w init:(NSMutableData *)d
{
    pthread_mutex_lock(&mu);
    tcrypt t = tc[w]; bool known = tc_known[w]; NSString *iu = init_url[w];
    pthread_mutex_unlock(&mu);
    if (known && !d) return t;
    if (!d && iu) { NSData *raw = fetch([NSURL URLWithString:iu], hdr, NULL); d = raw ? [raw mutableCopy] : nil; }
    if (!d) return t;
    memset(&t, 0, sizeof(t));
    init_clear(d.mutableBytes, d.length, &t);
    pthread_mutex_lock(&mu);
    tc[w] = t; tc_known[w] = true;
    bool say = !told; told = true;
    pthread_mutex_unlock(&mu);
    if (say) {
        char kid[33]; for (int i = 0; i < 16; i++) snprintf(kid + 2 * i, 3, "%02x", t.kid[i]);
        uint32_t sc = t.scheme;
        tl_log_line("avstream: encrypted with '%c%c%c%c', KID %s%s", (char)(sc >> 24), (char)(sc >> 16), (char)(sc >> 8), (char)sc, kid, t.on ? "" : " (track not encrypted)");
    }
    return t;
}

/* an encrypted stream's init or media segment, decrypted */
- (NSData *)segment:(NSString *)name
{
    pthread_mutex_lock(&mu);
    NSString *u = k2u[name];
    pthread_mutex_unlock(&mu);
    if (!u) return nil;
    int w = [name hasPrefix:@"a"] ? 1 : 0;
    NSData *raw = fetch([NSURL URLWithString:u], hdr, NULL);
    if (!raw) return nil;
    NSMutableData *d = [raw mutableCopy];
    if ([name hasSuffix:@".mp4"]) { [self crypt:w init:d]; return d; }
    tcrypt t = [self crypt:w init:nil];
    if (!t.on) return d;
    if (t.scheme != FOURCC("cenc") && t.scheme != FOURCC("cbcs")) {
        tl_log_line("avstream: encryption scheme '%c%c%c%c' is not decrypted here", (char)(t.scheme >> 24), (char)(t.scheme >> 16), (char)(t.scheme >> 8), (char)t.scheme);
        return nil;
    }
    NSData *key = key_for(t.kid);
    if (!key) { tl_log_line("avstream: no ClearKey key for this stream's KID"); return nil; }
    if (!segment_clear(d.mutableBytes, d.length, &t, key.bytes)) tl_log_line("avstream: %s: no encrypted samples found", name.UTF8String);
    return d;
}

- (NSString *)list:(NSString *)which
{
    @synchronized (self) {
        if (dynamic && [NSDate date].timeIntervalSince1970 - fetched >= refresh) [self load];
    }
    pthread_mutex_lock(&mu);
    NSString *r = [which isEqualToString:@"master"] ? master : [which isEqualToString:@"v"] ? vlist : alist;
    pthread_mutex_unlock(&mu);
    return r;
}
@end

/* ======================================================================== the streams being served */

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary<NSNumber *, id> *g_streams;
static atomic_int g_next_id = 1;

static int add_stream(id s)
{
    int sid = atomic_fetch_add(&g_next_id, 1);
    pthread_mutex_lock(&g_lock);
    if (!g_streams) g_streams = [NSMutableDictionary dictionary];
    g_streams[@(sid)] = s;
    pthread_mutex_unlock(&g_lock);
    return sid;
}

static id stream(int sid)
{
    pthread_mutex_lock(&g_lock);
    id s = g_streams[@(sid)];
    pthread_mutex_unlock(&g_lock);
    return s;
}

void tl_av_stop(int sid);
void tl_av_stop(int sid)
{
    if (sid <= 0) return;
    pthread_mutex_lock(&g_lock);
    id s = g_streams[@(sid)];
    [g_streams removeObjectForKey:@(sid)];
    pthread_mutex_unlock(&g_lock);
    if ([s isKindOfClass:[HTsRelay class]]) [(HTsRelay *)s stop];
    if ([s isKindOfClass:[HFile class]]) [(HFile *)s stop];
}

static reply handle_path(NSString *path, int64_t range_lo, int64_t range_hi)
{
    reply r = { nil, nil, 404, nil, nil, 0 };
    NSArray *parts = [path componentsSeparatedByString:@"/"];        /* "", "s", id, file */
    if (parts.count != 4 || ![parts[1] isEqualToString:@"s"]) return r;
    id s = stream([parts[2] intValue]);
    NSString *file = parts[3];
    if ([s isKindOfClass:[HTsRelay class]]) {
        HTsRelay *t = s;
        if ([file isEqualToString:@"live.m3u8"]) { r.body = [t playlist]; r.type = @"application/vnd.apple.mpegurl"; }
        else if ([file hasSuffix:@".ts"]) { r.body = [t segment:(uint64_t)[file longLongValue]]; r.type = @"video/mp2t"; }
    } else if ([s isKindOfClass:[HFile class]]) {
        return [(HFile *)s serve:range_lo to:range_hi];
    } else if ([s isKindOfClass:[HDash class]]) {
        NSString *which = [file isEqualToString:@"master.m3u8"] ? @"master" : [file isEqualToString:@"v.m3u8"] ? @"v" : [file isEqualToString:@"a.m3u8"] ? @"a" : nil;
        NSString *l = which ? [(HDash *)s list:which] : nil;
        if (l) { r.body = [l dataUsingEncoding:NSUTF8StringEncoding]; r.type = @"application/vnd.apple.mpegurl"; }
        else if (!which) { r.body = [(HDash *)s segment:file]; r.type = @"video/mp4"; }
    }
    if (r.body) r.status = 200;
    return r;
}

/* ======================================================================== what AVPlayer is given */

/* The first bytes of the stream, to tell TS, HLS, DASH and the rest apart when the URL does not say. */
static NSData *sniff(NSURL *u, NSDictionary *hdr)
{
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:u cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    for (NSString *k in hdr) [rq setValue:hdr[k] forHTTPHeaderField:k];
    __block NSMutableData *got = [NSMutableData data];
    __block NSURLSessionDataTask *task = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSession *s = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    task = [s dataTaskWithRequest:rq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) { if (d) [got appendData:d]; dispatch_semaphore_signal(sem); }];
    /* a live TS stream never ends: stop after the first bytes */
    [task resume];
    for (int i = 0; i < 150 && task.countOfBytesReceived < 2048; i++) {
        if (!dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC))) { [s finishTasksAndInvalidate]; return got; }
    }
    [task cancel];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    [s invalidateAndCancel];
    return got;
}

/* What AVPlayer should open for src: src itself, or a playlist on the local server (*stream_id set). nil, with *why, when nothing
   here makes it playable (the app's own player is the answer). Blocks: called off the app's thread. */
NSURL *tl_av_resolve(NSURL *src, NSDictionary *hdr, int *stream_id, NSString **why);
NSURL *tl_av_resolve(NSURL *src, NSDictionary *hdr, int *stream_id, NSString **why)
{
    *stream_id = 0;
    NSString *scheme = src.scheme.lowercaseString;
    if ([scheme isEqualToString:@"rtmp"] || [scheme isEqualToString:@"rtmps"] || [scheme isEqualToString:@"rtsp"] || [scheme isEqualToString:@"udp"]
        || [scheme isEqualToString:@"rtp"] || [scheme isEqualToString:@"srt"]) { *why = [NSString stringWithFormat:@"%@ is not a protocol AVPlayer speaks", scheme]; return nil; }
    if (![scheme hasPrefix:@"http"]) return src;
    NSString *ext = src.path.pathExtension.lowercaseString;
    static NSSet *direct; static dispatch_once_t once;
    dispatch_once(&once, ^{ direct = [NSSet setWithArray:@[ @"m3u8", @"m3u", @"mp4", @"m4v", @"mov", @"mp3", @"m4a", @"aac", @"wav", @"caf", @"3gp" ]]; });
    if ([direct containsObject:ext]) return src;
    int kind = 0;                                     /* 1 TS, 2 DASH */
    if ([ext isEqualToString:@"mpd"]) kind = 2;
    else {
        NSData *d = sniff(src, hdr);
        const uint8_t *b = d.bytes; NSUInteger n = d.length;
        if (n >= TS + 1 && b[0] == 0x47 && b[TS] == 0x47) kind = 1;
        else if (n >= 7 && !memcmp(b, "#EXTM3U", 7)) return src;
        else if (n && [[[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(0, MIN(n, 512))] encoding:NSUTF8StringEncoding] containsString:@"<MPD"]) kind = 2;
        else if ([ext isEqualToString:@"ts"] && n == 0) kind = 1;
        else return src;
    }
    pthread_once(&g_server_once, server_start);
    if (!g_port) { *why = @"no local server"; return nil; }
    if (kind == 1) {
        HTsRelay *t = [[HTsRelay alloc] initWithURL:src headers:hdr];
        *stream_id = add_stream(t);
        tl_log_line("avstream: MPEG-TS stream, played as HLS (stream %d)", *stream_id);
        return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/s/%d/live.m3u8", g_port, *stream_id]];
    }
    HDash *dsh = [HDash new];
    dsh->mpd_url = src; dsh->hdr = hdr; pthread_mutex_init(&dsh->mu, NULL);
    if (![dsh load]) { *why = [NSString stringWithFormat:@"DASH: %@", dsh->why]; return nil; }
    *stream_id = add_stream(dsh);
    tl_log_line("avstream: DASH%s%s, played as HLS (stream %d)", dsh->dynamic ? " (live)" : "", dsh->enc ? ", ClearKey-decrypted" : "", *stream_id);
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/s/%d/master.m3u8", g_port, *stream_id]];
}

/* A file AVPlayer could not read from its server, read by the local server instead (HFile). Does not block. */
NSURL *tl_av_progressive(NSURL *src, NSDictionary *hdr, int *stream_id);
NSURL *tl_av_progressive(NSURL *src, NSDictionary *hdr, int *stream_id)
{
    pthread_once(&g_server_once, server_start);
    if (!g_port) return nil;
    HFile *f = [[HFile alloc] initWithURL:src headers:hdr];
    *stream_id = add_stream(f);
    NSString *ext = src.path.pathExtension.length ? src.path.pathExtension : @"mp4";
    tl_log_line("avstream: the file is read through the local server (stream %d)", *stream_id);
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/s/%d/media.%@", g_port, *stream_id, ext]];
}
