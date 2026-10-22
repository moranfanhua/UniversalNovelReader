package io.github.moranfanhua.unr

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.unr.research.qimeiclient.AndroidQimeiClient
import java.util.concurrent.Executors

/** Private values cross only the in-process channel, never Android logs. */
class QidianNativeBridge(context: Context, messenger: BinaryMessenger) {
    private val app = context.applicationContext
    private val channel = MethodChannel(messenger, "unr/qidian_native")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val lock = Any()
    private val clients = mutableMapOf<String, AndroidQimeiClient>()
    private var next = 1L
    @Volatile private var disposed = false

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "dispatch") {
                result.notImplemented()
            } else if (disposed) {
                result.error("qidian_closed", "起点请求已取消", null)
            } else {
                val raw = call.arguments as? String
                if (raw == null || raw.length > 2 * 1024 * 1024) {
                    result.error("qidian_input", "起点参数无效", null)
                } else {
                    val action = Runnable {
                        val reply = try { dispatch(JSONObject(raw)).toString() }
                        catch (_: Exception) { "{\"ok\":false,\"error\":\"native_parameters_unavailable\"}" }
                        main.post { result.success(reply) }
                    }
                    // close must be able to interrupt a blocked registration.
                    if (runCatching { JSONObject(raw).optString("op") }.getOrDefault("") == "close") {
                        Thread(action, "qidian-cancel").start()
                    } else worker.execute(action)
                }
            }
        }
    }

    private fun dispatch(input: JSONObject): JSONObject {
        when (input.getString("op")) {
            "create" -> {
                check(input.optBoolean("privacyAgreed"))
                val session = input.optJSONObject("session") ?: JSONObject()
                val client = AndroidQimeiClient(app, AndroidQimeiClient.Session(
                    session.optString("deviceId"), "0", "", "", "", "", "", ""
                ), true, input.optBoolean("allowNetwork", true))
                synchronized(lock) {
                    if (disposed) { client.close(); error("Closed") }
                    val id = (next++).toString()
                    clients[id] = client
                    return JSONObject().put("ok", true).put("handle", id)
                }
            }
            "close" -> {
                val client = synchronized(lock) { clients.remove(input.getString("handle")) }
                client?.close()
                return JSONObject().put("ok", true)
            }
            else -> {
                val client = synchronized(lock) { clients[input.getString("handle")] } ?: error("Closed")
                return when (input.getString("op")) {
                    "ensure" -> client.ensure(true, false).put("ok", true)
                    "headers" -> JSONObject().put("ok", true).put("headers",
                        client.headers(input.getJSONObject("params"), input.optJSONObject("session") ?: JSONObject()))
                    "pause" -> JSONObject().put("ok", true).put("persisted", client.pause())
                    else -> error("Unknown operation")
                }
            }
        }
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        val pending = synchronized(lock) { clients.values.toList().also { clients.clear() } }
        pending.forEach { it.close() }
        worker.shutdown()
    }
}
