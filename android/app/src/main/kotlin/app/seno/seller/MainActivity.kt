package app.seno.seller

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "app.seno.seller/share"
    private var latestSharedImagePath: String? = null
    private var shareChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        captureSharedImage(intent)

        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        shareChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeSharedImage" -> {
                    val path = latestSharedImagePath
                    latestSharedImagePath = null
                    result.success(path)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureSharedImage(intent)
        latestSharedImagePath?.let { path ->
            shareChannel?.invokeMethod("sharedImageReceived", path)
            latestSharedImagePath = null
        }
    }

    private fun captureSharedImage(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM) ?: return
        latestSharedImagePath = copyUriToCache(uri)
    }

    private fun copyUriToCache(uri: Uri): String? {
        return try {
            val file = File(cacheDir, "shared-product-${System.currentTimeMillis()}.jpg")
            contentResolver.openInputStream(uri)?.use { input ->
                file.outputStream().use { output -> input.copyTo(output) }
            }
            file.absolutePath
        } catch (_: Exception) {
            null
        }
    }
}
