package com.droidrun.bench;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;

/**
 * CPU benchmark for the Dalvik runtime: each test runs a fixed amount of work, logs its time and a checksum. The checksum must
 * be the same interpreted and compiled (tools/dexc), so the log shows both speed and correctness.
 */
public class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        new Thread(new Runnable() { public void run() { Bench.all(); } }, "bench").start();
    }
}

final class Bench {
    interface Test { long run(); }

    static void time(String name, Test t) {
        t.run();                                                  // first run: classes resolved, caches filled
        long best = Long.MAX_VALUE, sum = 0;
        for (int i = 0; i < 3; i++) {
            long s = System.nanoTime();
            sum = t.run();
            long ms = (System.nanoTime() - s) / 1000000;
            if (ms < best) best = ms;
        }
        Log.i("Bench", name + ": " + best + " ms, checksum " + sum);
    }

    static void all() {
        Log.i("Bench", "start");
        time("int-loop", new Test() { public long run() { return intLoop(3000000); } });
        time("long-math", new Test() { public long run() { return longMath(1000000); } });
        time("double-math", new Test() { public long run() { return doubleMath(1000000); } });
        time("array-sum", new Test() { public long run() { return arraySum(200000, 10); } });
        time("fields", new Test() { public long run() { return fields(1000000); } });
        time("calls", new Test() { public long run() { return calls(1000000); } });
        time("sort", new Test() { public long run() { return sort(20000); } });
        time("switch", new Test() { public long run() { return switches(1000000); } });
        time("exceptions", new Test() { public long run() { return exceptions(20000); } });
        time("strings", new Test() { public long run() { return strings(20000); } });
        time("objects", new Test() { public long run() { return objects(200000); } });
        Log.i("Bench", "done");
    }

    static long intLoop(int n) {
        int a = 1, b = 7;
        for (int i = 0; i < n; i++) {
            a = a * 31 + (i ^ b);
            b = (b << 3) - (a >>> 5) + i % 7;
            if ((a & 1) == 0) a /= 3;
        }
        return a + (long) b;
    }

    static long longMath(int n) {
        long x = 0x123456789L, y = 3;
        for (int i = 0; i < n; i++) {
            x = x * 6364136223846793005L + 1442695040888963407L;
            y += (x >>> 33) % 1000;
            y ^= x << 7;
        }
        return x ^ y;
    }

    static long doubleMath(int n) {
        double s = 0, t = 1.5;
        float f = 0.25f;
        for (int i = 1; i <= n; i++) {
            s += t / i - Math.sqrt(i) * 0.001;
            t = t * 1.0000001 + f;
            f = f * 0.999f + (float) (i & 7);
        }
        return (long) (s * 1000) + (long) f + Double.doubleToLongBits(t) % 1000;
    }

    static long arraySum(int n, int rounds) {
        int[] a = new int[n];
        long[] l = new long[n / 4];
        byte[] by = new byte[n];
        for (int i = 0; i < n; i++) { a[i] = i * 3 - 7; by[i] = (byte) i; }
        long s = 0;
        for (int r = 0; r < rounds; r++) {
            for (int i = 0; i < n; i++) s += a[i] + by[i];
            for (int i = 0; i < l.length; i++) { l[i] += a[i * 4] + r; s ^= l[i]; }
        }
        return s;
    }

    static final class Point { int x, y; long w; Point next; }

    static int counter;

    static long fields(int n) {
        Point p = new Point(), q = new Point();
        p.next = q; q.next = p;
        for (int i = 0; i < n; i++) {
            p.x += i; p.y -= p.x >> 3; p.w += p.y;
            p = p.next;
            counter++;
        }
        return p.x + p.y + p.w + q.x + counter;
    }

    static abstract class Shape { abstract int area(int k); int twice(int k) { return area(k) * 2; } }
    static final class Sq extends Shape { int area(int k) { return k * k; } }
    static final class Tri extends Shape { int area(int k) { return k * k / 2; } }

    static int add(int a, int b) { return a + b; }

    static long calls(int n) {
        Shape[] s = { new Sq(), new Tri() };
        long t = 0;
        for (int i = 0; i < n; i++) t += s[i & 1].twice(i & 15) + add(i, 3);
        return t;
    }

    static long sort(int n) {
        int[] a = new int[n];
        int seed = 12345;
        for (int i = 0; i < n; i++) { seed = seed * 1103515245 + 12345; a[i] = (seed >>> 8) % 100000; }
        quick(a, 0, n - 1);
        long s = 0;
        for (int i = 0; i < n; i += 97) s = s * 31 + a[i];
        return s;
    }

    static void quick(int[] a, int lo, int hi) {
        while (lo < hi) {
            int p = a[(lo + hi) >>> 1], i = lo, j = hi;
            while (i <= j) {
                while (a[i] < p) i++;
                while (a[j] > p) j--;
                if (i <= j) { int t = a[i]; a[i] = a[j]; a[j] = t; i++; j--; }
            }
            if (j - lo < hi - i) { quick(a, lo, j); lo = i; } else { quick(a, i, hi); hi = j; }
        }
    }

    static long switches(int n) {
        long s = 0;
        for (int i = 0; i < n; i++) {
            switch (i % 9) {
                case 0: s += 3; break;
                case 1: s ^= i; break;
                case 2: s -= 5; break;
                case 3: s += i >> 2; break;
                case 5: s *= 3; break;
                default: s++;
            }
            switch (i & 0x7ff) {
                case 7: s += 1000; break;
                case 300: s -= 77; break;
                case 1999: s ^= 0xff; break;
            }
        }
        return s;
    }

    static int risky(int i) {
        if (i % 3 == 0) throw new IllegalStateException("x" + (i & 3));
        return 10 / (i % 5);
    }

    static long exceptions(int n) {
        long s = 0;
        for (int i = 0; i < n; i++) {
            try {
                s += risky(i);
            } catch (IllegalStateException e) {
                s += e.getMessage().length();
            } catch (ArithmeticException e) {
                s -= 1;
            } finally {
                s++;
            }
        }
        return s;
    }

    static long strings(int n) {
        StringBuilder sb = new StringBuilder();
        long s = 0;
        for (int i = 0; i < n; i++) {
            sb.setLength(0);
            sb.append("item").append(i).append(':').append(i * 7);
            String t = sb.toString();
            s += t.length() + t.charAt(t.length() - 1) + (t.equals("item5:35") ? 1000 : 0);
        }
        return s;
    }

    static long objects(int n) {
        Point head = null;
        long s = 0;
        for (int i = 0; i < n; i++) {
            Point p = new Point();
            p.x = i; p.next = head;
            head = (i % 1000 == 999) ? null : p;
            s += p.x;
        }
        Object[] arr = new Object[64];
        for (int i = 0; i < arr.length; i++) arr[i] = (i & 1) == 0 ? "s" + i : Integer.valueOf(i);
        for (Object o : arr) if (o instanceof String) s += ((String) o).length(); else s += (Integer) o;
        synchronized (Bench.class) { s++; }
        return s;
    }
}
