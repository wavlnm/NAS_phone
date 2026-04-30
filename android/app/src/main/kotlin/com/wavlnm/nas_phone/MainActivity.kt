package com.wavlnm.nas_phone

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	companion object {
		private const val CHANNEL = "nas_phone/system_open"
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
			when (call.method) {
				"openVideoUrl" -> {
					val url = call.argument<String>("url")
					if (url.isNullOrBlank()) {
						result.error("invalid_arguments", "缺少视频 URL。", null)
						return@setMethodCallHandler
					}

					openVideoUrl(url, result)
				}
				else -> result.notImplemented()
			}
		}
	}

	private fun openVideoUrl(url: String, result: MethodChannel.Result) {
		val intent = Intent(Intent.ACTION_VIEW).apply {
			setDataAndType(Uri.parse(url), "video/*")
			addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
		}

		try {
			startActivity(Intent.createChooser(intent, null))
			result.success(true)
		} catch (_: ActivityNotFoundException) {
			result.success(false)
		} catch (exception: Exception) {
			result.error("open_video_failed", exception.message, null)
		}
	}
}
