package com.wavlnm.nas_phone

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * 传输期间的前台服务：持有 CPU 和 WiFi 锁，避免手机息屏后进入省电模式导致传输中断。
 * 传输开始由 Dart 侧调用 [start]，全部结束调用 [stop]。
 */
class TransferService : Service() {
	companion object {
		private const val CHANNEL_ID = "nas_transfer"
		private const val NOTIFICATION_ID = 0x4E43
		private const val ACTION_START = "com.wavlnm.nas_phone.transfer.START"
		private const val ACTION_STOP = "com.wavlnm.nas_phone.transfer.STOP"
		private const val EXTRA_TEXT = "text"

		fun start(context: Context, text: String) {
			val intent = Intent(context, TransferService::class.java).apply {
				action = ACTION_START
				putExtra(EXTRA_TEXT, text)
			}
			if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
				context.startForegroundService(intent)
			} else {
				@Suppress("DEPRECATION")
				context.startService(intent)
			}
		}

		fun stop(context: Context) {
			context.stopService(Intent(context, TransferService::class.java))
		}
	}

	private var wakeLock: PowerManager.WakeLock? = null
	private var wifiLock: WifiManager.WifiLock? = null

	override fun onBind(intent: Intent?): IBinder? = null

	override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
		if (intent?.action == ACTION_STOP) {
			stopSelf()
			return START_NOT_STICKY
		}

		val text = intent?.getStringExtra(EXTRA_TEXT) ?: "正在传输"
		ensureChannel()
		startForeground(NOTIFICATION_ID, buildNotification(text))
		acquireLocks()
		return START_NOT_STICKY
	}

	override fun onDestroy() {
		releaseLocks()
		@Suppress("DEPRECATION")
		stopForeground(true)
		super.onDestroy()
	}

	private fun ensureChannel() {
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
			return
		}
		val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
		if (manager.getNotificationChannel(CHANNEL_ID) != null) {
			return
		}
		val channel = NotificationChannel(
			CHANNEL_ID,
			"文件传输",
			NotificationManager.IMPORTANCE_LOW
		).apply {
			description = "传输进行中时保持连接"
			setShowBadge(false)
		}
		manager.createNotificationChannel(channel)
	}

	private fun buildNotification(text: String): Notification {
		val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
		val pendingIntent = launchIntent?.let {
			PendingIntent.getActivity(
				this,
				0,
				it,
				PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
			)
		}

		val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
			Notification.Builder(this, CHANNEL_ID)
		} else {
			@Suppress("DEPRECATION")
			Notification.Builder(this)
		}

		return builder
			.setContentTitle("千私云 · 正在传输")
			.setContentText(text)
			.setSmallIcon(android.R.drawable.stat_sys_upload)
			.setOngoing(true)
			.setOnlyAlertOnce(true)
			.setShowWhen(false)
			.setContentIntent(pendingIntent)
			.build()
	}

	private fun acquireLocks() {
		if (wakeLock == null) {
			val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
			wakeLock = powerManager
				.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "nas_phone:transfer")
				.apply {
					setReferenceCounted(false)
					acquire()
				}
		}

		if (wifiLock == null) {
			val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
			wifiLock = wifiManager
				?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "nas_phone:transfer")
				?.apply {
					setReferenceCounted(false)
					acquire()
				}
		}
	}

	private fun releaseLocks() {
		wakeLock?.let { if (it.isHeld) it.release() }
		wakeLock = null
		wifiLock?.let { if (it.isHeld) it.release() }
		wifiLock = null
	}
}
