package io.github.moranfanhua.unr

import android.app.Application
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import com.github.megatronking.netbare.NetBare
import com.github.megatronking.netbare.NetBareConfig
import com.github.megatronking.netbare.NetBareListener
import com.github.megatronking.netbare.http.*
import com.github.megatronking.netbare.ssl.JKS
import java.io.File
import java.nio.ByteBuffer
import java.net.Inet4Address
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
        com.github.megatronking.netbare.NetBareLog.setTransportDebug(
            application.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0)
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
        check(context.packageManager.getLaunchIntentForPackage(source.appPackage) != null) { "请先安装${source.title}官方 App" }
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val network = connectivity.activeNetwork?.takeIf {
            connectivity.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == false
        } ?: connectivity.allNetworks.firstOrNull {
            val capabilities = connectivity.getNetworkCapabilities(it)
            capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true && !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        }
        val dnsServers = network?.let { connectivity.getLinkProperties(it)?.dnsServers }
            .orEmpty().filterIsInstance<Inet4Address>().mapNotNull { it.hostAddress }
        check(dnsServers.isNotEmpty()) { "未取得系统 IPv4 DNS，请检查当前网络" }
        generation++
        val token = generation
        platform = source
        collector?.clear()
        collector = SessionCookies(source)
        captured = null
        requests = 0
        message = null
        com.github.megatronking.netbare.ssl.SSLWhiteList.clear()
        phase = "starting"
        com.github.megatronking.netbare.NetBareLog.setTlsHandshakeFailureListener { main.post {
            if (generation == token && phase in listOf("starting", "capturing")) {
                stop()
                phase = "error"
                message = "官方 App 的 HTTPS 握手失败，可能不信任本机 CA 或启用了证书校验。VPN 已停止；普通手机无法仅靠安装用户 CA 解除此限制。"
                publish()
            }
        } }
        fun collectHeaders(host: String, headers: List<String>, response: Boolean) {
            if (!source.acceptsAppHost(host)) return
            main.post {
                if (generation == token && phase in listOf("capturing", "starting")) {
                    if (!response) requests++
                    for (header in headers) {
                        val cookie = if (response) collector?.addAppSetCookie(host, header) else collector?.addApp(host, header)
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
        val factory = HttpInterceptorFactory { object : HttpIndexedInterceptor() {
            override fun intercept(chain: HttpRequestChain, buffer: ByteBuffer, index: Int) {
                val requestHeaders = chain.request().requestHeaders()
                if (index == 0) {
                    val headers = requestHeaders.filterKeys { it.equals("cookie", true) }.values.flatten()
                    collectHeaders(chain.request().host() ?: "", headers, false)
                }
                chain.process(buffer)
            }
            override fun intercept(chain: HttpResponseChain, buffer: ByteBuffer, index: Int) {
                if (index == 0) {
                    val headers = chain.response().responseHeaders().filterKeys { it.equals("set-cookie", true) }.values.flatten()
                    collectHeaders(chain.response().host() ?: "", headers, true)
                }
                chain.process(buffer)
            }
        } }
        val builder = NetBareConfig.defaultHttpConfig(store, listOf(factory)).newBuilder()
            .setSession("UNR 会话辅助")
            .addAllowedApplication(source.appPackage)
            .excludeSelf(false)
            .blockQuic(true)
        source.appHosts.forEach { builder.addAllowedHost(it); builder.addAllowedHost("*.$it") }
        dnsServers.forEach { builder.addDnsServer(it) }
        val config = builder.build()
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

    fun takeCookie(source: SessionPlatform): String? {
        val result = cookie(source)
        if (result != null) stop()
        return result
    }

    fun stop(clear: Boolean = true) {
        com.github.megatronking.netbare.NetBareLog.setTlsHandshakeFailureListener(null)
        val active = NetBare.get().isActive || phase == "starting" || phase == "capturing"
        if (clear) {
            generation++
            collector?.clear()
            collector = null
            captured = null
            phase = if (active) "stopping" else "stopped"
            message = null
        }
        if (!SessionVpnService.stopRunning()) {
            context.stopService(Intent(context, SessionVpnService::class.java))
            if (phase == "stopping") phase = "stopped"
        }
        publish()
    }

    fun serviceDestroyed() {
        if (phase == "stopping") { phase = "stopped"; publish() }
    }
}
