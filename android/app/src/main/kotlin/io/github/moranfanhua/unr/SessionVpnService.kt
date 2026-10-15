package io.github.moranfanhua.unr

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import com.github.megatronking.netbare.NetBareService

class SessionVpnService : NetBareService() {
    companion object {
        private var instance: SessionVpnService? = null
        fun stopRunning(): Boolean {
            val service = instance ?: return false
            service.stopCapture()
            return true
        }
    }
    private var started = false
    override fun onCreate() { super.onCreate(); instance = this; SessionCapture.attach(application) }
    private fun stopCapture() {
        super.onStartCommand(Intent(this, SessionVpnService::class.java).setAction(ACTION_STOP), 0, 0)
    }
    override fun notificationId() = 5132

    override fun createNotification(): Notification {
        val channelId = "unr-session-capture"
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(channelId, "会话抓取辅助", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val stopIntent = PendingIntent.getService(this, 1,
            Intent(this, SessionVpnService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val openIntent = PendingIntent.getActivity(this, 2, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channelId) else Notification.Builder(this)
        return builder.setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle("UNR 会话辅助正在运行")
            .setContentText("仅抓取所选官方 App 的会话，取得后自动停止；点此返回 UNR")
            .setContentIntent(openIntent).setOngoing(true)
            .addAction(Notification.Action.Builder(null, "停止抓取", stopIntent).build()).build()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) { SessionCapture.stop(); stopSelf(); return START_NOT_STICKY }
        if (intent?.action == ACTION_START) {
            if (SessionCapture.snapshot()["phase"] != "starting") { stopCapture(); return START_NOT_STICKY }
            started = true
        }
        return super.onStartCommand(intent, flags, startId)
    }

    override fun onRevoke() { SessionCapture.stop(); super.onRevoke() }
    override fun onDestroy() { instance = null; super.onDestroy(); if (!started) SessionCapture.serviceDestroyed() }
}
