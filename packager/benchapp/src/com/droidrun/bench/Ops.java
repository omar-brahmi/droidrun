package com.droidrun.bench;

import android.util.Log;

/**
 * Correctness tests for the compiler (tools/dexc): every kind of instruction and its edge cases, each giving a value. The
 * "Ops" lines must be the same interpreted and compiled; the Test app on Mac workflow compares them.
 */
final class Ops {
    static void all() {
        t("consts", consts());
        t("int-edges", intEdges());
        t("long-edges", longEdges());
        t("float-edges", floatEdges());
        t("casts", casts());
        t("arrays", arrays());
        t("array-errors", arrayErrors());
        t("switches", switches());
        t("string-switch", stringSwitch());
        t("exceptions", exceptions());
        t("nested-finally", nestedFinally());
        t("stack-overflow", stackOverflow());
        t("calls", calls());
        t("interfaces", interfaces());
        t("statics", statics());
        t("sync", sync());
        t("strings", strings());
        t("lambdas", lambdas());
        t("math", math());
        t("line-number", lineNumber());
        t("clearkey (1 = works)", clearKey());
        t("media-metrics (1 = works)", mediaMetrics());
        Log.i("Ops", "done");
    }

    static void t(String name, long v) { Log.i("Ops", name + ": " + v); }

    static long consts() {
        int a = 3, b = -8, c = 1000, d = -40000, e = 0x7fff0000, f = 0x12345678;
        long g = -1L, h = 0x123456789abcdefL, i = Long.MIN_VALUE, j = 0x7ff0000000000000L;
        float k = -0.0f, l = Float.MAX_VALUE; double m = Double.MIN_VALUE, n = -2.5;
        return a + b + c + d + e + f + g + h + i + j + Float.floatToRawIntBits(k) + Float.floatToRawIntBits(l)
            + Double.doubleToRawLongBits(m) + Double.doubleToRawLongBits(n);
    }

    static int id(int x) { return x; }

    static long intEdges() {
        long s = 0;
        int min = id(Integer.MIN_VALUE), m1 = id(-1), z = id(0);
        s += min / m1; s += min % m1; s += 7 / -2; s += 7 % -2; s += -7 / 2; s += -7 % 2;
        s += 1 << 33; s += -1 >> 40; s += -1 >>> 28; s += min - 1; s += Integer.MAX_VALUE + 1;
        s += (min * m1); s += ~z; s += -min;
        try { s += 5 / z; } catch (ArithmeticException x) { s += 1000; }
        try { s += 5 % z; } catch (ArithmeticException x) { s += 2000; }
        int lit = id(100);
        s += lit / 7 + lit % 7 + (lit * 3) + (lit & 6) + (lit | 9) + (lit ^ 5) + (lit << 2) + (lit >> 1) + (-lit >>> 3) + (7 - lit);
        return s;
    }

    static long idl(long x) { return x; }

    static long longEdges() {
        long s = 0, min = idl(Long.MIN_VALUE), m1 = idl(-1), z = idl(0);
        s += min / m1; s += min % m1; s += 1L << 65; s += -1L >> 70; s += -1L >>> 60; s += min - 1;
        s += Long.compare(min, m1) + Long.compare(m1, m1) + (min < z ? 1 : 0);
        try { s += 5 / z; } catch (ArithmeticException x) { s += 3000; }
        try { s += 5 % z; } catch (ArithmeticException x) { s += 4000; }
        return s;
    }

    static float idf(float x) { return x; }
    static double idd(double x) { return x; }

    static long floatEdges() {
        float nan = idf(Float.NaN), one = idf(1f);
        double dn = idd(Double.NaN), dz = idd(0.0);
        long s = 0;
        s += (nan < one ? 1 : 0) + (nan > one ? 2 : 0) + (nan == nan ? 4 : 0) + (nan != nan ? 8 : 0);
        s += (dn < 1.0 ? 16 : 0) + (dn > 1.0 ? 32 : 0) + (dn <= dz ? 64 : 0) + (dn >= dz ? 128 : 0);
        s += Float.floatToRawIntBits(one / idf(0f)) + Double.doubleToRawLongBits(-1.0 / dz);
        s += Double.doubleToRawLongBits(5.5 % 2.0) + Float.floatToRawIntBits(-5.5f % 2f);
        s += Double.doubleToRawLongBits(-dz) + Float.floatToRawIntBits(-idf(0f));
        return s;
    }

    static long casts() {
        long s = 0;
        float[] fs = { Float.NaN, 1e20f, -1e20f, 3.99f, -3.99f, Float.POSITIVE_INFINITY };
        double[] ds = { Double.NaN, 1e300, -1e300, 2.5, -2.5, Double.NEGATIVE_INFINITY };
        for (float f : fs) s = s * 31 + (int) f + (long) f;
        for (double d : ds) s = s * 31 + (int) d + (long) d + Float.floatToRawIntBits((float) d);
        int big = id(0x12345678);
        s += (byte) big + (short) big + (char) big + (long) big + (int) (long) -1L;
        s += Float.floatToRawIntBits((float) big) + Double.doubleToRawLongBits((double) idl(Long.MAX_VALUE));
        return s;
    }

    static long arrays() {
        boolean[] z = new boolean[5]; byte[] b = new byte[5]; char[] c = new char[5]; short[] sh = new short[5];
        int[] i = { 1, -2, 3, Integer.MIN_VALUE, 5 }; long[] l = new long[5]; float[] f = new float[5]; double[] d = new double[5];
        Object[] o = new Object[5]; String[] st = { "a", "bb", null, "dddd", "" };
        int[][] grid = new int[3][4];
        long s = 0;
        for (int k = 0; k < 5; k++) {
            z[k] = (k & 1) == 0; b[k] = (byte) (k * 100); c[k] = (char) (k * 30000); sh[k] = (short) (k * 20000);
            l[k] = (long) i[k] << 33; f[k] = k / 3f; d[k] = -k / 7.0; o[k] = k % 2 == 0 ? st[k] : Integer.valueOf(k);
            grid[k % 3][k % 4] += k;
        }
        for (int k = 0; k < 5; k++) {
            s = s * 7 + (z[k] ? 1 : 0) + b[k] + c[k] + sh[k] + i[k] + l[k] + Float.floatToRawIntBits(f[k])
                + Double.doubleToRawLongBits(d[k]) + (o[k] == null ? 0 : o[k].hashCode()) + (st[k] == null ? -1 : st[k].length());
        }
        for (int[] row : grid) for (int v : row) s += v;
        System.arraycopy(i, 1, i, 0, 4);
        for (int v : i) s = s * 3 + v;
        return s + i.length + grid.length + grid[0].length;
    }

    static long arrayErrors() {
        long s = 0;
        int[] a = new int[3];
        Object[] strs = new String[2];
        int[] nul = null;
        try { a[3] = 1; } catch (ArrayIndexOutOfBoundsException e) { s += 1; }
        try { s += a[-1]; } catch (ArrayIndexOutOfBoundsException e) { s += 2; }
        try { s += nul[0]; } catch (NullPointerException e) { s += 4; }
        try { s += nul.length; } catch (NullPointerException e) { s += 8; }
        try { strs[0] = Integer.valueOf(1); } catch (ArrayStoreException e) { s += 16; }
        try { s += new int[id(-1)].length; } catch (NegativeArraySizeException e) { s += 32; }
        try { Object x = "s"; s += ((Integer) x); } catch (ClassCastException e) { s += 64; }
        try { System.arraycopy(a, 2, a, 0, 5); } catch (ArrayIndexOutOfBoundsException e) { s += 128; }
        return s;
    }

    static long switches() {
        long s = 0;
        for (int k = -5; k < 40; k++) {
            switch (k) { case -3: s += 1; break; case -1: s += 2; break; case 0: s += 3; break; case 1: s += 4; break;
                         case 2: s += 5; break; case 3: s += 6; break; default: s += 7; }
            switch (k * 1000) { case -5000: s += 100; break; case 7000: s += 200; break; case 39000: s += 300; break; default: break; }
        }
        return s;
    }

    static long stringSwitch() {
        long s = 0;
        String[] keys = { "alpha", "beta", "gamma", "Aa", "BB", "zz" };     // "Aa" and "BB" share a hash code
        for (String k : keys) {
            switch (k) { case "alpha": s += 1; break; case "beta": s += 10; break; case "Aa": s += 100; break;
                         case "BB": s += 1000; break; default: s += 10000; }
        }
        return s;
    }

    static int thrower(int k) {
        if (k == 1) throw new IllegalArgumentException("one");
        if (k == 2) throw new UnsupportedOperationException();
        if (k == 3) { Object o = null; return o.hashCode(); }
        return k * 2;
    }

    static long exceptions() {
        long s = 0;
        for (int k = 0; k < 6; k++) {
            try {
                s += thrower(k);
            } catch (IllegalArgumentException e) {
                s += 10 + e.getMessage().length();
            } catch (UnsupportedOperationException | NullPointerException e) {
                s += e instanceof NullPointerException ? 100 : 200;
            }
        }
        try { throw null; } catch (NullPointerException e) { s += 1000; }
        return s;
    }

    static long nestedFinally() {
        long[] s = { 0 };
        for (int k = 0; k < 4; k++) {
            try {
                try {
                    if (k == 2) throw new RuntimeException("x");
                    s[0] += 1;
                } finally {
                    s[0] += 10;
                    if (k == 3) continue;
                }
                s[0] += 100;
            } catch (RuntimeException e) {
                s[0] += 1000;
            } finally {
                s[0] += 10000;
            }
        }
        return s[0];
    }

    static int depth;
    static int recurse(int n) { depth = n; return recurse(n + 1) + 1; }

    static long stackOverflow() {
        try { recurse(0); } catch (StackOverflowError e) { return depth > 100 ? 1 : 0; }
        return -1;
    }

    static final class Box { private int v; int get() { return v; } void set(int x) { v = x; } }
    static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
    static abstract class A { int f() { return 1; } int g() { return f() * 10; } }
    static class B extends A { int f() { return 2; } }
    static class C extends B { int f() { return super.f() + 5; } }

    static long calls() {
        Box b = new Box();
        long s = 0;
        for (int k = 0; k < 1000; k++) { b.set(b.get() + k); s += b.get(); }
        A[] as = { new B(), new C(), new B() { int f() { return 9; } } };
        for (int k = 0; k < 30; k++) s += as[k % 3].g();       // the same call site, three receiver classes
        return s + fib(20);
    }

    interface Shape { int sides(); default int twice() { return sides() * 2; } }
    static final class Tri implements Shape { public int sides() { return 3; } }
    static final class Sqr implements Shape { public int sides() { return 4; } public int twice() { return 99; } }

    static long interfaces() {
        Shape[] s = { new Tri(), new Sqr(), new Tri() };
        long t = 0;
        for (int k = 0; k < 9; k++) t = t * 3 + s[k % 3].twice() + s[k % 3].sides();
        return t;
    }

    static final StringBuilder order = new StringBuilder();
    static final class Init1 { static int v = 7; static { order.append('a'); } }
    static final class Init2 { static int v = Init1.v * 2; static { order.append('b'); } }

    static long statics() {
        long s = Init2.v + Init1.v;
        Init1.v++;
        return s + Init1.v + order.toString().hashCode();
    }

    static int counter;
    static synchronized void inc() { counter++; }
    synchronized int self() { return 1; }

    static long sync() {
        final Object lock = new Object();
        long s = 0;
        for (int k = 0; k < 100; k++) { inc(); synchronized (lock) { s += k; } }
        try { synchronized (lock) { throw new IllegalStateException(); } } catch (IllegalStateException e) { s += 7; }
        synchronized (lock) { s += 1; }                             // the monitor was left when it threw
        return s + counter + new Ops().self();
    }

    static long strings() {
        String a = "héllo", b = "w世rld";
        String c = a + " " + b + 12 + 'x' + 3.5 + true;
        long s = c.length() + c.hashCode();
        for (int k = 0; k < c.length(); k++) s = s * 31 + c.charAt(k);
        try { s += c.charAt(100); } catch (StringIndexOutOfBoundsException e) { s += 5; }
        s += new String(new char[] { 'a', 'b' }).hashCode() + String.valueOf(42).length() + "abc".indexOf('c');
        return s;
    }

    interface F { int apply(int x); }

    static long lambdas() {
        int base = 5;
        F add = x -> x + base, twice = x -> x * 2;
        java.util.function.IntBinaryOperator mul = (x, y) -> x * y;
        java.util.List<Integer> l = new java.util.ArrayList<>();
        for (int k = 0; k < 10; k++) l.add(k);
        l.removeIf(x -> x % 3 == 0);
        long s = 0;
        for (int v : l) s += add.apply(twice.apply(v)) + mul.applyAsInt(v, 3);
        return s;
    }

    static long math() {
        long s = 0;
        double[] ds = { 2.0, -0.0, 1e-300, 3.7, -3.7, Double.NaN };
        for (double d : ds) s = s * 31 + Double.doubleToRawLongBits(Math.sqrt(d)) + Double.doubleToRawLongBits(Math.floor(d))
            + Double.doubleToRawLongBits(Math.ceil(d));
        s += Math.abs(Integer.MIN_VALUE) + Math.abs(-5) + Math.abs(Long.MIN_VALUE) + Math.min(-3, 4) + Math.max(7L, -9L);
        return s;
    }

    /** ClearKey through MediaDrm (session, license request and response), then the framework's sample decryption (husk.ClearKey,
     *  as MediaCodec.queueSecureInputBuffer uses it) checked against data encrypted here: 'cenc' CTR over two subsamples, and
     *  'cbcs' CBC with a 1:1 pattern. 1 when everything matches. */
    static long clearKey() {
        try {
            java.util.UUID ck = new java.util.UUID(0xe2719d58a985b3c9L, 0x781ab030af78d30eL);
            if (!android.media.MediaDrm.isCryptoSchemeSupported(ck)) return -1;
            android.media.MediaDrm drm = new android.media.MediaDrm(ck);
            byte[] session = drm.openSession();
            byte[] kid = new byte[16], key = new byte[16], iv = new byte[16];
            for (int i = 0; i < 16; i++) { kid[i] = (byte) (0xa0 + i); key[i] = (byte) (i * 17); iv[i] = (byte) (i == 15 ? 0 : 7 * i); }
            // a version 1 PSSH box naming the key id
            java.nio.ByteBuffer pssh = java.nio.ByteBuffer.allocate(52);
            pssh.putInt(52).put("pssh".getBytes()).putInt(0x01000000).putLong(0x1077efecc0b24d02L).putLong(0xace33c1e52e2fb4bL).putInt(1).put(kid).putInt(0);
            String req = new String(drm.getKeyRequest(session, pssh.array(), "cenc", android.media.MediaDrm.KEY_TYPE_STREAMING, null).getData(), "UTF-8");
            String b64kid = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(kid);
            if (!req.contains(b64kid)) return -2;
            String lic = "{\"keys\":[{\"kty\":\"oct\",\"kid\":\"" + b64kid + "\",\"k\":\"" + java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(key) + "\"}]}";
            drm.provideKeyResponse(session, lic.getBytes("UTF-8"));
            Class<?> c = Class.forName("husk.ClearKey");
            java.lang.reflect.Method dec = c.getMethod("decrypt", byte[].class, byte[].class, int.class, int.class, int[].class, int[].class,
                                                       byte[].class, byte[].class, int.class, int.class, int.class);
            byte[] plain = new byte[100];
            for (int i = 0; i < plain.length; i++) plain[i] = (byte) (i * 31 + 5);
            javax.crypto.spec.SecretKeySpec k = new javax.crypto.spec.SecretKeySpec(key, "AES");
            // cenc: clear 10, encrypted 30, clear 20, encrypted 40; one keystream over the 70 encrypted bytes
            javax.crypto.Cipher ctr = javax.crypto.Cipher.getInstance("AES/CTR/NoPadding");
            ctr.init(javax.crypto.Cipher.ENCRYPT_MODE, k, new javax.crypto.spec.IvParameterSpec(iv));
            byte[] enc = plain.clone();
            byte[] ks = ctr.update(new byte[70]);
            for (int i = 0; i < 30; i++) enc[10 + i] ^= ks[i];
            for (int i = 0; i < 40; i++) enc[60 + i] ^= ks[30 + i];
            dec.invoke(null, session, enc, 0, 2, new int[] { 10, 20 }, new int[] { 30, 40 }, kid, iv, 1, 0, 0);
            if (!java.util.Arrays.equals(enc, plain)) return -3;
            // cbcs: clear 4, then 96 bytes = 6 blocks with a 1:1 pattern (blocks 0, 2, 4 encrypted, chained)
            javax.crypto.Cipher cbc = javax.crypto.Cipher.getInstance("AES/CBC/NoPadding");
            cbc.init(javax.crypto.Cipher.ENCRYPT_MODE, k, new javax.crypto.spec.IvParameterSpec(iv));
            byte[] enc2 = plain.clone();
            for (int b = 0; b < 6; b += 2) { byte[] o = cbc.update(plain, 4 + 16 * b, 16); System.arraycopy(o, 0, enc2, 4 + 16 * b, 16); }
            dec.invoke(null, session, enc2, 0, 1, new int[] { 4 }, new int[] { 96 }, kid, iv, 2, 1, 1);
            if (!java.util.Arrays.equals(enc2, plain)) return -4;
            drm.closeSession(session);
            return 1;
        } catch (Throwable e) {
            Log.w("Ops", "clearkey: " + e);
            return -100;
        }
    }

    /** What players read without a check (the Google Mobile Ads video player): MediaPlayer.getMetrics() is never null. */
    static long mediaMetrics() {
        try {
            android.media.MediaPlayer p = new android.media.MediaPlayer();
            android.os.PersistableBundle m = p.getMetrics();
            p.release();
            return m != null && m.getInt("android.media.mediaplayer.width") == 0 ? 1 : 0;
        } catch (Throwable e) {
            Log.w("Ops", "media-metrics: " + e);
            return -100;
        }
    }

    static int lineNumber() {
        try {
            Object o = null;
            o.toString();                                           // the line the trace must name
        } catch (NullPointerException e) {
            StackTraceElement[] st = e.getStackTrace();
            for (StackTraceElement el : st) if (el.getMethodName().equals("lineNumber")) return el.getLineNumber();
        }
        return -1;
    }
}
