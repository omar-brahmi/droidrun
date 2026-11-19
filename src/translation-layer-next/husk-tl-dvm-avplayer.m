/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * husk.AvPlayer's natives: an app's ExoPlayer played by AVPlayer (see AvPlayer.java). AVPlayer downloads, demuxes and decodes
 * natively (HLS, MP4, the formats iOS plays), and an AVPlayerItemVideoOutput hands its frames out as 32BGRA pixel buffers, which
 * nCopyFrame converts into the Bitmap the Java side draws into the app's Surface, as MediaCodec's frames are. Audio plays through
 * AVPlayer itself. Written to build with and without ARC: objects are kept with CFBridgingRetain and let go with CFRelease.
 */
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "husk-tl-dvm-internal.h"

/* AVFoundation is linked from here, so neither the app's project nor the harnesses' build has to name it */
__asm__(".linker_option \"-framework\", \"AVFoundation\"");

void tl_log_line(const char *fmt, ...);
typedef struct { uint32_t width, height, stride; int32_t format; uint32_t flags; } tl_abitmap_info;
int tl_AndroidBitmap_getInfo(void *env, void *bitmap, tl_abitmap_info *info);
int tl_AndroidBitmap_lockPixels(void *env, void *bitmap, void **addr);

#define NAT(fn) static bool fn(jobj *self, const jvalue *a, jvalue *ret)
static jvalue I(int32_t v) { jvalue r; r.j = (uint32_t)v; return r; }
static jvalue J(int64_t v) { jvalue r; r.j = v; return r; }
static jvalue Z(bool v) { jvalue r; r.j = v; return r; }
static jvalue L(void *p) { jvalue r; r.j = 0; r.l = p; return r; }

typedef struct {
    pthread_mutex_t lock;
    void *player;               /* AVPlayer, retained */
    void *item;                 /* AVPlayerItem, retained */
    void *output;               /* AVPlayerItemVideoOutput, retained */
    int width, height;
    int stream;                 /* a stream the local server converts for AVPlayer (husk-tl-dvm-avstream.m), or 0 */
    int generation;             /* nSetSource calls so far: a late resolution of an older source is dropped */
    bool pending;               /* the source is still being looked at */
    bool proxied;               /* already retried through the local server */
    bool playing;               /* the app asked to play (nPlay), not to pause */
    void *src, *hdr;            /* NSURL, NSDictionary of what AVPlayer was given directly (retained), for that retry */
    char error[300];
    void *view;                 /* HuskVideoView (retained; main thread): the picture shown by iOS itself, see nLayer */
    bool shown;                 /* view on screen (main thread) */
} avp;

NSURL *tl_av_resolve(NSURL *src, NSDictionary *hdr, int *stream_id, NSString **why);
void tl_av_stop(int id);
NSURL *tl_av_progressive(NSURL *src, NSDictionary *hdr, int *stream_id);

static AVPlayerItemVideoOutput *new_output(void)
{
    return [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) }];
}

#define P ((avp *)(uintptr_t)a[0].j)
static bool wants_play(avp *p) { return p->playing; }
#define PLAYER(p) ((__bridge AVPlayer *)(p)->player)
#define ITEM(p) ((__bridge AVPlayerItem *)(p)->item)
#define OUTPUT(p) ((__bridge AVPlayerItemVideoOutput *)(p)->output)

static NSString *ns(jobj *s) { const char *c = tl_jni_string(s); return c ? [NSString stringWithUTF8String:c] : nil; }

static void drop_item(avp *p)
{
    if (p->item) {
        if (p->output) [ITEM(p) removeOutput:OUTPUT(p)];
        CFRelease(p->item); p->item = NULL;
    }
    if (p->output) { CFRelease(p->output); p->output = NULL; }
    p->width = p->height = 0;
    if (p->stream) { tl_av_stop(p->stream); p->stream = 0; }
    if (p->src) { CFRelease(p->src); p->src = NULL; }
    if (p->hdr) { CFRelease(p->hdr); p->hdr = NULL; }
    p->proxied = false;
}

NAT(A_create)
{
    (void)self; (void)a;
    avp *p = calloc(1, sizeof(*p));
    pthread_mutex_init(&p->lock, NULL);
    @autoreleasepool {
        AVPlayer *pl = [[AVPlayer alloc] init];
        pl.automaticallyWaitsToMinimizeStalling = YES;
        p->player = (void *)CFBridgingRetain(pl);
#if !__has_feature(objc_arc)
        [pl release];
#endif
    }
    /* sound goes through the audio session Husk already set up for apps (HuskAudio) */
    *ret = J((int64_t)(uintptr_t)p);
    return true;
}

/* nSetSource(h, url, headers): name, value, name, value... The stream is looked at off the app's thread (tl_av_resolve: as it is,
   or converted to HLS by the local server, or not playable here), then given to AVPlayer. */
NAT(A_setSource)
{
    (void)self; (void)ret;
    avp *p = P;
    if (!p) return true;
    @autoreleasepool {
        NSString *s = ns(a[1].l);
        NSURL *url = s ? [NSURL URLWithString:s] : nil;
        if (!url && s) url = [NSURL fileURLWithPath:s];
        if (url && !url.scheme) url = [NSURL fileURLWithPath:s];
        NSMutableDictionary *hdr = [NSMutableDictionary dictionary];
        jobj *arr = a[2].l;
        if (arr && arr->kind == TL_K_OBJ_ARRAY)
            for (uint32_t i = 0; i + 1 < arr->oarr.len; i += 2) {
                NSString *k = ns(arr->oarr.v[i]), *v = ns(arr->oarr.v[i + 1]);
                if (k && v) hdr[k] = v;
            }
        pthread_mutex_lock(&p->lock);
        [PLAYER(p) replaceCurrentItemWithPlayerItem:nil];
        drop_item(p);
        p->error[0] = 0;
        int gen = ++p->generation;
        p->pending = url != nil;
        if (!url) snprintf(p->error, sizeof(p->error), "not a URL: %s", s ? s.UTF8String : "(none)");
        pthread_mutex_unlock(&p->lock);
        if (!url) return true;
        tl_log_line("avplayer: %s%s", s.UTF8String, hdr.count ? " (with the app's request headers)" : "");
        NSDictionary *headers = [hdr copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                int sid = 0; NSString *why = nil;
                NSURL *use = tl_av_resolve(url, headers, &sid, &why);
                NSMutableDictionary *opts = [NSMutableDictionary dictionary];
                if (headers.count) opts[@"AVURLAssetHTTPHeaderFieldsKey"] = headers;
                /* AVPlayer sends its own User-Agent whatever the header dictionary says; servers that check it need the app's */
                NSString *ua = headers[@"User-Agent"];
                if (ua) { if (@available(iOS 16.0, macOS 13.0, *)) opts[AVURLAssetHTTPUserAgentKey] = ua; }
                AVPlayerItem *item = use ? [AVPlayerItem playerItemWithAsset:[AVURLAsset URLAssetWithURL:use options:opts]] : nil;
                AVPlayerItemVideoOutput *out = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) }];
                if (item) [item addOutput:out];
                pthread_mutex_lock(&p->lock);
                if (gen != p->generation || !p->player) { pthread_mutex_unlock(&p->lock); tl_av_stop(sid); return; }
                p->pending = false;
                if (item) {
                    p->item = (void *)CFBridgingRetain(item); p->output = (void *)CFBridgingRetain(out); p->stream = sid;
                    if (!sid && [use.scheme hasPrefix:@"http"] && ![use.path.pathExtension.lowercaseString hasPrefix:@"m3u"]) {
                        p->src = (void *)CFBridgingRetain(use); p->hdr = (void *)CFBridgingRetain(headers);
                    }
                    [PLAYER(p) replaceCurrentItemWithPlayerItem:item];
                } else {
                    snprintf(p->error, sizeof(p->error), "%s", why ? why.UTF8String : "not playable by AVPlayer");
                    tl_log_line("avplayer: not playable here: %s", p->error);
                }
                pthread_mutex_unlock(&p->lock);
            }
        });
    }
    return true;
}

NAT(A_play) { (void)self; (void)ret; avp *p = P; if (p) { p->playing = true; [PLAYER(p) play]; } return true; }
NAT(A_pause) { (void)self; (void)ret; avp *p = P; if (p) { p->playing = false; [PLAYER(p) pause]; } return true; }
NAT(A_volume) { (void)self; (void)ret; avp *p = P; if (p) PLAYER(p).volume = a[1].f; return true; }

NAT(A_seek)
{
    (void)self; (void)ret;
    avp *p = P;
    if (p) [PLAYER(p) seekToTime:CMTimeMakeWithSeconds((double)a[1].j / 1000.0, 600)];
    return true;
}

/* the live edge: the end of the seekable range */
NAT(A_seekLive)
{
    (void)self; (void)ret;
    avp *p = P;
    if (!p) return true;
    pthread_mutex_lock(&p->lock);
    AVPlayerItem *it = ITEM(p);
    NSValue *v = it ? it.seekableTimeRanges.lastObject : nil;
    if (v) [PLAYER(p) seekToTime:CMTimeRangeGetEnd(v.CMTimeRangeValue)];
    pthread_mutex_unlock(&p->lock);
    return true;
}

static int64_t ms(CMTime t) { return CMTIME_IS_NUMERIC(t) ? (int64_t)(CMTimeGetSeconds(t) * 1000.0) : -1; }

NAT(A_position) { (void)self; avp *p = P; *ret = J(p ? ms(PLAYER(p).currentTime) : 0); return true; }

NAT(A_duration)
{
    (void)self;
    avp *p = P;
    int64_t d = -1;
    if (p) { pthread_mutex_lock(&p->lock); if (p->item) d = ms(ITEM(p).duration); pthread_mutex_unlock(&p->lock); }
    *ret = J(d);
    return true;
}

NAT(A_buffered)
{
    (void)self;
    avp *p = P;
    int64_t b = 0;
    if (p) {
        pthread_mutex_lock(&p->lock);
        NSValue *v = p->item ? ITEM(p).loadedTimeRanges.lastObject : nil;
        if (v) b = ms(CMTimeRangeGetEnd(v.CMTimeRangeValue));
        pthread_mutex_unlock(&p->lock);
    }
    *ret = J(b < 0 ? 0 : b);
    return true;
}

/* 1 idle, 2 buffering, 3 ready, 4 ended, -1 failed */
NAT(A_state)
{
    (void)self;
    avp *p = P;
    int s = 1;
    if (p) {
        pthread_mutex_lock(&p->lock);
        AVPlayer *pl = PLAYER(p);
        AVPlayerItem *it = p->item ? ITEM(p) : nil;
        if (p->error[0]) s = -1;
        else if (p->pending) s = 2;
        else if (!it) s = 1;
        else if ((it.status == AVPlayerItemStatusFailed || pl.status == AVPlayerStatusFailed) && p->src && !p->proxied) {
            /* a file AVPlayer could not read from its server (no byte ranges, its requests turned away): once more, through the
               local server, which reads it with the app's headers */
            NSError *e = it.error ? it.error : pl.error;
            tl_log_line("avplayer: %s; trying again through the local server", e ? e.localizedDescription.UTF8String : "failed");
            int sid = 0;
            NSURL *via = tl_av_progressive((__bridge NSURL *)p->src, (__bridge NSDictionary *)p->hdr, &sid);
            if (via) {
                if (p->output) [it removeOutput:OUTPUT(p)];
                CFRelease(p->item); p->item = NULL;
                if (p->output) { CFRelease(p->output); p->output = NULL; }
                AVPlayerItem *ni = [AVPlayerItem playerItemWithURL:via];
                AVPlayerItemVideoOutput *out = new_output();
                [ni addOutput:out];
                p->item = (void *)CFBridgingRetain(ni); p->output = (void *)CFBridgingRetain(out); p->stream = sid;
                /* a failed AVPlayer stays failed: a new one, as the old one was set up */
                float vol = pl.volume; float rate = pl.rate;
                [pl replaceCurrentItemWithPlayerItem:nil];
                AVPlayer *np = [[AVPlayer alloc] initWithPlayerItem:ni];
                np.automaticallyWaitsToMinimizeStalling = YES; np.volume = vol;
                CFRelease(p->player); p->player = (void *)CFBridgingRetain(np);
                if (rate > 0 || wants_play(p)) [np play];
                pl = np;
            }
            p->proxied = true;
            s = 2;
        }
        else if (it.status == AVPlayerItemStatusFailed || pl.status == AVPlayerStatusFailed) {
            NSError *e = it.error ? it.error : pl.error;
            snprintf(p->error, sizeof(p->error), "%s", e ? e.localizedDescription.UTF8String : "AVPlayer failed");
            tl_log_line("avplayer: failed: %s (%s)", p->error, e ? e.description.UTF8String : "");
            s = -1;
        } else if (it.status != AVPlayerItemStatusReadyToPlay) s = 2;
        else if (pl.timeControlStatus == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate) s = 2;
        else {
            CMTime d = it.duration;
            s = CMTIME_IS_NUMERIC(d) && CMTimeGetSeconds(d) > 0 && CMTimeGetSeconds(pl.currentTime) >= CMTimeGetSeconds(d) - 0.25 ? 4 : 3;
        }
        pthread_mutex_unlock(&p->lock);
    }
    *ret = I(s);
    return true;
}

NAT(A_playing) { (void)self; avp *p = P; *ret = Z(p && PLAYER(p).timeControlStatus == AVPlayerTimeControlStatusPlaying); return true; }

NAT(A_videoSize)
{
    (void)self;
    avp *p = P;
    int w = 0, h = 0;
    if (p) {
        pthread_mutex_lock(&p->lock);
        if (p->width > 0) { w = p->width; h = p->height; }
        else if (p->item) { CGSize s = ITEM(p).presentationSize; w = (int)s.width; h = (int)s.height; }
        pthread_mutex_unlock(&p->lock);
    }
    if (w > 0xffff) w = 0xffff;
    if (h > 0xffff) h = 0xffff;
    *ret = I(w << 16 | (h & 0xffff));
    return true;
}

/* nCopyFrame(h, bitmap): the frame due now, if it is new, into the Bitmap (RGBA, its own size) */
NAT(A_copyFrame)
{
    (void)self;
    avp *p = P;
    *ret = Z(false);
    if (!p || !a[1].l) return true;
    pthread_mutex_lock(&p->lock);
    AVPlayerItemVideoOutput *out = p->output ? OUTPUT(p) : nil;
    CVPixelBufferRef pb = NULL;
    if (out) {
        CMTime t = [out itemTimeForHostTime:CACurrentMediaTime()];
        if ([out hasNewPixelBufferForItemTime:t]) pb = [out copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
    }
    if (pb) { p->width = (int)CVPixelBufferGetWidth(pb); p->height = (int)CVPixelBufferGetHeight(pb); }
    pthread_mutex_unlock(&p->lock);
    if (!pb) return true;
    tl_abitmap_info bi; void *px = NULL;
    if (tl_AndroidBitmap_getInfo(NULL, a[1].l, &bi) || tl_AndroidBitmap_lockPixels(NULL, a[1].l, &px) || !px) { CVPixelBufferRelease(pb); return true; }
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    uint8_t *base = CVPixelBufferGetBaseAddress(pb);
    size_t w = bi.width, h = bi.height;
    if (w > CVPixelBufferGetWidth(pb)) w = CVPixelBufferGetWidth(pb);
    if (h > CVPixelBufferGetHeight(pb)) h = CVPixelBufferGetHeight(pb);
    bool ok = false;
    if (base) {
        vImage_Buffer s = { base, h, w, CVPixelBufferGetBytesPerRow(pb) }, d = { px, h, w, bi.stride };
        const uint8_t map[4] = { 2, 1, 0, 3 };                     /* BGRA -> RGBA */
        ok = vImagePermuteChannels_ARGB8888(&s, &d, map, kvImageNoFlags) == kvImageNoError;
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(pb);
    *ret = Z(ok);
    return true;
}

/* ---- the picture shown by iOS itself: an AVPlayerLayer in a view under the app's screen (the web views' container,
 * husk-tl-dvm-web.m), at the place of the app's SurfaceView, which leaves a see-through hole there. The frames go from the decoder
 * to the screen on the GPU: no copy, where nCopyFrame copies each one into a Bitmap the app's views draw. */
void *tl_web_container(void);
float tl_web_scale(void);
void tl_web_video_shown(int delta);

#if TARGET_OS_IPHONE
@interface HuskVideoView : UIView
@end
@implementation HuskVideoView
+ (Class)layerClass { return AVPlayerLayer.class; }
@end
#define VLAYER(v) ((AVPlayerLayer *)(v).layer)
#else
@interface HuskVideoView : NSView
@end
@implementation HuskVideoView
- (instancetype)initWithFrame:(NSRect)f { if ((self = [super initWithFrame:f])) { self.wantsLayer = YES; self.layer = [AVPlayerLayer layer]; } return self; }
- (BOOL)isFlipped { return YES; }
@end
#define VLAYER(v) ((AVPlayerLayer *)(v).layer)
#endif
#define VIEW(p) ((__bridge HuskVideoView *)(p)->view)

/* nLayerSupported(): whether videos show through layers. On the iPhone yes (TL_VIDEO_LAYER=0: no); on a Mac harness only with
 * TL_VIDEO_LAYER=1, since its screenshots are the app's GL frames, which the layer is not in. */
NAT(A_layerSupported)
{
    (void)self; (void)a;
    const char *e = getenv("TL_VIDEO_LAYER");
#if TARGET_OS_IPHONE
    bool on = !e || strcmp(e, "0");
#else
    bool on = e && !strcmp(e, "1");
#endif
    *ret = Z(on);
    return true;
}

/* nLayer(h, x, y, w, h, visible, fill): the player's picture at that place of the screen (pixels), fitted or filling */
NAT(A_layer)
{
    (void)self; (void)ret;
    avp *p = P;
    if (!p) return true;
    int x = a[1].i, y = a[2].i, w = a[3].i, h = a[4].i;
    bool visible = a[5].z && w > 0 && h > 0, fill = a[6].z;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!p->player) return;                                        /* released meanwhile */
        HuskVideoView *v = p->view ? VIEW(p) : nil;
        if (!v && visible) {
#if TARGET_OS_IPHONE
            UIView *box = (__bridge UIView *)tl_web_container();
#else
            NSView *box = (__bridge NSView *)tl_web_container();
#endif
            if (!box) return;
            v = [[HuskVideoView alloc] initWithFrame:CGRectZero];
#if TARGET_OS_IPHONE
            v.userInteractionEnabled = NO;                             /* the app's own controls above it take the touches */
            v.backgroundColor = UIColor.blackColor;
#endif
            VLAYER(v).player = PLAYER(p);
            [box addSubview:v];
            p->view = (void *)CFBridgingRetain(v);
#if !__has_feature(objc_arc)
            [v release];
#endif
        }
        if (!v) return;
        float s = tl_web_scale();
        v.frame = CGRectMake(x / s, y / s, w / s, h / s);
        VLAYER(v).videoGravity = fill ? AVLayerVideoGravityResizeAspectFill : AVLayerVideoGravityResizeAspect;
        v.hidden = !visible;
        if (visible != p->shown) { p->shown = visible; tl_web_video_shown(visible ? 1 : -1); }
    });
    return true;
}

/* the view goes with the player (on the main thread, where the view is only ever touched) */
static void drop_view(avp *p)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        void *view = p->view;
        p->view = NULL;
        if (!view) return;
        HuskVideoView *v = (__bridge HuskVideoView *)view;
        VLAYER(v).player = nil;
        [v removeFromSuperview];
        if (p->shown) { p->shown = false; tl_web_video_shown(-1); }
        CFRelease(view);
    });
}

NAT(A_error)
{
    (void)self;
    avp *p = P;
    *ret = L(dvm_new_string_utf8(p && p->error[0] ? p->error : "AVPlayer failed"));
    return true;
}

NAT(A_release)
{
    (void)self; (void)ret;
    avp *p = P;
    if (!p) return true;
    [PLAYER(p) pause];
    drop_view(p);
    pthread_mutex_lock(&p->lock);
    [PLAYER(p) replaceCurrentItemWithPlayerItem:nil];
    drop_item(p);
    CFRelease(p->player); p->player = NULL;
    p->generation++;
    pthread_mutex_unlock(&p->lock);
    /* a resolution still running holds p: it sees player NULL and leaves; p itself is kept (a few bytes) rather than freed under it */
    return true;
}

void tl_av_clearkey(NSString *keys, NSString *license, NSDictionary *hdr);

/* nClearKey(keys, licenseUrl, licenseHeaders): ClearKey keys (a JSON Web Key set) or a license server, for encrypted DASH */
NAT(A_clearKey)
{
    (void)self; (void)ret;
    @autoreleasepool {
        NSMutableDictionary *hdr = [NSMutableDictionary dictionary];
        jobj *arr = a[2].l;
        if (arr && arr->kind == TL_K_OBJ_ARRAY)
            for (uint32_t i = 0; i + 1 < arr->oarr.len; i += 2) {
                NSString *k = ns(arr->oarr.v[i]), *v = ns(arr->oarr.v[i + 1]);
                if (k && v) hdr[k] = v;
            }
        tl_av_clearkey(a[0].l ? ns(a[0].l) : nil, a[1].l ? ns(a[1].l) : nil, hdr);
    }
    return true;
}

NAT(A_buildExo);
static const struct { const char *name, *sig; dvm_native_fn fn; } k_avp[] = {
    { "nCreate", "()J", A_create },
    { "nSetSource", "(JLjava/lang/String;[Ljava/lang/String;)V", A_setSource },
    { "nPlay", "(J)V", A_play },
    { "nPause", "(J)V", A_pause },
    { "nSeek", "(JJ)V", A_seek },
    { "nSeekLive", "(J)V", A_seekLive },
    { "nPosition", "(J)J", A_position },
    { "nDuration", "(J)J", A_duration },
    { "nBuffered", "(J)J", A_buffered },
    { "nState", "(J)I", A_state },
    { "nPlaying", "(J)Z", A_playing },
    { "nVideoSize", "(J)I", A_videoSize },
    { "nCopyFrame", "(JLandroid/graphics/Bitmap;)Z", A_copyFrame },
    { "nError", "(J)Ljava/lang/String;", A_error },
    { "nVolume", "(JF)V", A_volume },
    { "nRelease", "(J)V", A_release },
    { "nBuildExo", "(Ljava/lang/Object;)Ljava/lang/Object;", A_buildExo },
    { "nClearKey", "(Ljava/lang/String;Ljava/lang/String;[Ljava/lang/String;)V", A_clearKey },
    { "nLayer", "(JIIIIZZ)V", A_layer },
    { "nLayerSupported", "()Z", A_layerSupported },
    { NULL, NULL, NULL },
};

dvm_native_fn tl_avplayer_native(const char *name, const char *sig);
dvm_native_fn tl_avplayer_native(const char *name, const char *sig)
{
    for (int i = 0; k_avp[i].name; i++) if (!strcmp(k_avp[i].name, name) && !strcmp(k_avp[i].sig, sig)) return k_avp[i].fn;
    return NULL;
}

/* ExoPlayer.Builder.build()'s own bytecode, with the hook below taken off for the call */
static bool exo_build_original(jobj *self, jvalue *ret)
{
    dvm_class *c = dvm_class_of(dvm_object_class(self));
    for (dvm_class *k = c; k; k = k->super) {
        for (int i = 0; i < k->nvm; i++) {
            dvm_method *m = &k->vm[i];
            if (strcmp(m->name, "build") || m->insns == NULL || strncmp(m->sig, "()L", 3)) continue;
            dvm_native_fn hook = m->intrinsic;
            m->intrinsic = NULL;
            bool ok = dvm_call(m, self, NULL, ret);
            m->intrinsic = hook;
            return ok;
        }
    }
    return dvm_throw("java/lang/IllegalStateException", "ExoPlayer.Builder.build: no bytecode to fall back on");
}

/* ExoPlayer.Builder.build(), answered by husk.AvPlayer.create (TL_AVPLAYER=0, or create declining: ExoPlayer's own build) */
static bool Exo_build(jobj *self, const jvalue *a, jvalue *ret)
{
    (void)a;
    jvalue args[1]; args[0].l = self;
    jvalue r = { 0 };
    if (tl_dvm_call_static("husk/AvPlayer", "create", "(Ljava/lang/Object;)Ljava/lang/Object;", args, &r) && r.l) { *ret = r; return true; }
    tl_jni_clear();
    return exo_build_original(self, ret);
}

/* nBuildExo(builder): the app's own ExoPlayer, for a stream AVPlayer cannot play */
NAT(A_buildExo) { (void)self; if (!a[0].l) { *ret = L(NULL); return true; } return exo_build_original(a[0].l, ret); }

dvm_native_fn tl_avplayer_hook(const char *cls, const char *name, const char *sig);
dvm_native_fn tl_avplayer_hook(const char *cls, const char *name, const char *sig)
{
    if (strcmp(name, "build")) return NULL;
    if (!strcmp(cls, "androidx/media3/exoplayer/ExoPlayer$Builder") && !strcmp(sig, "()Landroidx/media3/exoplayer/ExoPlayer;")) return Exo_build;
    if (!strcmp(cls, "com/google/android/exoplayer2/ExoPlayer$Builder") && !strcmp(sig, "()Lcom/google/android/exoplayer2/ExoPlayer;")) return Exo_build;
    return NULL;
}
