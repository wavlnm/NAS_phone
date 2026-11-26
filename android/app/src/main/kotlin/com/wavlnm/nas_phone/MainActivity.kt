package com.wavlnm.nas_phone

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
	companion object {
		private const val CHANNEL = "nas_phone/system_open"
		private const val FOLDER_CHANNEL = "nas_phone/folder_upload"
		private const val REQ_PICK_FOLDER = 0x4E41
	}

	private var pendingFolderResult: MethodChannel.Result? = null
	private var folderTreeUri: Uri? = null
	private var folderEntries: List<FolderEntry> = emptyList()
	private var folderSessionDir: File? = null

	private data class FolderEntry(
		val relativePath: String,
		val size: Long,
		val isDir: Boolean,
		val documentId: String?
	)

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

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FOLDER_CHANNEL).setMethodCallHandler { call, result ->
			when (call.method) {
				"pickFolder" -> pickFolder(result)
				"materialize" -> {
					val index = call.argument<Int>("index")
					if (index == null) {
						result.error("invalid_arguments", "缺少 index。", null)
					} else {
						materializeFile(index, result)
					}
				}
				"clearSession" -> {
					clearFolderSession()
					result.success(null)
				}
				else -> result.notImplemented()
			}
		}
	}

	private fun pickFolder(result: MethodChannel.Result) {
		if (pendingFolderResult != null) {
			result.error("busy", "文件夹选择器正在使用中。", null)
			return
		}

		pendingFolderResult = result
		try {
			val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
				addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
			}
			startActivityForResult(intent, REQ_PICK_FOLDER)
		} catch (e: ActivityNotFoundException) {
			pendingFolderResult = null
			result.error("picker_unavailable", "系统没有可用的文件夹选择器。", null)
		} catch (e: Exception) {
			pendingFolderResult = null
			result.error("picker_failed", e.message, null)
		}
	}

	@Suppress("DEPRECATION")
	override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
		if (requestCode == REQ_PICK_FOLDER) {
			val result = pendingFolderResult
			pendingFolderResult = null
			val uri = data?.data

			if (resultCode != Activity.RESULT_OK || uri == null) {
				result?.success(null)
				return
			}

			try {
				contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
			} catch (_: Exception) {
				// 部分提供方不支持持久授权，本次会话内仍可读取
			}

			Thread {
				try {
					val rootId = DocumentsContract.getTreeDocumentId(uri)
					val rootName = queryDisplayName(uri, rootId) ?: "上传文件夹"
					val entries = ArrayList<FolderEntry>()
					// 把所选文件夹本身作为根目录带出去，避免根层文件直接铺进当前目录
					entries.add(FolderEntry(rootName, 0L, true, null))
					walkChildren(uri, rootId, rootName, entries)

					clearFolderTemp()

					folderTreeUri = uri
					folderEntries = entries
					val payload = entries.map {
						mapOf(
							"path" to it.relativePath,
							"size" to it.size,
							"isDir" to it.isDir
						)
					}
					runOnUiThread { result?.success(payload) }
				} catch (e: Exception) {
					runOnUiThread { result?.error("scan_failed", e.message ?: "读取文件夹失败", null) }
				}
			}.start()
			return
		}

		@Suppress("DEPRECATION")
		super.onActivityResult(requestCode, resultCode, data)
	}

	private fun queryDisplayName(treeUri: Uri, documentId: String): String? {
		val documentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
		val projection = arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
		contentResolver.query(documentUri, projection, null, null, null)?.use { cursor ->
			if (cursor.moveToFirst()) {
				return cursor.getString(0)
			}
		}
		return null
	}

	private fun walkChildren(
		treeUri: Uri,
		parentDocumentId: String,
		prefix: String,
		out: MutableList<FolderEntry>
	) {
		val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocumentId)
		val projection = arrayOf(
			DocumentsContract.Document.COLUMN_DOCUMENT_ID,
			DocumentsContract.Document.COLUMN_DISPLAY_NAME,
			DocumentsContract.Document.COLUMN_MIME_TYPE,
			DocumentsContract.Document.COLUMN_SIZE
		)

		contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
			val idIndex = cursor.getColumnIndex(projection[0])
			val nameIndex = cursor.getColumnIndex(projection[1])
			val mimeIndex = cursor.getColumnIndex(projection[2])
			val sizeIndex = cursor.getColumnIndex(projection[3])
			if (idIndex < 0 || nameIndex < 0 || mimeIndex < 0) {
				return
			}

			while (cursor.moveToNext()) {
				val documentId = cursor.getString(idIndex) ?: continue
				val name = cursor.getString(nameIndex) ?: continue
				val mime = if (mimeIndex >= 0) cursor.getString(mimeIndex) ?: "" else ""
				val size = if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) cursor.getLong(sizeIndex) else 0L
				val relativePath = if (prefix.isEmpty()) name else "$prefix/$name"

				if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
					out.add(FolderEntry(relativePath, 0L, true, null))
					try {
						walkChildren(treeUri, documentId, relativePath, out)
					} catch (_: Exception) {
						// 个别子目录无权限时跳过，不影响其它文件
					}
				} else {
					out.add(FolderEntry(relativePath, size, false, documentId))
				}
			}
		}
	}

	private fun materializeFile(index: Int, result: MethodChannel.Result) {
		val treeUri = folderTreeUri
		if (treeUri == null) {
			result.error("no_session", "还没有选择文件夹。", null)
			return
		}
		if (index < 0 || index >= folderEntries.size) {
			result.error("invalid_index", "文件序号越界。", null)
			return
		}

		val entry = folderEntries[index]
		val documentId = entry.documentId
		if (documentId == null) {
			result.error("invalid_entry", "该条目不是文件。", null)
			return
		}

		val dir = folderSessionDir
			?: File(cacheDir, "nas_folder_upload").apply {
				deleteRecursively()
				mkdirs()
			}.also { folderSessionDir = it }

		Thread {
			try {
				val fileName = entry.relativePath.substringAfterLast('/')
				val target = File(dir, "${index}_$fileName")
				val documentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
				contentResolver.openInputStream(documentUri).use { input ->
					if (input == null) {
						throw IllegalStateException("无法读取文件：${entry.relativePath}")
					}
					target.outputStream().use { output ->
						input.copyTo(output, 64 * 1024)
					}
				}
				runOnUiThread { result.success(target.absolutePath) }
			} catch (e: Exception) {
				runOnUiThread { result.error("copy_failed", e.message ?: "复制文件失败", null) }
			}
		}.start()
	}

	private fun clearFolderSession() {
		folderTreeUri = null
		folderEntries = emptyList()
		clearFolderTemp()
	}

	private fun clearFolderTemp() {
		folderSessionDir?.deleteRecursively()
		folderSessionDir = null
	}

	override fun onDestroy() {
		clearFolderTemp()
		super.onDestroy()
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
