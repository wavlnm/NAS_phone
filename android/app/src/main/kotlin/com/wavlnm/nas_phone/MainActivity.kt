package com.wavlnm.nas_phone

import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

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
				"copyToMediaStoreDownloads" -> {
					val sourcePath = call.argument<String>("sourcePath")
					val fileName   = call.argument<String>("fileName")
					val mimeType   = call.argument<String>("mimeType") ?: "application/octet-stream"
					val subFolder  = call.argument<String>("subFolder") ?: "NAS_Downloads"
					if (sourcePath.isNullOrBlank() || fileName.isNullOrBlank()) {
						result.error("invalid_arguments", "sourcePath 和 fileName 不能为空。", null)
						return@setMethodCallHandler
					}
					copyToMediaStoreDownloads(sourcePath, fileName, mimeType, subFolder, result)
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

	/**
	 * 将 [sourcePath] 对应的临时文件复制到 MediaStore Downloads。
	 * Android 10+ (API 29+) 使用 MediaStore API，文件会出现在系统文件管理器的"最近"和"下载"中。
	 * Android 9 及以下直接复制到公共 Downloads 目录。
	 * 成功时返回显示用路径字符串（如 "Download/NAS_Downloads/file.jpg"）。
	 */
	private fun copyToMediaStoreDownloads(
		sourcePath: String,
		fileName: String,
		mimeType: String,
		subFolder: String,
		result: MethodChannel.Result
	) {
		try {
			val src = File(sourcePath)
			if (!src.exists()) {
				result.error("file_not_found", "临时文件不存在：$sourcePath", null)
				return
			}

			if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
				// Android 10+ — MediaStore.Downloads API
				val values = ContentValues().apply {
					put(MediaStore.Downloads.DISPLAY_NAME, fileName)
					put(MediaStore.Downloads.MIME_TYPE, mimeType)
					put(MediaStore.Downloads.RELATIVE_PATH, "Download/$subFolder")
					put(MediaStore.Downloads.IS_PENDING, 1)
				}
				val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
				val itemUri = contentResolver.insert(collection, values)
					?: throw Exception("MediaStore.insert 返回 null，无法创建条目。")

				contentResolver.openOutputStream(itemUri)?.use { out ->
					FileInputStream(src).use { it.copyTo(out) }
				}

				values.clear()
				values.put(MediaStore.Downloads.IS_PENDING, 0)
				contentResolver.update(itemUri, values, null, null)
			} else {
				// Android 9 及以下 — 直接写入公共 Downloads
				val dest = File(
					Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
					"$subFolder/$fileName"
				)
				dest.parentFile?.mkdirs()
				FileInputStream(src).use { i -> dest.outputStream().use { o -> i.copyTo(o) } }
			}

			result.success("Download/$subFolder/$fileName")
		} catch (e: Exception) {
			result.error("media_store_error", e.message, null)
		}
	}
}

