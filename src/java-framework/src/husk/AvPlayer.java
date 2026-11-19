package husk;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Rect;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * An app's Media3 ExoPlayer, played by iOS's own AVPlayer (husk-tl-dvm-avplayer.m). ExoPlayer.Builder.build() is answered with
 * one of these (a Proxy of the app's ExoPlayer interface, dvm_fast_path): the app keeps calling the Player API it knows, while
 * downloading, demuxing and decoding the stream happen natively instead of in the interpreter. Frames come out of AVPlayer as
 * pixel buffers and are drawn into the app's SurfaceView the way MediaCodec's are. Listeners hear the Player events a UI needs.
 * When AVPlayer cannot play a stream (DRM, media the app feeds through its own DataSource, a server that turns AVPlayer away),
 * the app's own ExoPlayer is built from the same Builder and given everything the app did so far -- media, surface, listeners,
 * play state -- and from then on every call goes to it: no stream plays worse than before.
 */
public final class AvPlayer implements InvocationHandler {
    static native long nCreate();
    static native void nSetSource(long h, String url, String[] headers);
    static native void nPlay(long h);
    static native void nPause(long h);
    static native void nSeek(long h, long ms);
    static native void nSeekLive(long h);
    static native long nPosition(long h);
    static native long nDuration(long h);                    /* -1: unknown or live */
    static native long nBuffered(long h);
    static native int nState(long h);                        /* 1 idle, 2 buffering, 3 ready, 4 ended, -1 failed */
    static native boolean nPlaying(long h);
    static native int nVideoSize(long h);                    /* width << 16 | height */
    static native boolean nCopyFrame(long h, Bitmap dst);    /* a new frame, into dst (its size) */
    /* the picture shown by iOS itself (an AVPlayerLayer under the screen) at a SurfaceView's place, in screen pixels: no frame
     * is copied. nLayerSupported: whether this build shows video that way (the iPhone; a Mac harness with TL_VIDEO_LAYER=1). */
    static native void nLayer(long h, int x, int y, int w, int ht, boolean visible, boolean fill);
    static native boolean nLayerSupported();
    static final boolean LAYER = layerSupported();
    private static boolean layerSupported() { try { return nLayerSupported(); } catch (Throwable t) { return false; } }
    static native String nError(long h);
    static native void nVolume(long h, float v);
    static native void nRelease(long h);
    static native Object nBuildExo(Object builder);          /* ExoPlayer.Builder.build()'s own bytecode */
    static native void nClearKey(String keys, String licenseUrl, String[] licenseHeaders);   /* keys: a JSON Web Key set, or null */

    private static final java.util.UUID CLEARKEY = new java.util.UUID(0xe2719d58a985b3c9L, 0x781ab030af78d30eL);
    private static final java.util.UUID COMMON_PSSH = new java.util.UUID(0x1077efecc0b24d02L, 0xace33c1e52e2fb4bL);

    private static final String TAG = "HuskAvPlayer";
    private static final long TIME_UNSET = Long.MIN_VALUE + 1;

    /** ExoPlayer.Builder.build(): the app's ExoPlayer, or null to let ExoPlayer build its own. */
    public static Object create(Object builder) {
        try {
            if ("0".equals(System.getenv("TL_AVPLAYER"))) return null;
            ClassLoader cl = builder.getClass().getClassLoader();
            String pkg = builder.getClass().getName();
            pkg = pkg.substring(0, pkg.lastIndexOf('.'));                       /* androidx.media3.exoplayer */
            Class<?> exo = Class.forName(pkg + ".ExoPlayer", false, cl);
            AvPlayer p = new AvPlayer(cl, exo, builder);
            Object proxy = Proxy.newProxyInstance(cl, new Class<?>[] { exo }, p);
            p.self = proxy;
            android.util.Log.i(TAG, "ExoPlayer is played by AVPlayer");
            return proxy;
        } catch (Throwable t) {
            android.util.Log.w(TAG, "AVPlayer not used: " + t);
            return null;
        }
    }

    private final ClassLoader cl;
    private final Object builder;
    private volatile Object exo;                               /* the app's own ExoPlayer, once AVPlayer has given up */
    private final List<Object[]> replay = new ArrayList<>();   /* { Method, args }: what the app did, for exo */
    private final boolean media3;                              /* androidx.media3, else ExoPlayer 2 (com.google.android.exoplayer2) */
    private final Handler handler;
    private final List<Object> listeners = new CopyOnWriteArrayList<>();
    private long h;
    private Object self, mediaItem, mediaSource, playerError;
    private String url, drmScheme, licenseUrl;
    private String[] licenseHeaders = new String[0];
    private String[] headers = new String[0];
    private boolean playWhenReady, prepared, released, firstFrame;
    private int state = 1, lastState = 1, videoW, videoH;
    private boolean lastPlaying, drm;
    private float volume = 1f;
    private Surface surface;
    private SurfaceHolder holder;
    private Thread renderer;

    private AvPlayer(ClassLoader cl, Class<?> exo, Object builder) {
        this.cl = cl;
        this.builder = builder;
        String n = exo.getName();
        this.media3 = n.startsWith("androidx.media3");
        Looper l = Looper.myLooper();
        this.handler = new Handler(l != null ? l : Looper.getMainLooper());
    }

    /* ---------------------------------------------------------------- the Player API */

    @Override
    public Object invoke(Object proxy, Method m, Object[] a) throws Throwable {
        String n = m.getName();
        Object e = exo;
        if (e != null && !n.equals("equals") && !n.equals("hashCode")) {
            try { return m.invoke(e, a); } catch (java.lang.reflect.InvocationTargetException x) { throw x.getCause(); }
        }
        if (REPLAYED.contains(n)) synchronized (replay) { replay.add(new Object[] { m, a }); }
        try {
            switch (n) {
            case "equals": return proxy == a[0];
            case "hashCode": return System.identityHashCode(proxy);
            case "toString": return "HuskAvPlayer@" + Integer.toHexString(System.identityHashCode(proxy));
            case "setMediaItem": case "setMediaItems": case "addMediaItem": case "addMediaItems":
                takeItem(first(a)); return null;
            case "setMediaSource": case "setMediaSources": case "addMediaSource": case "addMediaSources":
                takeSource(first(a)); return null;
            case "prepare": prepare(); return null;
            case "play": setPlayWhenReady(true); return null;
            case "pause": setPlayWhenReady(false); return null;
            case "setPlayWhenReady": setPlayWhenReady((Boolean) a[0]); return null;
            case "getPlayWhenReady": return playWhenReady;
            case "isPlaying": return h != 0 && nPlaying(h);
            case "getPlaybackState": return state;
            case "getPlaybackSuppressionReason": return 0;
            case "isLoading": return state == 2;
            case "seekTo":
                if (a != null && a.length > 0 && a[a.length - 1] instanceof Long) { if (h != 0) nSeek(h, (Long) a[a.length - 1]); }
                return null;
            case "seekToDefaultPosition": if (h != 0) nSeekLive(h); return null;
            case "stop": if (h != 0) nPause(h); setState(1); return null;
            case "release": release(); return null;
            case "getCurrentPosition": case "getContentPosition": return h != 0 ? Math.max(0, nPosition(h)) : 0L;
            case "getDuration": case "getContentDuration": { long d = h != 0 ? nDuration(h) : -1; return d < 0 ? TIME_UNSET : d; }
            case "getBufferedPosition": case "getContentBufferedPosition": return h != 0 ? Math.max(0, nBuffered(h)) : 0L;
            case "getTotalBufferedDuration": return h != 0 ? Math.max(0, nBuffered(h) - nPosition(h)) : 0L;
            case "getBufferedPercentage": { long d = h != 0 ? nDuration(h) : -1; return d > 0 ? (int) Math.min(100, nBuffered(h) * 100 / d) : 0; }
            case "isCurrentMediaItemLive": case "isCurrentMediaItemDynamic": return h != 0 && nDuration(h) < 0;
            case "isCurrentMediaItemSeekable": return h != 0 && nDuration(h) > 0;
            case "getCurrentLiveOffset": return TIME_UNSET;
            case "getCurrentMediaItem": return mediaItem;
            case "getMediaItemCount": return mediaItem != null ? 1 : 0;
            case "getMediaItemAt": return mediaItem;
            case "getCurrentMediaItemIndex": case "getCurrentWindowIndex": case "getCurrentPeriodIndex": return 0;
            case "getNextMediaItemIndex": case "getPreviousMediaItemIndex": return -1;
            case "hasNextMediaItem": case "hasPreviousMediaItem": case "isPlayingAd": return false;
            case "getCurrentAdGroupIndex": case "getCurrentAdIndexInAdGroup": return -1;
            case "setVolume": volume = (Float) a[0]; if (h != 0) nVolume(h, volume); return null;
            case "getVolume": return volume;
            case "addListener": if (a[0] != null && !listeners.contains(a[0])) listeners.add(a[0]); return null;
            case "removeListener": listeners.remove(a[0]); return null;
            case "addAnalyticsListener": case "removeAnalyticsListener": return null;
            case "setVideoSurfaceView": setSurfaceView((SurfaceView) a[0]); return null;
            case "setVideoSurfaceHolder": setHolder((SurfaceHolder) a[0]); return null;
            case "setVideoSurface": setSurface((Surface) a[0]); return null;
            case "setVideoTextureView":
                if (a[0] != null) { android.graphics.SurfaceTexture st = ((android.view.TextureView) a[0]).getSurfaceTexture(); setSurface(st != null ? new Surface(st) : null); }
                return null;
            case "clearVideoSurface": case "clearVideoSurfaceView": case "clearVideoSurfaceHolder": case "clearVideoTextureView":
                setSurface(null); return null;
            case "getVideoSize": return videoSize();
            case "getPlayerError": return playerError;
            case "getApplicationLooper": return handler.getLooper();
            case "isCommandAvailable": return true;
            case "getAvailableCommands": return allCommands();
            case "getRepeatMode": return 0;
            case "getShuffleModeEnabled": return false;
            case "isReleased": return released;
            default: return fallback(m);
            }
        } catch (Throwable t) {
            android.util.Log.w(TAG, n + ": " + t);
            return fallback(m);
        }
    }

    private static final java.util.Set<String> REPLAYED = new java.util.HashSet<>(java.util.Arrays.asList(
        "setMediaItem", "setMediaItems", "addMediaItem", "addMediaItems", "setMediaSource", "setMediaSources", "addMediaSource",
        "addMediaSources", "prepare", "setPlayWhenReady", "play", "pause", "seekTo", "seekToDefaultPosition", "setVolume", "addListener",
        "removeListener", "addAnalyticsListener", "removeAnalyticsListener", "setVideoSurfaceView", "setVideoSurfaceHolder", "setVideoSurface",
        "setVideoTextureView", "clearVideoSurface", "clearVideoSurfaceView", "clearVideoSurfaceHolder", "clearVideoTextureView",
        "setRepeatMode", "setPlaybackParameters", "setAudioAttributes", "setHandleAudioBecomingNoisy", "setWakeMode", "setTrackSelectionParameters"));

    /** AVPlayer cannot play this stream: the app's own ExoPlayer takes over, on the app's thread. */
    private void fallBackToExo(String why) {
        android.util.Log.w(TAG, "AVPlayer cannot play this stream (" + why + "); the app's own ExoPlayer takes over");
        post(() -> {
            if (exo != null || released) return;
            Object real;
            try { real = nBuildExo(builder); } catch (Throwable t) { real = null; android.util.Log.w(TAG, "ExoPlayer could not be built: " + t); }
            if (real == null) { fail(why); return; }
            Thread r = renderer; renderer = null;
            if (r != null) r.interrupt();
            if (h != 0) { long x = h; h = 0; nRelease(x); }
            List<Object[]> calls;
            synchronized (replay) { calls = new ArrayList<>(replay); replay.clear(); }
            for (Object[] c : calls) {
                try { ((Method) c[0]).invoke(real, (Object[]) c[1]); } catch (Throwable t) { android.util.Log.w(TAG, "replay " + ((Method) c[0]).getName() + ": " + t); }
            }
            exo = real;
        });
    }

    private static Object first(Object[] a) {
        if (a == null || a.length == 0) return null;
        Object o = a[0];
        if (o instanceof List) return ((List<?>) o).isEmpty() ? null : ((List<?>) o).get(0);
        return o;
    }

    /** What an unlisted method answers: nothing, zero, or the EMPTY/DEFAULT/UNKNOWN constant of its type. */
    private Object fallback(Method m) {
        Class<?> r = m.getReturnType();
        if (r == void.class) return null;
        if (r == boolean.class) return false;
        if (r == int.class) return 0;
        if (r == long.class) return 0L;
        if (r == float.class) return 0f;
        if (r == double.class) return 0d;
        if (r == short.class) return (short) 0;
        if (r == byte.class) return (byte) 0;
        if (r == char.class) return (char) 0;
        if (r == Looper.class) return handler.getLooper();
        if (r.isInstance(self)) return self;
        for (String c : new String[] { "EMPTY", "DEFAULT", "UNKNOWN", "EMPTY_TIME_ZERO", "DEFAULT_UNSET" }) {
            try {
                Field f = r.getField(c);
                if (Modifier.isStatic(f.getModifiers()) && r.isAssignableFrom(f.getType())) return f.get(null);
            } catch (Throwable ignored) { }
        }
        if (r == List.class) return new ArrayList<>();
        return null;
    }

    /* ---------------------------------------------------------------- media */

    private void takeItem(Object item) {
        if (item == null) return;
        mediaItem = item;
        Object lc = field(item, "localConfiguration");
        if (lc == null) lc = field(item, "playbackProperties");
        Object uri = lc != null ? field(lc, "uri") : null;
        if (uri == null) uri = findOfType(item, Uri.class, 3, new IdentityHashMap<>());
        url = uri != null ? uri.toString() : null;
        Object dc = lc != null ? field(lc, "drmConfiguration") : null;
        drm = dc != null;
        drmScheme = null; licenseUrl = null; licenseHeaders = new String[0];
        if (dc != null) {
            Object scheme = field(dc, "scheme");
            if (scheme == null) scheme = field(dc, "uuid");
            drmScheme = scheme != null ? scheme.toString() : "unknown";
            Object lic = field(dc, "licenseUri");
            licenseUrl = lic != null ? lic.toString() : null;
            Object lh = field(dc, "licenseRequestHeaders");
            if (lh == null) lh = field(dc, "requestHeaders");
            if (lh instanceof Map) {
                List<String> kv = new ArrayList<>();
                for (Map.Entry<?, ?> e : ((Map<?, ?>) lh).entrySet()) { kv.add(String.valueOf(e.getKey())); kv.add(String.valueOf(e.getValue())); }
                licenseHeaders = kv.toArray(new String[0]);
            }
        }
    }

    private void takeSource(Object source) {
        if (source == null) return;
        mediaSource = source;
        Object item = null;
        try { item = source.getClass().getMethod("getMediaItem").invoke(source); } catch (Throwable ignored) { }
        if (item != null) takeItem(item);
        /* request headers (User-Agent, Referer...) the app gave its HTTP data source factory */
        Map<String, String> found = new HashMap<>();
        collectHeaders(source, found, 5, new IdentityHashMap<>());
        if (!found.isEmpty()) {
            String[] kv = new String[found.size() * 2]; int i = 0;
            for (Map.Entry<String, String> e : found.entrySet()) { kv[i++] = e.getKey(); kv[i++] = e.getValue(); }
            headers = kv;
            android.util.Log.i(TAG, "request headers from the app: " + found.keySet());
        }
    }

    private void prepare() {
        if (released) return;
        if (url == null) { fallBackToExo("no URL in the media item"); return; }
        if (!clearKey()) return;
        playerError = null;
        if (h == 0) h = nCreate();
        nVolume(h, volume);
        nSetSource(h, url, headers);
        prepared = true; firstFrame = false;
        setState(2);
        if (playWhenReady) nPlay(h);
        startRenderer();
    }

    /**
     * ClearKey: the keys the app gave its player (a LocalMediaDrmCallback's JSON key set, or "kid:key" in hex, anywhere under the
     * media item, the media source or the builder), and its license server, go to the local server, which decrypts the segments
     * for AVPlayer. Other DRM (Widevine, PlayReady) is the app's own player's. False when the app's player has taken over.
     */
    private boolean clearKey() {
        boolean ck = drmScheme == null || drmScheme.equals(CLEARKEY.toString()) || drmScheme.equals(COMMON_PSSH.toString());
        if (drm && !ck) { fallBackToExo("DRM " + drmScheme); return false; }
        IdentityHashMap<Object, Boolean> seen = new IdentityHashMap<>();
        List<String> keys = new ArrayList<>();
        for (Object root : new Object[] { mediaItem, mediaSource, builder }) findKeys(root, 9, seen, keys);
        boolean license = drm && licenseUrl != null && !licenseUrl.isEmpty();
        if (!keys.isEmpty() || license) {
            android.util.Log.i(TAG, "ClearKey: " + keys.size() + " key set(s) from the app" + (license ? ", license server " + licenseUrl : ""));
            for (String k : keys) nClearKey(k, null, null);
            if (license) nClearKey(null, licenseUrl, licenseHeaders);
        } else if (drm) { fallBackToExo("ClearKey, but no keys or license server found"); return false; }
        return true;
    }

    /** ClearKey key sets under o, into out: Strings or byte[]s holding {"keys":[...]} (JSON), or "kid:key" pairs in hex. */
    private static void findKeys(Object o, int depth, IdentityHashMap<Object, Boolean> seen, List<String> out) {
        if (o == null || depth < 0 || out.size() >= 200 || seen.size() > 50000 || seen.put(o, Boolean.TRUE) != null) return;
        if (o instanceof byte[]) { byte[] b = (byte[]) o; if (b.length > 20 && b.length < 65536 && b[0] == '{') add(keysIn(new String(b, java.nio.charset.StandardCharsets.UTF_8)), out); return; }
        if (o instanceof String) { add(keysIn((String) o), out); return; }
        if (o instanceof Object[]) { for (Object x : (Object[]) o) findKeys(x, depth - 1, seen, out); return; }
        if (o instanceof Map) { for (Object x : ((Map<?, ?>) o).values()) findKeys(x, depth - 1, seen, out); return; }
        if (o instanceof java.util.Collection) { for (Object x : (java.util.Collection<?>) o) findKeys(x, depth - 1, seen, out); return; }
        Class<?> oc = o.getClass();
        String n = oc.getName();
        if (oc.isArray() || n.startsWith("java.") || n.startsWith("android.") || n.startsWith("kotlin.") || n.startsWith("dalvik.")) return;
        for (Class<?> c = oc; c != null && c != Object.class; c = c.getSuperclass()) {
            for (Field f : c.getDeclaredFields()) {
                if (Modifier.isStatic(f.getModifiers()) || f.getType().isPrimitive()) continue;
                try { f.setAccessible(true); findKeys(f.get(o), depth - 1, seen, out); } catch (Throwable ignored) { }
            }
        }
    }

    private static void add(String keys, List<String> out) { if (keys != null && !out.contains(keys)) out.add(keys); }

    private static final java.util.regex.Pattern HEX_PAIR = java.util.regex.Pattern.compile("([0-9a-fA-F]{32})\\s*:\\s*([0-9a-fA-F]{32})");

    private static String keysIn(String s) {
        if (s.length() < 20 || s.length() > 65536) return null;
        if (s.startsWith("{") && s.contains("\"keys\"") && s.contains("\"k\"")) return s;
        java.util.regex.Matcher m = HEX_PAIR.matcher(s);
        StringBuilder j = null;
        while (m.find()) {
            j = j == null ? new StringBuilder("{\"keys\":[") : j.append(',');
            j.append("{\"kty\":\"oct\",\"kid\":\"").append(b64url(m.group(1))).append("\",\"k\":\"").append(b64url(m.group(2))).append("\"}");
        }
        return j != null ? j.append("]}").toString() : null;
    }

    private static String b64url(String hex) {
        byte[] b = new byte[hex.length() / 2];
        for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(hex.substring(2 * i, 2 * i + 2), 16);
        return android.util.Base64.encodeToString(b, android.util.Base64.URL_SAFE | android.util.Base64.NO_PADDING | android.util.Base64.NO_WRAP);
    }

    private void setPlayWhenReady(boolean p) {
        if (playWhenReady != p) {
            playWhenReady = p;
            post(() -> {
                for (Object l : listeners) call(l, "onPlayWhenReadyChanged", new Class<?>[] { boolean.class, int.class }, p, 1);
                events(5);
            });
        }
        if (h != 0 && prepared) { if (p) nPlay(h); else nPause(h); }
    }

    private void release() {
        released = true;
        Thread r = renderer; renderer = null;
        if (r != null) r.interrupt();
        if (h != 0) { long x = h; h = 0; nRelease(x); }
        listeners.clear();
    }

    private void fail(String why) { fail(why, 1000 /* ERROR_CODE_UNSPECIFIED */, null); }
    private void fail(String why, int code, Throwable cause) {
        android.util.Log.w(TAG, "playback failed: " + why + " (error code " + code + ")");
        playerError = newInstance(c("PlaybackException"), new Class<?>[] { String.class, Throwable.class, int.class },
                                  why, cause, code);
        Object e = playerError;
        setState(1);
        post(() -> {
            for (Object l : listeners) {
                call(l, "onPlayerErrorChanged", new Class<?>[] { cls(c("PlaybackException")) }, e);
                call(l, "onPlayerError", new Class<?>[] { cls(c("PlaybackException")) }, e);
            }
            events(10);
        });
    }

    private void setState(int s) {
        state = s;
        if (s == lastState) return;
        lastState = s;
        post(() -> {
            for (Object l : listeners) call(l, "onPlaybackStateChanged", new Class<?>[] { int.class }, s);
            events(4);
        });
    }

    /* ---------------------------------------------------------------- video into the app's surface */

    private void setSurfaceView(SurfaceView v) { setHolder(v != null ? v.getHolder() : null); }
    private synchronized void setHolder(SurfaceHolder hd) { holder = hd; surface = null; }
    private synchronized void setSurface(Surface s) { surface = s; holder = null; }

    private synchronized Surface target() {
        if (surface != null) return surface;
        return holder != null ? holder.getSurface() : null;
    }

    private void startRenderer() {
        if (renderer != null) return;
        renderer = new Thread(this::renderLoop, "HuskAvPlayer");
        renderer.start();
    }

    private void renderLoop() {
        Bitmap frame = null;
        Bitmap[] pair = new Bitmap[2];          /* a SurfaceView's frames: one shown while the next is copied into the other */
        int which = 0;
        SurfaceView shownOn = null, layerOn = null;
        Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG);
        Rect dst = new Rect();
        long nextPoll = 0;
        while (renderer == Thread.currentThread() && !released) {
            long now = System.nanoTime();
            if (now >= nextPoll) { poll(); nextPoll = now + 100_000_000L; }
            int vs = h != 0 ? nVideoSize(h) : 0;
            int w = vs >>> 16, ht = vs & 0xffff;
            Surface s = target();
            SurfaceView sv = s != null ? s.huskView : null;
            if (sv != shownOn) { if (shownOn != null) shownOn.huskClearVideo(); shownOn = null; }
            if (sv != layerOn && layerOn != null) { layerOn.huskSetVideoLayer(null); layerOn = null; }
            if (sv != null && LAYER) {
                /* iOS shows the picture itself, under the screen where the SurfaceView leaves a hole: nothing is copied */
                if (layerOn == null) {
                    sv.huskSetVideoLayer((x0, y0, w0, h0, vis) -> { long cur = h; if (cur != 0) nLayer(cur, x0, y0, w0, h0, vis, false); });
                    layerOn = sv;
                }
                if (w > 0 && ht > 0) framed(w, ht);
                try { Thread.sleep(30); } catch (InterruptedException e) { break; }
                continue;
            }
            if (w > 0 && ht > 0 && sv != null) {
                /* a SurfaceView: the frame goes to the view as it is, which draws it scaled once (no canvas, no buffer copies) */
                Bitmap b = pair[which];
                if (b == null || b.getWidth() != w || b.getHeight() != ht) b = pair[which] = Bitmap.createBitmap(w, ht, Bitmap.Config.ARGB_8888);
                if (h != 0 && nCopyFrame(h, b) && sv.huskPostVideoFrame(b, false)) { shownOn = sv; which ^= 1; framed(w, ht); }
            } else if (w > 0 && ht > 0 && s != null && s.isValid()) {
                if (frame == null || frame.getWidth() != w || frame.getHeight() != ht) frame = Bitmap.createBitmap(w, ht, Bitmap.Config.ARGB_8888);
                if (h != 0 && nCopyFrame(h, frame)) draw(s, frame, dst, paint, w, ht);
            }
            try { Thread.sleep(8); } catch (InterruptedException e) { break; }
        }
        if (shownOn != null) shownOn.huskClearVideo();
        if (layerOn != null) layerOn.huskSetVideoLayer(null);
    }

    private void draw(Surface s, Bitmap frame, Rect dst, Paint paint, int w, int ht) {
        Canvas c;
        try { c = s.lockCanvas(null); } catch (RuntimeException e) { return; }
        if (c == null) return;
        try {
            int cw = c.getWidth(), ch = c.getHeight();
            float sc = Math.min((float) cw / w, (float) ch / ht);            /* fit, as ExoPlayer's default resize mode */
            int dw = Math.round(w * sc), dh = Math.round(ht * sc);
            dst.set((cw - dw) / 2, (ch - dh) / 2, (cw + dw) / 2, (ch + dh) / 2);
            c.drawColor(0xFF000000);
            c.drawBitmap(frame, null, dst, paint);
        } finally { s.unlockCanvasAndPost(c); }
        framed(w, ht);
    }

    /* a frame is on screen: the first one, or one of a new size, tells the listeners */
    private void framed(int w, int ht) {
        if (!firstFrame || w != videoW || ht != videoH) {
            boolean sized = w != videoW || ht != videoH;
            firstFrame = true; videoW = w; videoH = ht;
            Object size = videoSize();
            post(() -> {
                for (Object l : listeners) {
                    if (sized) call(l, "onVideoSizeChanged", new Class<?>[] { cls(c("VideoSize")) }, size);
                    call(l, "onRenderedFirstFrame", new Class<?>[0]);
                }
                events(25, 26);
            });
        }
    }

    /** AVPlayer's state, turned into Player events. */
    private void poll() {
        if (h == 0 || !prepared) return;
        int s = nState(h);
        if (s < 0) {
            prepared = false;
            String why = nError(h);
            /* the server said no (404, 403) or could not be reached: the app's to handle, as ExoPlayer reports it (PrimeTV goes to its
               next server and sets a new item, which AVPlayer plays). Only a stream AVPlayer cannot play goes to the app's ExoPlayer. */
            if (why != null && why.startsWith("http: ")) {
                String rest = why.substring(6);
                int sp = rest.indexOf(' '), status = 0;
                try { status = Integer.parseInt(sp > 0 ? rest.substring(0, sp) : rest); } catch (NumberFormatException ignored) { }
                String msg = sp > 0 ? rest.substring(sp + 1) : rest;
                fail(msg, 2004 /* ERROR_CODE_IO_BAD_HTTP_STATUS */, httpError(status, msg));
                return;
            }
            if (why != null && why.startsWith("net: ")) { fail(why.substring(5), 2001 /* ERROR_CODE_IO_NETWORK_CONNECTION_FAILED */, new java.io.IOException(why.substring(5))); return; }
            fallBackToExo(why);
            return;
        }
        setState(s);
        boolean playing = nPlaying(h);
        if (playing != lastPlaying) {
            lastPlaying = playing;
            post(() -> {
                for (Object l : listeners) call(l, "onIsPlayingChanged", new Class<?>[] { boolean.class }, playing);
                events(7);
            });
        }
    }

    /** The exception ExoPlayer's HTTP data source throws for an error status (HttpDataSource.InvalidResponseCodeException): apps read
     *  its responseCode from the error's cause to pick their next server. Any IOException when it cannot be made. */
    private Throwable httpError(int status, String msg) {
        String ds = media3 ? "androidx.media3.datasource." : "com.google.android.exoplayer2.upstream.";
        try {
            Class<?> ex = Class.forName(ds + "HttpDataSource$InvalidResponseCodeException", false, cl);
            Class<?> spec = Class.forName(ds + "DataSpec", false, cl);
            Object dataSpec = spec.getConstructor(Uri.class).newInstance(Uri.parse(url != null ? url : ""));
            for (Constructor<?> k : ex.getConstructors()) {
                Class<?>[] t = k.getParameterTypes();
                if (t.length == 0 || t[0] != int.class) continue;
                Object[] a = new Object[t.length];
                for (int i = 0; i < t.length; i++) {
                    if (i == 0) a[i] = status;
                    else if (t[i] == String.class) a[i] = msg;
                    else if (t[i] == spec) a[i] = dataSpec;
                    else if (t[i] == Map.class) a[i] = new HashMap<String, List<String>>();
                    else if (t[i] == byte[].class) a[i] = new byte[0];
                    else if (t[i] == int.class) a[i] = 1;            /* TYPE_OPEN */
                    else a[i] = null;                                   /* the IOException cause */
                }
                return (Throwable) k.newInstance(a);
            }
        } catch (Throwable t) { android.util.Log.w(TAG, "no InvalidResponseCodeException: " + t); }
        return new java.io.IOException("HTTP " + status + ": " + msg);
    }

    private Object videoSize() {
        if (videoW <= 0) {
            try { return cls(c("VideoSize")).getField("UNKNOWN").get(null); } catch (Throwable t) { return null; }
        }
        return newInstance(c("VideoSize"), new Class<?>[] { int.class, int.class }, videoW, videoH);
    }

    /* ---------------------------------------------------------------- events */

    private void post(Runnable r) { handler.post(r); }

    /** onEvents(player, events): what the Media3 UI updates itself from. */
    private void events(int... ev) {
        try {
            Class<?> fsb = cls(c("FlagSet$Builder"));
            Object b = fsb.getConstructor().newInstance();
            Method add = fsb.getMethod("add", int.class);
            for (int e : ev) add.invoke(b, e);
            Object flags = fsb.getMethod("build").invoke(b);
            Class<?> evc = cls(c("Player$Events"));
            Object events = evc.getConstructor(cls(c("FlagSet"))).newInstance(flags);
            for (Object l : listeners) call(l, "onEvents", new Class<?>[] { cls(c("Player")), evc }, self, events);
        } catch (Throwable ignored) { }
    }

    private Object allCommands() {
        try {
            Class<?> cb = cls(c("Player$Commands$Builder"));
            Object b = cb.getConstructor().newInstance();
            cb.getMethod("addAllCommands").invoke(b);
            return cb.getMethod("build").invoke(b);
        } catch (Throwable t) {
            try { return cls(c("Player$Commands")).getField("EMPTY").get(null); } catch (Throwable t2) { return null; }
        }
    }

    private static void call(Object target, String name, Class<?>[] types, Object... args) {
        if (target == null) return;
        try {
            Method m = target.getClass().getMethod(name, types);
            m.setAccessible(true);
            m.invoke(target, args);
        } catch (NoSuchMethodException ignored) {
        } catch (Throwable t) {
            android.util.Log.w(TAG, "listener " + name + ": " + t);
        }
    }

    /* ---------------------------------------------------------------- reflection over the app's classes */

    /** A Player API class by its Media3 simple name, in the app's flavour of ExoPlayer. */
    private String c(String simple) {
        if (media3) return "androidx.media3.common." + simple;
        if (simple.equals("VideoSize")) return "com.google.android.exoplayer2.video.VideoSize";
        if (simple.startsWith("FlagSet")) return "com.google.android.exoplayer2.util." + simple;
        return "com.google.android.exoplayer2." + simple;
    }

    private Class<?> cls(String name) {
        try { return Class.forName(name, false, cl); } catch (Throwable t) { return Object.class; }
    }

    private Object newInstance(String name, Class<?>[] types, Object... args) {
        try {
            Constructor<?> c = cls(name).getConstructor(types);
            return c.newInstance(args);
        } catch (Throwable t) { return null; }
    }

    private static Object field(Object o, String name) {
        for (Class<?> c = o.getClass(); c != null && c != Object.class; c = c.getSuperclass()) {
            try { Field f = c.getDeclaredField(name); f.setAccessible(true); return f.get(o); } catch (NoSuchFieldException e) { } catch (Throwable t) { return null; }
        }
        return null;
    }

    private static Object findOfType(Object o, Class<?> type, int depth, IdentityHashMap<Object, Boolean> seen) {
        if (o == null || depth < 0 || seen.put(o, Boolean.TRUE) != null) return null;
        if (type.isInstance(o)) return o;
        for (Class<?> c = o.getClass(); c != null && c != Object.class && !c.getName().startsWith("java."); c = c.getSuperclass()) {
            for (Field f : c.getDeclaredFields()) {
                if (Modifier.isStatic(f.getModifiers()) || f.getType().isPrimitive()) continue;
                try { f.setAccessible(true); Object v = findOfType(f.get(o), type, depth - 1, seen); if (v != null) return v; } catch (Throwable ignored) { }
            }
        }
        return null;
    }

    /** Map<String,String> fields (an HTTP data source factory's request properties) and a userAgent, anywhere under o. */
    private static void collectHeaders(Object o, Map<String, String> out, int depth, IdentityHashMap<Object, Boolean> seen) {
        if (o == null || depth < 0 || seen.put(o, Boolean.TRUE) != null) return;
        if (o instanceof Map) {
            for (Map.Entry<?, ?> e : ((Map<?, ?>) o).entrySet())
                if (e.getKey() instanceof String && e.getValue() instanceof String && looksLikeHeader((String) e.getKey())) out.put((String) e.getKey(), (String) e.getValue());
            return;
        }
        Class<?> oc = o.getClass();
        if (oc.isArray() || oc.getName().startsWith("java.") || oc.getName().startsWith("android.")) return;
        for (Class<?> c = oc; c != null && c != Object.class; c = c.getSuperclass()) {
            for (Field f : c.getDeclaredFields()) {
                if (Modifier.isStatic(f.getModifiers()) || f.getType().isPrimitive()) continue;
                try {
                    f.setAccessible(true);
                    Object v = f.get(o);
                    if (v instanceof String && f.getName().toLowerCase().contains("useragent")) out.put("User-Agent", (String) v);
                    else collectHeaders(v, out, depth - 1, seen);
                } catch (Throwable ignored) { }
            }
        }
    }

    private static boolean looksLikeHeader(String k) {
        if (k.isEmpty() || k.length() > 64) return false;
        for (int i = 0; i < k.length(); i++) { char ch = k.charAt(i); if (!(Character.isLetterOrDigit(ch) || ch == '-' || ch == '_')) return false; }
        return true;
    }
}
