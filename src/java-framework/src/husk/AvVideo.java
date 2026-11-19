package husk;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Rect;
import android.view.Surface;
import android.view.SurfaceHolder;
import java.util.Map;

/**
 * One video played by iOS's AVPlayer (AvPlayer's natives), drawn into an app's Surface: what android.media.MediaPlayer (and so
 * VideoView) plays video and network media with. Events come on the engine's own thread; the caller moves them to its own.
 */
public final class AvVideo {
    public interface Events {
        void onState(int state);                 /* 1 idle, 2 buffering, 3 ready, 4 ended */
        void onPlaying(boolean playing);
        void onVideoSize(int w, int h);
        void onFirstFrame();
        void onError(String why);
    }

    private final Events ev;
    private volatile long h;
    private volatile SurfaceHolder holder;
    private volatile Surface surface;
    private Thread thread;
    private volatile boolean released;
    private boolean scaleToFill;

    public AvVideo(Events ev) { this.ev = ev; this.h = AvPlayer.nCreate(); }

    public void setSource(String url, Map<String, String> headers) {
        String[] kv = new String[headers != null ? headers.size() * 2 : 0];
        int i = 0;
        if (headers != null) for (Map.Entry<String, String> e : headers.entrySet()) { kv[i++] = e.getKey(); kv[i++] = e.getValue(); }
        if (h != 0) AvPlayer.nSetSource(h, url, kv);
        if (thread == null) { thread = new Thread(this::loop, "HuskAvVideo"); thread.start(); }
    }

    public void setDisplay(SurfaceHolder hd) { holder = hd; surface = null; }
    public void setSurface(Surface s) { surface = s; holder = null; }
    public void setScaleToFill(boolean fill) { scaleToFill = fill; }
    public void play() { if (h != 0) AvPlayer.nPlay(h); }
    public void pause() { if (h != 0) AvPlayer.nPause(h); }
    public void seek(long ms) { if (h != 0) AvPlayer.nSeek(h, ms); }
    public void volume(float v) { if (h != 0) AvPlayer.nVolume(h, v); }
    public long position() { return h != 0 ? Math.max(0, AvPlayer.nPosition(h)) : 0; }
    public long duration() { return h != 0 ? AvPlayer.nDuration(h) : -1; }      /* -1: live or unknown */
    public long buffered() { return h != 0 ? AvPlayer.nBuffered(h) : 0; }
    public boolean playing() { return h != 0 && AvPlayer.nPlaying(h); }
    public int state() { return h != 0 ? AvPlayer.nState(h) : 1; }

    public void release() {
        released = true;
        Thread t = thread; thread = null;
        if (t != null) t.interrupt();
        long x = h; h = 0;
        if (x != 0) AvPlayer.nRelease(x);
    }

    private Surface target() {
        Surface s = surface;
        if (s != null) return s;
        SurfaceHolder hd = holder;
        return hd != null ? hd.getSurface() : null;
    }

    private void loop() {
        Bitmap frame = null;
        Bitmap[] pair = new Bitmap[2];          /* a SurfaceView's frames: one shown while the next is copied into the other */
        int which = 0;
        android.view.SurfaceView shownOn = null;
        Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG);
        Rect dst = new Rect();
        int lastState = 0, w0 = 0, h0 = 0;
        boolean lastPlaying = false, first = false;
        long nextPoll = 0;
        while (!released && thread == Thread.currentThread()) {
            long x = h;
            if (x == 0) break;
            long now = System.nanoTime();
            if (now >= nextPoll) {
                nextPoll = now + 100_000_000L;
                int s = AvPlayer.nState(x);
                if (s < 0) { ev.onError(AvPlayer.nError(x)); break; }
                if (s != lastState) { lastState = s; ev.onState(s); }
                boolean p = AvPlayer.nPlaying(x);
                if (p != lastPlaying) { lastPlaying = p; ev.onPlaying(p); }
            }
            int vs = AvPlayer.nVideoSize(x);
            int w = vs >>> 16, ht = vs & 0xffff;
            if (w > 0 && ht > 0 && (w != w0 || ht != h0)) { w0 = w; h0 = ht; ev.onVideoSize(w, ht); }
            Surface s = target();
            android.view.SurfaceView sv = s != null ? s.huskView : null;
            if (sv != shownOn) { if (shownOn != null) shownOn.huskClearVideo(); shownOn = null; }
            if (w > 0 && ht > 0 && sv != null) {
                /* a SurfaceView: the frame goes to the view as it is, which draws it scaled once (no canvas, no buffer copies) */
                Bitmap b = pair[which];
                if (b == null || b.getWidth() != w || b.getHeight() != ht) b = pair[which] = Bitmap.createBitmap(w, ht, Bitmap.Config.ARGB_8888);
                if (AvPlayer.nCopyFrame(x, b) && sv.huskPostVideoFrame(b, scaleToFill)) {
                    shownOn = sv; which ^= 1;
                    if (!first) { first = true; ev.onFirstFrame(); }
                }
            } else if (w > 0 && ht > 0 && s != null && s.isValid()) {
                if (frame == null || frame.getWidth() != w || frame.getHeight() != ht) frame = Bitmap.createBitmap(w, ht, Bitmap.Config.ARGB_8888);
                if (AvPlayer.nCopyFrame(x, frame) && draw(s, frame, dst, paint, w, ht) && !first) { first = true; ev.onFirstFrame(); }
            }
            try { Thread.sleep(8); } catch (InterruptedException e) { break; }
        }
        if (shownOn != null) shownOn.huskClearVideo();
    }

    private boolean draw(Surface s, Bitmap frame, Rect dst, Paint paint, int w, int ht) {
        Canvas c;
        try { c = s.lockCanvas(null); } catch (RuntimeException e) { return false; }
        if (c == null) return false;
        try {
            int cw = c.getWidth(), ch = c.getHeight();
            float sc = scaleToFill ? Math.max((float) cw / w, (float) ch / ht) : Math.min((float) cw / w, (float) ch / ht);
            int dw = Math.round(w * sc), dh = Math.round(ht * sc);
            dst.set((cw - dw) / 2, (ch - dh) / 2, (cw + dw) / 2, (ch + dh) / 2);
            c.drawColor(0xFF000000);
            c.drawBitmap(frame, null, dst, paint);
        } finally { s.unlockCanvasAndPost(c); }
        return true;
    }
}
