package org.kartdrift.offline.nativeapp;

import android.app.Activity;
import android.os.Bundle;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.opengl.GLSurfaceView;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.opengles.GL10;

public final class RaceActivity extends Activity implements GLSurfaceView.Renderer {
    static { System.loadLibrary("kartdrift"); }
    private static native void nativeCreate();
    private static native void nativeResize(int width,int height);
    private static native String nativeFrame();
    private static native void nativeAction(int action,boolean down);
    private static native float nativeFinishTime();
    private GLSurfaceView surface;
    private TextView hud;
    private int frames,mode;
    private boolean savedFinish;
    @Override public void onCreate(Bundle state){
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY|View.SYSTEM_UI_FLAG_FULLSCREEN|View.SYSTEM_UI_FLAG_HIDE_NAVIGATION);
        FrameLayout root=new FrameLayout(this);
        surface=new GLSurfaceView(this);surface.setEGLContextClientVersion(3);surface.setPreserveEGLContextOnPause(true);surface.setRenderer(this);root.addView(surface);
        hud=new TextView(this);hud.setTextColor(Color.WHITE);hud.setTextSize(16);hud.setTypeface(Typeface.MONOSPACE,Typeface.BOLD);hud.setPadding(dp(10),dp(4),dp(10),dp(4));hud.setBackgroundColor(0x99000000);
        FrameLayout.LayoutParams hp=new FrameLayout.LayoutParams(-1,dp(86),Gravity.TOP);hp.setMargins(dp(12),dp(10),dp(12),0);root.addView(hud,hp);
        LinearLayout menu=new LinearLayout(this);String[] names={"竞速","道具","练习","重开","救援","暂停","自动测试"};
        for(int i=0;i<names.length;i++){final int action=i;Button b=button(names[i]);b.setTextSize(13);b.setOnClickListener(v->{if(action<3){mode=action;getPreferences(0).edit().putInt("mode",mode).apply();}if(action<4)savedFinish=false;surface.queueEvent(()->nativeAction(action,true));});menu.addView(b,new LinearLayout.LayoutParams(dp(78),dp(42)));}
        FrameLayout.LayoutParams mp=new FrameLayout.LayoutParams(-2,dp(42),Gravity.TOP|Gravity.LEFT);mp.setMargins(dp(12),dp(102),0,0);root.addView(menu,mp);
        addControl(root,"◀",7,Gravity.BOTTOM|Gravity.LEFT,12,16,78,78);
        addControl(root,"▶",8,Gravity.BOTTOM|Gravity.LEFT,102,16,78,78);
        addControl(root,"刹车",11,Gravity.BOTTOM|Gravity.LEFT,40,108,100,48);
        addControl(root,"漂移",9,Gravity.BOTTOM|Gravity.RIGHT,12,16,88,88);
        addControl(root,"氮气 / 道具",10,Gravity.BOTTOM|Gravity.RIGHT,112,16,132,78);
        mode=getPreferences(0).getInt("mode",0);setContentView(root);
    }
    private int dp(int n){return Math.round(n*getResources().getDisplayMetrics().density);}
    private Button button(String title){Button b=new Button(this);b.setText(title);b.setTextColor(Color.WHITE);b.setAllCaps(false);b.setTypeface(null,Typeface.BOLD);b.setPadding(0,0,0,0);GradientDrawable bg=new GradientDrawable();bg.setColor(0xc0091a2f);bg.setCornerRadius(dp(14));bg.setStroke(dp(1),0x55ffffff);b.setBackground(bg);return b;}
    private void addControl(FrameLayout root,String name,int action,int gravity,int side,int bottom,int w,int h){
        Button b=button(name);b.setTextSize(19);b.setOnTouchListener((v,e)->{int a=e.getActionMasked();if(a==MotionEvent.ACTION_DOWN)surface.queueEvent(()->nativeAction(action,true));if(a==MotionEvent.ACTION_UP||a==MotionEvent.ACTION_CANCEL){surface.queueEvent(()->nativeAction(action,false));v.performClick();}return true;});
        FrameLayout.LayoutParams p=new FrameLayout.LayoutParams(dp(w),dp(h),gravity);p.bottomMargin=dp(bottom);if((gravity&Gravity.HORIZONTAL_GRAVITY_MASK)==Gravity.RIGHT)p.rightMargin=dp(side);else p.leftMargin=dp(side);root.addView(b,p);
    }
    @Override public void onSurfaceCreated(GL10 gl,EGLConfig config){nativeCreate();nativeAction(mode,true);}
    @Override public void onSurfaceChanged(GL10 gl,int w,int h){nativeResize(w,h);}
    @Override public void onDrawFrame(GL10 gl){String text=nativeFrame();if(++frames%6==0){float time=nativeFinishTime();runOnUiThread(()->{hud.setText(text);if(time>0&&!savedFinish){savedFinish=true;String key=mode==1?"bestItem":"bestSpeed";float best=getPreferences(0).getFloat(key,0);if(best<=0||time<best)getPreferences(0).edit().putFloat(key,time).apply();}});}}
    @Override public void onPause(){surface.queueEvent(()->nativeAction(12,true));surface.onPause();super.onPause();}
    @Override public void onResume(){super.onResume();surface.onResume();}
}
