package io.github.moranfanhua.unr

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import com.github.megatronking.netbare.NetBareService

class SessionVpnService : NetBareService() {
    private var started = false
    override fun onCreate() { super.onCreate(); SessionCapture.attach(application) }
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
            .setContentText("仅辅助本机网页登录，点此返回；获取会话后自动停止")
            .setContentIntent(openIntent).setOngoing(true)
            .addAction(Notification.Action.Builder(null, "停止抓取", stopIntent).build()).build()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) { SessionCapture.stop(); stopSelf(); return START_NOT_STICKY }
        if (intent?.action == ACTION_START) started = true
        return super.onStartCommand(intent, flags, startId)
    }

    override fun onRevoke() { SessionCapture.stop(); super.onRevoke() }
    override fun onDestroy() { super.onDestroy(); if (!started) SessionCapture.serviceDestroyed() }
}
