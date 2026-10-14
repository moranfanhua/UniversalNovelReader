package io.github.moranfanhua.unr

import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.github.megatronking.netbare.NetBare
import com.github.megatronking.netbare.NetBareConfig
import com.github.megatronking.netbare.NetBareListener
import com.github.megatronking.netbare.http.*
import com.github.megatronking.netbare.ssl.JKS
import java.io.File
import java.nio.ByteBuffer
import java.security.KeyStore
import java.security.SecureRandom
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.concurrent.Executors

object SessionCapture {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var context: Context
    private var jks: JKS? = null
    private var platform: SessionPlatform? = null
    private var collector: SessionCookies? = null
    private var phase = "idle"
    private var captured: String? = null
    private var message: String? = null
    private var generation = 0
    private var requests = 0
    var onChanged: ((Map<String, Any?>) -> Unit)? = null

    fun attach(application: Application) {
        if (::context.isInitialized) return
        context = application.applicationContext
        // Captured headers must never be printed, including in debug APKs.
        NetBare.get().attachApplication(application, false)
        NetBare.get().registerNetBareListener(object : NetBareListener {
            override fun onServiceStarted() { main.post {
                if (phase == "starting") { phase = "capturing"; publish() }
            } }
            override fun onServiceStopped() { main.post {
                if (phase == "stopping") { phase = "stopped"; publish() }
                else if (phase == "starting" || phase == "capturing") {
                    phase = "error"
                    message = "VPN 已断开，请重新启动辅助抓取"
                    context.stopService(Intent(context, SessionVpnService::class.java))
                    publish()
                }
            } }
        })
    }

    fun snapshot(): Map<String, Any?> = mapOf(
        "phase" to phase, "source" to platform?.id, "requests" to requests,
        "message" to message, "hasCookie" to (captured != null)
    )

    private fun publish() { onChanged?.invoke(snapshot()) }

    fun prepare(done: (Map<String, Any?>?, String?) -> Unit) {
        worker.execute {
            try {
                val store = ensureCertificate()
                val installed = isTrusted(store)
                main.post { done(snapshot() + mapOf("certificateInstalled" to installed), null) }
            } catch (_: Exception) {
                main.post { done(null, "无法准备本机抓包证书，请重试") }
            }
        }
    }

    @Synchronized private fun ensureCertificate(): JKS {
        if (jks == null) {
            val passwordFile = File(context.noBackupFilesDir, "unr-session-ca.password")
            val password = if (passwordFile.exists()) passwordFile.readText() else {
                ByteArray(32).also { SecureRandom().nextBytes(it) }
                    .joinToString("") { "%02x".format(it) }.also { passwordFile.writeText(it) }
            }
            jks = JKS(context, "unr-session-ca", password.toCharArray(), "UNR Session CA", "UNR", "Session", "UNR", "Session")
        }
        val store = jks!!
        val deadline = System.currentTimeMillis() + 15000
        while (System.currentTimeMillis() < deadline) {
            try {
                certificate(store)
                KeyStore.getInstance("PKCS12").apply {
                    store.aliasFile(JKS.KEY_STORE_FILE_EXTENSION).inputStream().use { load(it, File(context.noBackupFilesDir, "unr-session-ca.password").readText().toCharArray()) }
                }
                return store
            } catch (_: Exception) { Thread.sleep(100) }
        }
        throw IllegalStateException("Certificate generation timed out")
    }

    private fun certificate(store: JKS): X509Certificate =
        store.aliasFile(JKS.KEY_PEM_FILE_EXTENSION).inputStream().use {
            CertificateFactory.getInstance("X.509").generateCertificate(it) as X509Certificate
        }

    private fun isTrusted(store: JKS): Boolean {
        val encoded = certificate(store).encoded
        val trust = KeyStore.getInstance("AndroidCAStore").apply { load(null) }
        val installed = trust.aliases().toList().any { trust.getCertificate(it)?.encoded?.contentEquals(encoded) == true }
        val marker = store.aliasFile(JKS.KEY_JKS_FILE_EXTENSION)
        if (installed) marker.writeText("") else marker.delete()
        return installed
    }

    fun publicCertificate(): ByteArray = certificate(checkNotNull(jks)).encoded

    fun start(source: SessionPlatform) {
        check(phase in listOf("idle", "stopped", "error") && !NetBare.get().isActive) { "请先停止当前抓取" }
        val store = checkNotNull(jks) { "请先准备并安装证书" }
        check(store.isInstalled) { "请先安装本机抓包 CA 证书" }
        generation++
        val token = generation
        platform = source
        collector?.clear()
        collector = SessionCookies(source)
        captured = null
        requests = 0
        message = null
        phase = "starting"
        val factory = HttpInterceptorFactory { object : HttpIndexedInterceptor() {
            override fun intercept(chain: HttpRequestChain, buffer: ByteBuffer, index: Int) {
                val requestHeaders = chain.request().requestHeaders()
                val loginRequest = requestHeaders.filterKeys { it.equals("user-agent", true) }.values.flatten().any { it.contains(source.userAgentMarker) }
                if (index == 0 && loginRequest && source.acceptsHost(chain.request().host() ?: "")) {
                    val host = chain.request().host()
                    val headers = requestHeaders.filterKeys { it.equals("cookie", true) }.values.flatten()
                    main.post {
                        if (generation == token && (phase == "capturing" || phase == "starting")) {
                            requests++
                            for (header in headers) {
                                val cookie = collector?.add(host, header)
                                if (cookie != null) {
                                    captured = cookie
                                    phase = "captured"
                                    main.postDelayed({ if (generation == token && phase == "captured") stop(clear = false) }, 2000)
                                    break
                                }
                            }
                            publish()
                        }
                    }
                }
                chain.process(buffer)
            }
            override fun intercept(chain: HttpResponseChain, buffer: ByteBuffer, index: Int) { chain.process(buffer) }
        } }
        val config = NetBareConfig.defaultHttpConfig(store, listOf(factory)).newBuilder()
            .setSession("UNR 会话辅助")
            .addAllowedApplication(context.packageName)
            .addAllowedHost(if (source == SessionPlatform.SFACG) "*.sfacg.com" else "*.fanqienovel.com")
            .addAllowedHost(if (source == SessionPlatform.SFACG) "sfacg.com" else "fanqienovel.com")
            .excludeSelf(false)
            .blockQuic(true)
            .build()
        try {
            NetBare.get().start(config, SessionVpnService::class.java)
            main.postDelayed({
                if (generation == token && phase == "starting") {
                    stop(); phase = "error"; message = "VPN 启动失败，请检查系统 VPN 设置"; publish()
                }
            }, 15000)
            main.postDelayed({
                if (generation == token) {
                    stop(); phase = "error"; message = "抓取已超时，请重新登录后再试"; publish()
                }
            }, 300000)
            publish()
        } catch (_: Exception) {
            stop(); phase = "error"; message = "无法启动 VPN，请检查系统授权"; publish()
            throw IllegalStateException("无法启动 VPN，请检查系统授权")
        }
    }

    fun cookie(source: SessionPlatform): String? = if (platform == source) captured else null

    fun stop(clear: Boolean = true) {
        val active = NetBare.get().isActive || phase == "starting" || phase == "capturing"
        if (clear) {
            generation++
            collector?.clear()
            collector = null
            captured = null
            phase = if (active) "stopping" else "stopped"
            message = null
        }
        if (!context.stopService(Intent(context, SessionVpnService::class.java)) && phase == "stopping") phase = "stopped"
        publish()
    }

    fun serviceDestroyed() {
        if (phase == "stopping") { phase = "stopped"; publish() }
    }
}
