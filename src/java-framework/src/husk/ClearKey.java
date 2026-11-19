package husk;

import java.util.ArrayList;
import java.util.Base64;
import java.util.HashMap;
import java.util.List;
import java.util.UUID;

import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * ClearKey DRM for apps that play through Android's MediaDrm, MediaCrypto and MediaCodec (ExoPlayer when a stream falls back
 * from the iOS player, husk.AvPlayer): the sessions MediaDrm opens, the license request (W3C ClearKey JSON) and response,
 * and the samples' decryption, 'cenc' (AES-CTR) and 'cbcs' (AES-CBC with an encrypt:skip pattern), before the decoder.
 * Only ClearKey: Widevine and PlayReady need a vendor's secure module, which iOS does not have.
 */
public final class ClearKey {
    public static final UUID CLEARKEY = new UUID(0xe2719d58a985b3c9L, 0x781ab030af78d30eL);
    public static final UUID COMMON_PSSH = new UUID(0x1077efecc0b24d02L, 0xace33c1e52e2fb4bL);

    private ClearKey() {}

    public static boolean supports(UUID scheme) { return CLEARKEY.equals(scheme) || COMMON_PSSH.equals(scheme); }

    /** A session's keys, by key id in hex. */
    private static final HashMap<String, HashMap<String, byte[]>> SESSIONS = new HashMap<>();
    private static final java.security.SecureRandom RANDOM = new java.security.SecureRandom();

    public static synchronized byte[] openSession() {
        byte[] id = new byte[8];
        RANDOM.nextBytes(id);
        SESSIONS.put(hex(id), new HashMap<String, byte[]>());
        return id;
    }

    public static synchronized void closeSession(byte[] id) { if (id != null) SESSIONS.remove(hex(id)); }

    public static synchronized boolean hasSession(byte[] id) { return id != null && SESSIONS.containsKey(hex(id)); }

    /** The license request: {"kids":["<base64url>",...],"type":"temporary"} with the key ids the init data names. */
    public static byte[] keyRequest(byte[] init, String mime) {
        StringBuilder sb = new StringBuilder("{\"kids\":[");
        List<byte[]> kids = keyIds(init, mime);
        for (int i = 0; i < kids.size(); i++) {
            if (i > 0) sb.append(',');
            sb.append('"').append(Base64.getUrlEncoder().withoutPadding().encodeToString(kids.get(i))).append('"');
        }
        sb.append("],\"type\":\"temporary\"}");
        return sb.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8);
    }

    /** Key ids in init data: 'cenc' (PSSH boxes, version 1 listing them), 'webm' (one key id), 'keyids' (the JSON itself). */
    static List<byte[]> keyIds(byte[] init, String mime) {
        List<byte[]> out = new ArrayList<>();
        if (init == null) return out;
        if ("webm".equals(mime) || "video/webm".equals(mime) || "audio/webm".equals(mime)) {
            if (init.length == 16) out.add(init.clone());
            return out;
        }
        if (init.length > 0 && init[0] == '{') {
            try {
                org.json.JSONArray a = new org.json.JSONObject(new String(init, java.nio.charset.StandardCharsets.UTF_8)).getJSONArray("kids");
                for (int i = 0; i < a.length(); i++) out.add(Base64.getUrlDecoder().decode(a.getString(i)));
            } catch (Exception e) { android.util.Log.w("ClearKey", "init data: " + e); }
            return out;
        }
        int p = 0;
        while (p + 32 <= init.length) {
            int size = u32(init, p);
            if (size < 32 || p + size > init.length || init[p + 4] != 'p' || init[p + 5] != 's' || init[p + 6] != 's' || init[p + 7] != 'h') break;
            int version = init[p + 8] & 0xff;
            if (version > 0) {
                int n = u32(init, p + 28);
                for (int i = 0; i < n && p + 32 + 16 * (i + 1) <= p + size; i++) {
                    byte[] k = new byte[16];
                    System.arraycopy(init, p + 32 + 16 * i, k, 0, 16);
                    out.add(k);
                }
            }
            p += size;
        }
        return out;
    }

    /** The license: {"keys":[{"kty":"oct","kid":"<base64url>","k":"<base64url>"},...]}; the session keeps the keys. */
    public static synchronized void keyResponse(byte[] session, byte[] response) throws Exception {
        HashMap<String, byte[]> keys = SESSIONS.get(hex(session));
        if (keys == null) throw new IllegalStateException("ClearKey: no such session");
        org.json.JSONArray a = new org.json.JSONObject(new String(response, java.nio.charset.StandardCharsets.UTF_8)).getJSONArray("keys");
        for (int i = 0; i < a.length(); i++) {
            org.json.JSONObject k = a.getJSONObject(i);
            keys.put(hex(Base64.getUrlDecoder().decode(k.getString("kid"))), Base64.getUrlDecoder().decode(k.getString("k")));
        }
        android.util.Log.i("ClearKey", a.length() + " key(s) for session " + hex(session));
    }

    public static synchronized HashMap<String, String> keyStatus(byte[] session) {
        HashMap<String, String> m = new HashMap<>();
        HashMap<String, byte[]> keys = SESSIONS.get(hex(session));
        if (keys != null) for (String kid : keys.keySet()) m.put(kid, "USABLE");
        return m;
    }

    static synchronized byte[] key(byte[] session, byte[] kid) {
        HashMap<String, byte[]> keys = session != null ? SESSIONS.get(hex(session)) : null;
        if (keys == null) return null;
        byte[] k = kid != null ? keys.get(hex(kid)) : null;
        if (k == null && keys.size() == 1) k = keys.values().iterator().next();     // one key: whatever the sample names
        return k;
    }

    /**
     * Decrypts one sample in place: subsamples of clear then encrypted bytes. mode 1 'cenc': AES-CTR, one keystream through
     * the sample's encrypted bytes. mode 2 'cbcs'/'cbc1': AES-CBC from the IV in each subsample, encrypt:skip blocks of the
     * pattern (0:0 = all), a partial last block clear. Returns false when the session has no key for the sample.
     */
    public static boolean decrypt(byte[] session, byte[] data, int offset, int numSub, int[] clear, int[] enc, byte[] kid, byte[] iv,
                                  int mode, int encryptBlocks, int skipBlocks) throws Exception {
        byte[] key = key(session, kid);
        if (key == null) return false;
        byte[] iv16 = new byte[16];
        if (iv != null) System.arraycopy(iv, 0, iv16, 0, Math.min(16, iv.length));
        SecretKeySpec k = new SecretKeySpec(key, "AES");
        int p = offset;
        if (mode == 1) {
            Cipher c = Cipher.getInstance("AES/CTR/NoPadding");
            c.init(Cipher.DECRYPT_MODE, k, new IvParameterSpec(iv16));
            for (int i = 0; i < numSub; i++) {
                p += clear != null ? clear[i] : 0;
                int n = enc != null ? enc[i] : 0;
                if (n > 0) { byte[] out = c.update(data, p, n); if (out != null) System.arraycopy(out, 0, data, p, out.length); }
                p += n;
            }
            return true;
        }
        Cipher c = Cipher.getInstance("AES/CBC/NoPadding");
        for (int i = 0; i < numSub; i++) {
            p += clear != null ? clear[i] : 0;
            int n = enc != null ? enc[i] : 0;
            c.init(Cipher.DECRYPT_MODE, k, new IvParameterSpec(iv16));
            int blocks = n / 16, q = p;
            if (encryptBlocks == 0 && skipBlocks == 0) {
                if (blocks > 0) { byte[] out = c.update(data, q, blocks * 16); System.arraycopy(out, 0, data, q, out.length); }
            } else {
                int b = 0;
                while (b < blocks) {
                    int e = Math.min(encryptBlocks, blocks - b);
                    if (e > 0) { byte[] out = c.update(data, q + b * 16, e * 16); System.arraycopy(out, 0, data, q + b * 16, out.length); }
                    b += e + skipBlocks;
                }
            }
            p += n;
        }
        return true;
    }

    private static int u32(byte[] b, int p) { return (b[p] & 0xff) << 24 | (b[p + 1] & 0xff) << 16 | (b[p + 2] & 0xff) << 8 | (b[p + 3] & 0xff); }

    static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder();
        for (byte x : b) sb.append(Character.forDigit((x >> 4) & 15, 16)).append(Character.forDigit(x & 15, 16));
        return sb.toString();
    }
}
