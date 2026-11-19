// Started as a tools/compat/genstubs.py stub; the state, the custom actions and their builder are written by hand.
package android.media.session;

@SuppressWarnings({"unchecked", "rawtypes", "deprecation"})
public final class PlaybackState implements android.os.Parcelable {
    private final java.util.HashMap<String, Object> huskProps = new java.util.HashMap<>();
    public static final long ACTION_FAST_FORWARD = 64L;
    public static final long ACTION_PAUSE = 2L;
    public static final long ACTION_PLAY = 4L;
    public static final long ACTION_PLAY_FROM_MEDIA_ID = 1024L;
    public static final long ACTION_PLAY_FROM_SEARCH = 2048L;
    public static final long ACTION_PLAY_FROM_URI = 8192L;
    public static final long ACTION_PLAY_PAUSE = 512L;
    public static final long ACTION_PREPARE = 16384L;
    public static final long ACTION_PREPARE_FROM_MEDIA_ID = 32768L;
    public static final long ACTION_PREPARE_FROM_SEARCH = 65536L;
    public static final long ACTION_PREPARE_FROM_URI = 131072L;
    public static final long ACTION_REWIND = 8L;
    public static final long ACTION_SEEK_TO = 256L;
    public static final long ACTION_SET_PLAYBACK_SPEED = 4194304L;
    public static final long ACTION_SET_RATING = 128L;
    public static final long ACTION_SKIP_TO_NEXT = 32L;
    public static final long ACTION_SKIP_TO_PREVIOUS = 16L;
    public static final long ACTION_SKIP_TO_QUEUE_ITEM = 4096L;
    public static final long ACTION_STOP = 1L;
    public static android.os.Parcelable.Creator CREATOR = husk.StubCreator.of(PlaybackState.class);
    public static final long PLAYBACK_POSITION_UNKNOWN = -1L;
    public static final int STATE_BUFFERING = 6;
    public static final int STATE_CONNECTING = 8;
    public static final int STATE_ERROR = 7;
    public static final int STATE_FAST_FORWARDING = 4;
    public static final int STATE_NONE = 0;
    public static final int STATE_PAUSED = 2;
    public static final int STATE_PLAYING = 3;
    public static final int STATE_REWINDING = 5;
    public static final int STATE_SKIPPING_TO_NEXT = 10;
    public static final int STATE_SKIPPING_TO_PREVIOUS = 9;
    public static final int STATE_SKIPPING_TO_QUEUE_ITEM = 11;
    public static final int STATE_STOPPED = 1;
    public int describeContents() { return 0; }
    public long getActions() { return (huskProps.get("Actions") instanceof Long ? (Long) huskProps.get("Actions") : 0L); }
    public long getActiveQueueItemId() { return (huskProps.get("ActiveQueueItemId") instanceof Long ? (Long) huskProps.get("ActiveQueueItemId") : 0L); }
    public long getBufferedPosition() { return (huskProps.get("BufferedPosition") instanceof Long ? (Long) huskProps.get("BufferedPosition") : 0L); }
    public java.util.List getCustomActions() { return (huskProps.get("CustomActions") != null ? (java.util.List) huskProps.get("CustomActions") : new java.util.ArrayList()); }
    public java.lang.CharSequence getErrorMessage() { return (java.lang.CharSequence) huskProps.get("ErrorMessage"); }
    public android.os.Bundle getExtras() { return (android.os.Bundle) huskProps.get("Extras"); }
    public long getLastPositionUpdateTime() { return (huskProps.get("LastPositionUpdateTime") instanceof Long ? (Long) huskProps.get("LastPositionUpdateTime") : 0L); }
    public float getPlaybackSpeed() { return (huskProps.get("PlaybackSpeed") instanceof Float ? (Float) huskProps.get("PlaybackSpeed") : 0f); }
    public long getPosition() { return (huskProps.get("Position") instanceof Long ? (Long) huskProps.get("Position") : 0L); }
    public int getState() { return (huskProps.get("State") instanceof Integer ? (Integer) huskProps.get("State") : 0); }
    public boolean isActive() { return (huskProps.get("Active") instanceof Boolean ? (Boolean) huskProps.get("Active") : false); }
    public void writeToParcel(android.os.Parcel p0, int p1) {}
    protected PlaybackState() {}
    public static final class Builder {
        private final java.util.HashMap<String, Object> huskProps = new java.util.HashMap<>();
        public Builder() {}
        public Builder(android.media.session.PlaybackState p0) { if (p0 != null) huskProps.putAll(p0.huskProps); }
        public android.media.session.PlaybackState.Builder addCustomAction(android.media.session.PlaybackState.CustomAction p0) {
            if (p0 == null) throw new IllegalArgumentException("You may not add a null CustomAction to PlaybackState.");
            java.util.List l = (java.util.List) huskProps.get("CustomActions");
            l = l == null ? new java.util.ArrayList() : new java.util.ArrayList(l);   // a copy: states already built keep their own list
            l.add(p0); huskProps.put("CustomActions", l); return this;
        }
        public android.media.session.PlaybackState.Builder addCustomAction(java.lang.String p0, java.lang.String p1, int p2) { return addCustomAction(new CustomAction(p0, p1, p2, null)); }
        public android.media.session.PlaybackState build() { android.media.session.PlaybackState x = new android.media.session.PlaybackState(); x.huskProps.putAll(huskProps); return x; }
        public android.media.session.PlaybackState.Builder setActions(long p0) { huskProps.put("Actions", Long.valueOf(p0)); return this; }
        public android.media.session.PlaybackState.Builder setActiveQueueItemId(long p0) { huskProps.put("ActiveQueueItemId", Long.valueOf(p0)); return this; }
        public android.media.session.PlaybackState.Builder setBufferedPosition(long p0) { huskProps.put("BufferedPosition", Long.valueOf(p0)); return this; }
        public android.media.session.PlaybackState.Builder setErrorMessage(java.lang.CharSequence p0) { huskProps.put("ErrorMessage", p0); return this; }
        public android.media.session.PlaybackState.Builder setExtras(android.os.Bundle p0) { huskProps.put("Extras", p0); return this; }
        public android.media.session.PlaybackState.Builder setState(int p0, long p1, float p2) { return setState(p0, p1, p2, android.os.SystemClock.elapsedRealtime()); }
        public android.media.session.PlaybackState.Builder setState(int p0, long p1, float p2, long p3) {
            huskProps.put("State", Integer.valueOf(p0)); huskProps.put("Position", Long.valueOf(p1));
            huskProps.put("PlaybackSpeed", Float.valueOf(p2)); huskProps.put("LastPositionUpdateTime", Long.valueOf(p3)); return this;
        }
    }
    public static final class CustomAction implements android.os.Parcelable {
        public static final android.os.Parcelable.Creator<CustomAction> CREATOR = husk.StubCreator.of(CustomAction.class);
        private final String mAction; private final CharSequence mName; private final int mIcon; private final android.os.Bundle mExtras;
        private CustomAction(String action, CharSequence name, int icon, android.os.Bundle extras) { mAction = action; mName = name; mIcon = icon; mExtras = extras; }
        public String getAction() { return mAction; }
        public CharSequence getName() { return mName; }
        public int getIcon() { return mIcon; }
        public android.os.Bundle getExtras() { return mExtras; }
        public int describeContents() { return 0; }
        public void writeToParcel(android.os.Parcel dest, int flags) {}
        public String toString() { return "Action:mName='" + mName + ", mIcon=" + mIcon + ", mExtras=" + mExtras; }
        public static final class Builder {
            private final String mAction; private final CharSequence mName; private final int mIcon; private android.os.Bundle mExtras;
            public Builder(String action, CharSequence name, int icon) {
                if (android.text.TextUtils.isEmpty(action)) throw new IllegalArgumentException("You must specify an action to build a CustomAction.");
                if (android.text.TextUtils.isEmpty(name)) throw new IllegalArgumentException("You must specify a name to build a CustomAction.");
                if (icon == 0) throw new IllegalArgumentException("You must specify an icon resource id to build a CustomAction.");
                mAction = action; mName = name; mIcon = icon;
            }
            public Builder setExtras(android.os.Bundle extras) { mExtras = extras; return this; }
            public CustomAction build() { return new CustomAction(mAction, mName, mIcon, mExtras); }
        }
    }
}
