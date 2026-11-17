package com.lemon.panel;
import android.app.Activity;
import android.os.Bundle;
import android.view.View;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.webkit.WebSettings;
import android.graphics.Color;
public class MainActivity extends Activity {
    private WebView w;
    @Override protected void onCreate(Bundle b){
        super.onCreate(b);
        getWindow().setStatusBarColor(Color.parseColor("#0B0F19"));
        getWindow().setNavigationBarColor(Color.parseColor("#0B0F19"));
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
        w=new WebView(this);
        setContentView(w);
        WebSettings s=w.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setUseWideViewPort(true);
        s.setLoadWithOverviewMode(true);
        s.setSupportZoom(false);
        s.setBuiltInZoomControls(false);
        s.setDisplayZoomControls(false);
        s.setTextZoom(100);
        s.setCacheMode(WebSettings.LOAD_NO_CACHE);
        w.setBackgroundColor(Color.parseColor("#0B0F19"));
        w.setWebViewClient(new WebViewClient());
        w.clearCache(true);
        w.loadUrl("http://127.0.0.1:8794/");
    }
    @Override public void onBackPressed(){ if(w!=null&&w.canGoBack()) w.goBack(); else super.onBackPressed(); }
    @Override protected void onDestroy(){ if(w!=null){ w.destroy(); } super.onDestroy(); }
}
