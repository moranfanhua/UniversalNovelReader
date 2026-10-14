package io.github.moranfanhua.unr

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import java.net.URI

class WebLoginActivity : Activity() {
    private lateinit var web: WebView
    private lateinit var platform: SessionPlatform
    private var finishingLogin = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        platform = try { SessionPlatform.fromId(intent.getStringExtra("source")) } catch (_: Exception) { finish(); return }
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(Color.WHITE) }
        val bar = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setPadding(8, 4, 8, 4) }
        val back = Button(this).apply { text = "返回"; setOnClickListener { finish() } }
        val host = TextView(this).apply { text = platform.title + "官网登录"; setTextColor(Color.BLACK); setPadding(8, 0, 8, 0) }
        val done = Button(this).apply { text = "完成并验证"; setOnClickListener { completeLogin() } }
        bar.addView(back)
        bar.addView(host, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        bar.addView(done)
        layout.addView(bar)
        web = WebView(this)
        @Suppress("SetJavaScriptEnabled")
        web.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            setSupportMultipleWindows(false)
            useWideViewPort = true
            loadWithOverviewMode = true
            builtInZoomControls = true
            displayZoomControls = false
            if (platform == SessionPlatform.FANQIE) {
                userAgentString = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
            }
        }
        web.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = !platform.acceptsNavigation(request.url.toString())
            @Deprecated("Legacy Android WebView callback")
            override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean = !platform.acceptsNavigation(url)
            override fun onPageFinished(view: WebView, url: String) {
                host.text = try { URI(url).host } catch (_: Exception) { platform.title }
            }
            // Keep WebView's default rejection of invalid TLS certificates.
        }
        layout.addView(web, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(layout)
        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            setAcceptThirdPartyCookies(web, true)
            removeAllCookies {
                if (!isFinishing && !isDestroyed) web.loadUrl(platform.loginUrl)
            }
        }
    }

    private fun completeLogin() {
        if (finishingLogin) return
        val collector = SessionCookies(platform)
        var cookie: String? = null
        for (url in platform.cookieUrls) {
            cookie = collector.add(URI(url).host, CookieManager.getInstance().getCookie(url) ?: "") ?: cookie
        }
        cookie = cookie ?: SessionCapture.cookie(platform)
        collector.clear()
        if (cookie == null) {
            Toast.makeText(this, "尚未取得登录会话，请先在官网完成登录", Toast.LENGTH_LONG).show()
            return
        }
        finishingLogin = true
        val result = Intent().putExtra("cookie", cookie).putExtra("source", platform.id)
        CookieManager.getInstance().removeAllCookies {
            CookieManager.getInstance().flush()
            setResult(RESULT_OK, result)
            finish()
        }
    }

    override fun onDestroy() {
        if (::web.isInitialized) {
            web.stopLoading()
            web.clearCache(true)
            web.clearHistory()
            web.destroy()
            CookieManager.getInstance().removeAllCookies { CookieManager.getInstance().flush() }
            WebStorage.getInstance().deleteAllData()
        }
        SessionCapture.stop()
        super.onDestroy()
    }
}
