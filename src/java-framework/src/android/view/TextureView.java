package android.view;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.Rect;
import android.graphics.SurfaceTexture;

/**
 * A view showing a SurfaceTexture's frames (video players, camera previews, GL renderers that draw off-screen). The texture is
 * made once the view is attached and sized; each frame posted to it redraws the view, scaled to its bounds and then transformed
 * by setTransform, as Android composites the layer.
 */
public class TextureView extends View {
    public interface SurfaceTextureListener {
        void onSurfaceTextureAvailable(SurfaceTexture t, int w, int h);
        void onSurfaceTextureSizeChanged(SurfaceTexture t, int w, int h);
        boolean onSurfaceTextureDestroyed(SurfaceTexture t);
        void onSurfaceTextureUpdated(SurfaceTexture t);
    }
    private SurfaceTexture mTexture;
    private SurfaceTextureListener mListener;
    private boolean mOpaque = true, mAvailable;
    private final Matrix mMatrix = new Matrix();
    private Paint mLayerPaint;
    private final Paint mPaint = new Paint(Paint.FILTER_BITMAP_FLAG);
    private Bitmap mShown;
    private Surface mCanvasSurface;

    /* The video shown by iOS itself under the screen (husk.AvPlayer: a player drawing into this view's texture): this view leaves a
       see-through hole and says where it is, as SurfaceView does -- no frame is copied or drawn here. */
    private volatile SurfaceView.VideoLayer mLayer;
    private boolean mLayerVisible;
    private int mLayerX, mLayerY, mLayerW = -1, mLayerH;
    private final Paint mClear = new Paint();
    { mClear.setXfermode(new android.graphics.PorterDuffXfermode(android.graphics.PorterDuff.Mode.CLEAR)); }
    /** Whether the iOS video layer can stand for this view: it shows the picture untransformed (setTransform not used). */
    public boolean huskLayerable() { return mMatrix.isIdentity(); }
    public void huskSetVideoLayer(SurfaceView.VideoLayer l) {
        SurfaceView.VideoLayer old = mLayer;
        mLayer = l;
        if (old != null && old != l) old.frame(0, 0, 0, 0, false);
        mLayerVisible = false; mLayerW = -1;
        post(this::updateLayer);
        postInvalidate();
    }
    private void updateLayer() {
        SurfaceView.VideoLayer l = mLayer;
        if (l == null) return;
        boolean visible = isAttachedToWindow() && isShown() && getWindowVisibility() == VISIBLE && getWidth() > 0 && getHeight() > 0;
        int[] loc = new int[2];
        if (visible) getLocationOnScreen(loc);
        if (visible == mLayerVisible && (!visible || (loc[0] == mLayerX && loc[1] == mLayerY && getWidth() == mLayerW && getHeight() == mLayerH))) return;
        mLayerVisible = visible; mLayerX = loc[0]; mLayerY = loc[1]; mLayerW = getWidth(); mLayerH = getHeight();
        l.frame(loc[0], loc[1], getWidth(), getHeight(), visible);
    }
    @Override public void layout(int l, int t, int r, int b) { super.layout(l, t, r, b); if (mLayer != null) post(this::updateLayer); }
    @Override protected void onScrollChanged(int l, int t, int ol, int ot) { super.onScrollChanged(l, t, ol, ot); updateLayer(); }
    @Override protected void onVisibilityChanged(View changed, int v) { super.onVisibilityChanged(changed, v); updateLayer(); }
    @Override protected void onWindowVisibilityChanged(int v) { super.onWindowVisibilityChanged(v); updateLayer(); }
    public TextureView(android.content.Context c) { super(c); }
    public TextureView(android.content.Context c, android.util.AttributeSet a) { super(c, a); }
    public TextureView(android.content.Context c, android.util.AttributeSet a, int s) { super(c, a, s); }
    public TextureView(android.content.Context c, android.util.AttributeSet a, int s, int r) { super(c, a, s, r); }

    public SurfaceTexture getSurfaceTexture() { return mTexture; }
    public void setSurfaceTexture(SurfaceTexture t) {
        if (t == null) throw new NullPointerException("surfaceTexture must not be null");
        if (t == mTexture) return;
        if (t.isReleased()) throw new IllegalArgumentException("Cannot setSurfaceTexture to a released SurfaceTexture");
        if (mTexture != null) mTexture.huskView = null;
        mTexture = t; t.huskView = this;
        if (getWidth() > 0 && getHeight() > 0) t.setDefaultBufferSize(getWidth(), getHeight());
        mAvailable = isAttachedToWindow() && getWidth() > 0;
        invalidate();
    }
    public SurfaceTextureListener getSurfaceTextureListener() { return mListener; }
    public void setSurfaceTextureListener(SurfaceTextureListener l) { mListener = l; }
    public boolean isAvailable() { return mTexture != null && mAvailable; }
    public boolean isOpaque() { return mOpaque; }
    public void setOpaque(boolean o) { mOpaque = o; invalidate(); }
    public void setTransform(Matrix m) {
        mMatrix.set(m);
        if (m != null && !m.isIdentity()) android.util.Log.d("TextureView", "transform " + m);
        invalidate();
    }
    public Matrix getTransform(Matrix m) { if (m == null) m = new Matrix(); m.set(mMatrix); return m; }
    public void setLayerPaint(Paint p) { mLayerPaint = p; invalidate(); }
    public void setLayerType(int type, Paint p) { mLayerPaint = p; }
    public int getLayerType() { return LAYER_TYPE_HARDWARE; }
    public void buildLayer() {}
    public CharSequence getAccessibilityClassName() { return TextureView.class.getName(); }

    private void ensureTexture() {
        int w = getWidth(), h = getHeight();
        if (!isAttachedToWindow() || w <= 0 || h <= 0) return;
        if (mTexture == null) { mTexture = new SurfaceTexture(false); mTexture.huskView = this; }
        if (!mAvailable) {
            mAvailable = true;
            int[] sz = mTexture.huskSize();
            if (sz[0] <= 0 || sz[1] <= 0) mTexture.setDefaultBufferSize(w, h);
            if (mListener != null) mListener.onSurfaceTextureAvailable(mTexture, w, h);
        }
    }
    @Override protected void onAttachedToWindow() { super.onAttachedToWindow(); post(this::ensureTexture); }
    @Override protected void onSizeChanged(int w, int h, int ow, int oh) {
        super.onSizeChanged(w, h, ow, oh);
        if (mTexture != null && mAvailable) {
            mTexture.setDefaultBufferSize(w, h);
            if (mListener != null) mListener.onSurfaceTextureSizeChanged(mTexture, w, h);
        } else post(this::ensureTexture);
    }
    @Override protected void onDetachedFromWindow() {
        super.onDetachedFromWindow();
        if (mTexture != null && mAvailable) {
            mAvailable = false;
            boolean release = mListener == null || mListener.onSurfaceTextureDestroyed(mTexture);
            if (release) { mTexture.release(); mTexture.huskView = null; mTexture = null; }
        }
        if (mCanvasSurface != null) { mCanvasSurface.release(); mCanvasSurface = null; }
        mShown = null;
        updateLayer();
    }
    @Override public void draw(Canvas c) {
        super.draw(c);
        if (mLayer != null) {                               /* iOS shows the video under the screen: a hole for it */
            c.drawRect(0, 0, getWidth(), getHeight(), mClear);
            updateLayer();
            return;
        }
        SurfaceTexture t = mTexture;
        Bitmap f = t != null ? t.huskFront() : null;
        if (f != null) {
            if (f != mShown) { mShown = f; if (mListener != null) mListener.onSurfaceTextureUpdated(t); }
            int save = c.save();
            c.concat(mMatrix);
            Paint p = mLayerPaint != null ? mLayerPaint : mPaint;
            c.drawBitmap(f, null, new Rect(0, 0, getWidth(), getHeight()), p);
            c.restoreToCount(save);
        }
    }
    public Bitmap getBitmap() { return getWidth() > 0 && getHeight() > 0 ? getBitmap(getWidth(), getHeight()) : null; }
    public Bitmap getBitmap(int w, int h) { return isAvailable() && w > 0 && h > 0 ? getBitmap(Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)) : null; }
    public Bitmap getBitmap(Bitmap b) {
        Bitmap f = mTexture != null ? mTexture.huskFront() : null;
        if (b != null && f != null) { Canvas c = new Canvas(b); c.drawBitmap(f, null, new Rect(0, 0, b.getWidth(), b.getHeight()), mPaint); }
        return b;
    }
    public Canvas lockCanvas() { return lockCanvas(null); }
    public Canvas lockCanvas(Rect dirty) {
        if (!isAvailable()) return null;
        if (mCanvasSurface == null) mCanvasSurface = new Surface(mTexture);
        return mCanvasSurface.lockCanvas(dirty);
    }
    public void unlockCanvasAndPost(Canvas c) { if (mCanvasSurface != null) mCanvasSurface.unlockCanvasAndPost(c); }
}
