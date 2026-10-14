package io.github.moranfanhua.unr

import android.view.KeyEvent
import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.provider.MediaStore
import android.provider.Settings
import android.security.KeyChain
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel

class MainActivity : FlutterActivity() {
    private var volumeChannel: MethodChannel? = null
    private var volumeKeysEnabled = false
    private val consumedKeys = mutableSetOf<Int>()
    private var sessionChannel: MethodChannel? = null
    private var captureEvents: EventChannel? = null
    private var loginResult: MethodChannel.Result? = null
    private var vpnResult: MethodChannel.Result? = null
    private var vpnPlatform: SessionPlatform? = null
    private var helperGeneration = 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        SessionCapture.attach(application)
        sessionChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "unr/session_helper").also { channel ->
            channel.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "prepare" -> SessionCapture.prepare { state, error ->
                            if (error == null) result.success(state) else result.error("certificate", error, null)
                        }
                        "status" -> result.success(SessionCapture.snapshot())
                        "installCertificate" -> {
                            val certificate = SessionCapture.publicCertificate()
                            if (Build.VERSION.SDK_INT >= 30) {
                                val values = ContentValues().apply {
                                    put(MediaStore.Downloads.DISPLAY_NAME, "UNR-session-CA.cer")
                                    put(MediaStore.Downloads.MIME_TYPE, "application/x-x509-ca-cert")
                                    put(MediaStore.Downloads.IS_PENDING, 1)
                                }
                                val uri = checkNotNull(contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values))
                                try {
                                    checkNotNull(contentResolver.openOutputStream(uri)).use { it.write(certificate) }
                                    contentResolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
                                } catch (e: Exception) { contentResolver.delete(uri, null, null); throw e }
                                val name = contentResolver.query(uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null)?.use {
                                    if (it.moveToFirst()) it.getString(0) else "UNR-session-CA.cer"
                                } ?: "UNR-session-CA.cer"
                                result.success(name)
                            } else {
                                startActivity(KeyChain.createInstallIntent().putExtra(KeyChain.EXTRA_CERTIFICATE, certificate).putExtra(KeyChain.EXTRA_NAME, "UNR Session CA"))
                                result.success(null)
                            }
                        }
                        "certificateSettings" -> {
                            startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS)); result.success(null)
                        }
                        "start" -> {
                            check(vpnResult == null) { "VPN 授权正在进行" }
                            val generation = ++helperGeneration
                            val source = SessionPlatform.fromId(call.argument<String>("source"))
                            SessionCapture.prepare { state, error ->
                                if (generation != helperGeneration || isDestroyed || isFinishing) {
                                    result.error("cancelled", "会话辅助已关闭", null)
                                } else if (error != null || state?.get("certificateInstalled") != true) {
                                    result.error("certificate", error ?: "请先安装本机抓包 CA 证书", null)
                                } else {
                                    requestVpn(source, result)
                                }
                            }
                        }
                        "stop" -> {
                            helperGeneration++
                            SessionCapture.stop()
                            vpnResult?.error("cancelled", "已取消 VPN 授权", null)
                            vpnResult = null; vpnPlatform = null
                            result.success(null)
                        }
                        "openLogin" -> {
                            check(loginResult == null) { "网页登录正在进行" }
                            val source = SessionPlatform.fromId(call.argument<String>("source"))
                            if (call.argument<Boolean>("vpn") == true) {
                                val state = SessionCapture.snapshot()
                                check(state["source"] == source.id && state["phase"] in listOf("capturing", "captured")) { "请先启动对应平台的 VPN 辅助" }
                            } else SessionCapture.stop()
                            loginResult = result
                            startActivityForResult(Intent(this, WebLoginActivity::class.java).putExtra("source", source.id), 5134)
                        }
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) { result.error("session_helper", "无法完成会话辅助操作，请重试", null) }
            }
        }
        captureEvents = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "unr/session_helper/events").also {
            it.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    SessionCapture.onChanged = { state -> events.success(state) }
                    events.success(SessionCapture.snapshot())
                }
                override fun onCancel(arguments: Any?) { SessionCapture.onChanged = null }
            })
        }
        volumeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "unr/reader_volume_keys").also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "setEnabled") {
                    volumeKeysEnabled = call.arguments == true
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    private fun requestVpn(source: SessionPlatform, result: MethodChannel.Result, notifications: Boolean = true) {
        try {
            if (notifications && Build.VERSION.SDK_INT >= 33 &&
                checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                vpnResult = result; vpnPlatform = source
                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 5135)
                return
            }
            val permission = VpnService.prepare(this)
            if (permission == null) {
                SessionCapture.start(source)
                result.success(SessionCapture.snapshot())
            } else {
                vpnResult = result; vpnPlatform = source
                startActivityForResult(permission, 5133)
            }
        } catch (_: Exception) {
            vpnResult = null; vpnPlatform = null
            result.error("vpn", "无法启动 VPN，请检查授权与运行状态", null)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 5135) {
            val result = vpnResult
            val source = vpnPlatform
            vpnResult = null; vpnPlatform = null
            if (result != null && source != null) requestVpn(source, result, notifications = false)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 5133) {
            val result = vpnResult
            val source = vpnPlatform
            vpnResult = null; vpnPlatform = null
            if (resultCode == Activity.RESULT_OK && source != null) {
                try { SessionCapture.start(source); result?.success(SessionCapture.snapshot()) }
                catch (_: Exception) { result?.error("vpn", "无法启动 VPN，请检查授权与运行状态", null) }
            } else result?.error("cancelled", "未授权 VPN，网页登录仍可直接使用", null)
        } else if (requestCode == 5134) {
            loginResult?.success(if (resultCode == Activity.RESULT_OK) data?.getStringExtra("cookie") else null)
            loginResult = null
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val key = event.keyCode
        if (key != KeyEvent.KEYCODE_VOLUME_UP && key != KeyEvent.KEYCODE_VOLUME_DOWN) {
            return super.dispatchKeyEvent(event)
        }
        if (event.action == KeyEvent.ACTION_UP && consumedKeys.remove(key)) {
            return true
        }
        if (event.action == KeyEvent.ACTION_DOWN) {
            // Never turn repeatedly while holding a key, or start consuming a
            // press that originally belonged to the system volume controls.
            if (key in consumedKeys) return true
            if (volumeKeysEnabled && hasWindowFocus() && event.repeatCount == 0) {
                consumedKeys.add(key)
                volumeChannel?.invokeMethod("turnPage", if (key == KeyEvent.KEYCODE_VOLUME_DOWN) 1 else -1)
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onPause() {
        volumeKeysEnabled = false
        consumedKeys.clear()
        super.onPause()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        helperGeneration++
        SessionCapture.stop()
        SessionCapture.onChanged = null
        sessionChannel?.setMethodCallHandler(null)
        captureEvents?.setStreamHandler(null)
        sessionChannel = null; captureEvents = null
        loginResult?.success(null); loginResult = null
        vpnResult?.error("cancelled", "会话辅助已关闭", null); vpnResult = null
        volumeKeysEnabled = false
        consumedKeys.clear()
        volumeChannel?.setMethodCallHandler(null)
        volumeChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
