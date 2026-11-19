package com.husk.avtest;

import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;
import android.util.Log;
import android.widget.VideoView;

/** Plays each test stream (served by the bench on 127.0.0.1:8765) for 25 seconds in a VideoView and logs what happened. */
public class MainActivity extends Activity {
    private static final String[] URLS = {
        "http://127.0.0.1:8765/cenc/stream.mpd",
        "http://127.0.0.1:8765/cbcs/stream.mpd",
        "http://127.0.0.1:8765/live.ts",
        "http://127.0.0.1:8765/dash/stream.mpd",
        "http://127.0.0.1:8765/hls/index.m3u8",
        "http://127.0.0.1:8765/clip.mp4",
    };
    private final Handler handler = new Handler();
    private VideoView view;
    private int next;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        /* the ClearKey key of the encrypted test streams, given the way husk.AvPlayer gives the keys an app's player has */
        try {
            java.lang.reflect.Method m = Class.forName("husk.AvPlayer").getDeclaredMethod("nClearKey", String.class, String.class, String[].class);
            m.setAccessible(true);
            m.invoke(null, "{\"keys\":[{\"kty\":\"oct\",\"kid\":\"a1b2c3d4e5f60718293a4b5c6d7e8f90\",\"k\":\"00112233445566778899aabbccddeeff\"}]}", null, null);
        } catch (Throwable t) { Log.i("AvTest", "no ClearKey hook: " + t); }
        view = new VideoView(this);
        setContentView(view);
        handler.postDelayed(this::playNext, 3000);
    }

    private void playNext() {
        if (next >= URLS.length) { Log.i("AvTest", "done"); return; }
        final String u = URLS[next++];
        Log.i("AvTest", "open " + u);
        view.setOnPreparedListener(mp -> {
            Log.i("AvTest", "prepared " + u + " " + mp.getVideoWidth() + "x" + mp.getVideoHeight() + " duration " + mp.getDuration());
            view.start();
        });
        view.setOnErrorListener((mp, what, extra) -> { Log.i("AvTest", "error " + u + " " + what + "/" + extra); return true; });
        view.setOnInfoListener((mp, what, extra) -> { Log.i("AvTest", "info " + u + " " + what); return false; });
        view.setVideoPath(u);
        handler.postDelayed(() -> {
            Log.i("AvTest", "after 25 s " + u + ": position " + view.getCurrentPosition() + " ms, playing " + view.isPlaying());
            view.stopPlayback();
            playNext();
        }, 25000);
    }
}
