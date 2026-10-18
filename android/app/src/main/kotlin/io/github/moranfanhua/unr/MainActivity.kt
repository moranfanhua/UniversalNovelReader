package io.github.moranfanhua.unr

import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var volumeChannel: MethodChannel? = null
    private var volumeKeysEnabled = false
    private val consumedKeys = mutableSetOf<Int>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
        volumeKeysEnabled = false
        consumedKeys.clear()
        volumeChannel?.setMethodCallHandler(null)
        volumeChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
