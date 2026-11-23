package com.synccanvas.sync_canvas_notebook

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.synccanvas/native_bridge"
        private const val REQ_PICK_IMAGE = 9101
        private const val REQ_SCAN_QR = 9102
        private const val REQ_PICK_PDF = 9103
        private const val REQ_RECORD_AUDIO = 9104
        private const val MAX_IMAGE_DIM = 1600
        private const val MAX_PDF_DIM = 1440
    }

    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var bridgeChannel: MethodChannel? = null
    private var pendingImageResult: MethodChannel.Result? = null
    private var pendingQrResult: MethodChannel.Result? = null
    private var pendingPdfResult: MethodChannel.Result? = null
    private var pendingPdfMaxPages: Int = 30
    private var pendingSpeechResult: MethodChannel.Result? = null
    private var pendingSpeechLocale: String = "zh-CN"
    private var speechRecognizer: SpeechRecognizer? = null
    private var wantsSpeechListening = false
    private var nearbyManager: NearbyBootstrapManager? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        bridgeChannel = channel
        val manager = NearbyBootstrapManager(this, channel)
        nearbyManager = manager

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getAppFilesDir" -> {
                    result.success(filesDir.absolutePath)
                }
                "pickImage" -> {
                    pendingImageResult?.success(null)
                    pendingImageResult = result
                    launchImagePicker()
                }
                "pickPdf" -> {
                    pendingPdfResult?.success(null)
                    pendingPdfResult = result
                    pendingPdfMaxPages = (call.argument<Int>("maxPages") ?: 30).coerceIn(1, 120)
                    launchPdfPicker()
                }
                "scanQrCode" -> {
                    pendingQrResult?.success(null)
                    pendingQrResult = result
                    val intent = Intent(this, QrScannerActivity::class.java)
                    @Suppress("DEPRECATION")
                    startActivityForResult(intent, REQ_SCAN_QR)
                }
                "setMulticastLock" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    manager.setMulticastLock(enabled)
                    result.success(true)
                }
                "startBleAdvertising" -> {
                    val json = call.argument<String>("beaconJson") ?: ""
                    manager.startBleAdvertising(json, result)
                }
                "stopBleAdvertising" -> {
                    manager.stopBleAdvertising()
                    result.success(true)
                }
                "startBleScanning" -> {
                    manager.startBleScanning(result)
                }
                "stopBleScanning" -> {
                    manager.stopBleScanning()
                    result.success(true)
                }
                "startLocalHotspot" -> {
                    manager.startLocalHotspot(result)
                }
                "stopLocalHotspot" -> {
                    manager.stopLocalHotspot()
                    result.success(true)
                }
                "connectToHotspot" -> {
                    val ssid = call.argument<String>("ssid") ?: ""
                    val password = call.argument<String>("password") ?: ""
                    manager.connectToHotspot(ssid, password, result)
                }
                "unbindHotspot" -> {
                    manager.unbindHotspot()
                    result.success(true)
                }
                "openSystemHotspotSettings" -> {
                    manager.openSystemHotspotSettings()
                    result.success(true)
                }
                "startSpeechRecognition" -> {
                    val locale = call.argument<String>("locale") ?: "zh-CN"
                    startSpeechRecognitionWithPermission(locale, result)
                }
                "stopSpeechRecognition" -> {
                    stopSpeechRecognitionInternal()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_RECORD_AUDIO) {
            val cb = pendingSpeechResult
            pendingSpeechResult = null
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            if (granted) {
                beginSpeechRecognizerOnMain(pendingSpeechLocale, cb)
            } else {
                cb?.success(
                    mapOf(
                        "ok" to false,
                        "manualRequired" to true,
                        "error" to "需要麦克风权限才能进行实时语音转写"
                    )
                )
            }
            return
        }
        nearbyManager?.onRequestPermissionsResult(requestCode, grantResults)
    }

    private fun emitSpeechEvent(payload: Map<String, Any?>) {
        mainHandler.post {
            bridgeChannel?.invokeMethod("onSpeechEvent", payload)
        }
    }

    private fun startSpeechRecognitionWithPermission(locale: String, result: MethodChannel.Result) {
        pendingSpeechLocale = locale
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED
        ) {
            pendingSpeechResult?.success(
                mapOf("ok" to false, "error" to "权限请求已取消")
            )
            pendingSpeechResult = result
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQ_RECORD_AUDIO)
            return
        }
        beginSpeechRecognizerOnMain(locale, result)
    }

    private fun beginSpeechRecognizerOnMain(locale: String, result: MethodChannel.Result?) {
        mainHandler.post {
            if (!SpeechRecognizer.isRecognitionAvailable(this)) {
                result?.success(
                    mapOf(
                        "ok" to false,
                        "manualRequired" to true,
                        "error" to "当前系统未安装或启用语音识别服务，可使用系统语音输入法录入并自动成稿"
                    )
                )
                return@post
            }

            destroyRecognizerImmediateOnMain()
            wantsSpeechListening = true
            pendingSpeechLocale = locale

            val recognizer = SpeechRecognizer.createSpeechRecognizer(this)
            speechRecognizer = recognizer
            recognizer.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {
                    emitSpeechEvent(mapOf("type" to "status", "status" to "listening"))
                }

                override fun onBeginningOfSpeech() {}

                override fun onRmsChanged(rmsdB: Float) {
                    val norm = ((rmsdB + 2f) / 12f).coerceIn(0f, 1f).toDouble()
                    emitSpeechEvent(mapOf("type" to "level", "level" to norm))
                }

                override fun onBufferReceived(buffer: ByteArray?) {}

                override fun onEndOfSpeech() {}

                override fun onError(error: Int) {
                    if (!wantsSpeechListening) return
                    val retryable = error == SpeechRecognizer.ERROR_NO_MATCH ||
                        error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT ||
                        error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY
                    if (retryable) {
                        mainHandler.postDelayed({ startNextRecognitionCycle() }, 180)
                        return
                    }
                    emitSpeechEvent(
                        mapOf(
                            "type" to "error",
                            "error" to when (error) {
                                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "请开启系统麦克风权限"
                                SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT ->
                                    "在线语音识别网络不可用，请检查网络或下载系统离线语音包"
                                else -> "语音识别中断 (code=$error)"
                            }
                        )
                    )
                }

                override fun onResults(results: Bundle?) {
                    val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    val top = matches?.firstOrNull()?.trim().orEmpty()
                    if (top.isNotEmpty()) {
                        emitSpeechEvent(mapOf("type" to "finalized", "text" to top))
                    } else {
                        emitSpeechEvent(mapOf("type" to "partial", "text" to ""))
                    }
                    if (wantsSpeechListening) {
                        mainHandler.postDelayed({ startNextRecognitionCycle() }, 120)
                    }
                }

                override fun onPartialResults(partialResults: Bundle?) {
                    val matches = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    val top = matches?.firstOrNull()?.trim().orEmpty()
                    if (top.isNotEmpty()) {
                        emitSpeechEvent(mapOf("type" to "partial", "text" to top))
                    }
                }

                override fun onEvent(eventType: Int, params: Bundle?) {}
            })

            startNextRecognitionCycle()
            result?.success(mapOf("ok" to true))
        }
    }

    private fun startNextRecognitionCycle() {
        if (!wantsSpeechListening) return
        val recognizer = speechRecognizer ?: return
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, pendingSpeechLocale)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        }
        try {
            recognizer.startListening(intent)
        } catch (_: Exception) {}
    }

    private fun destroyRecognizerImmediateOnMain() {
        try {
            speechRecognizer?.stopListening()
        } catch (_: Exception) {}
        try {
            speechRecognizer?.destroy()
        } catch (_: Exception) {}
        speechRecognizer = null
    }

    private fun stopSpeechRecognitionInternal(resetIntentOnly: Boolean = false) {
        wantsSpeechListening = false
        if (resetIntentOnly) return
        mainHandler.post {
            destroyRecognizerImmediateOnMain()
        }
    }

    private fun launchImagePicker() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Intent(MediaStore.ACTION_PICK_IMAGES).apply {
                type = "image/*"
            }
        } else {
            Intent(Intent.ACTION_GET_CONTENT).apply {
                type = "image/*"
                addCategory(Intent.CATEGORY_OPENABLE)
            }
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQ_PICK_IMAGE)
        } catch (_: Exception) {
            val fallback = Intent(Intent.ACTION_GET_CONTENT).apply {
                type = "image/*"
                addCategory(Intent.CATEGORY_OPENABLE)
            }
            @Suppress("DEPRECATION")
            startActivityForResult(fallback, REQ_PICK_IMAGE)
        }
    }

    private fun launchPdfPicker() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            type = "application/pdf"
            addCategory(Intent.CATEGORY_OPENABLE)
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQ_PICK_PDF)
        } catch (_: Exception) {
            val fallback = Intent(Intent.ACTION_GET_CONTENT).apply {
                type = "application/pdf"
                addCategory(Intent.CATEGORY_OPENABLE)
            }
            @Suppress("DEPRECATION")
            startActivityForResult(fallback, REQ_PICK_PDF)
        }
    }

    @Deprecated("Required for FlutterActivity compatibility across API 24+")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)

        when (requestCode) {
            REQ_PICK_IMAGE -> {
                val callback = pendingImageResult
                pendingImageResult = null
                if (callback == null) return

                val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
                if (uri == null) {
                    callback.success(null)
                    return
                }
                ioExecutor.execute {
                    val dataUrl = encodePickedImageToDataUrl(uri)
                    runOnUiThread { callback.success(dataUrl) }
                }
            }
            REQ_PICK_PDF -> {
                val callback = pendingPdfResult
                pendingPdfResult = null
                val maxPages = pendingPdfMaxPages
                if (callback == null) return

                val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
                if (uri == null) {
                    callback.success(null)
                    return
                }
                ioExecutor.execute {
                    val pdfJson = renderPickedPdfToJson(uri, maxPages)
                    runOnUiThread { callback.success(pdfJson) }
                }
            }
            REQ_SCAN_QR -> {
                val callback = pendingQrResult
                pendingQrResult = null
                if (callback == null) return

                val scanned = if (resultCode == Activity.RESULT_OK) {
                    data?.getStringExtra(QrScannerActivity.EXTRA_QR_RESULT)
                } else {
                    null
                }
                callback.success(scanned)
            }
        }
    }

    private fun encodePickedImageToDataUrl(uri: Uri): String? {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            contentResolver.openInputStream(uri)?.use { stream ->
                BitmapFactory.decodeStream(stream, null, bounds)
            }
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

            var sampleSize = 1
            while (max(bounds.outWidth / sampleSize, bounds.outHeight / sampleSize) > MAX_IMAGE_DIM * 2) {
                sampleSize *= 2
            }

            val decodeOpts = BitmapFactory.Options().apply { inSampleSize = sampleSize }
            val decoded = contentResolver.openInputStream(uri)?.use { stream ->
                BitmapFactory.decodeStream(stream, null, decodeOpts)
            } ?: return null

            val exifRotation = readExifTransform(uri)
            val maxDim = max(decoded.width, decoded.height)
            val scale = if (maxDim > MAX_IMAGE_DIM) {
                MAX_IMAGE_DIM.toFloat() / maxDim.toFloat()
            } else {
                1.0f
            }

            val finalBitmap = if (scale < 0.999f || !exifRotation.isIdentity) {
                val matrix = Matrix().apply {
                    postConcat(exifRotation)
                    if (scale < 0.999f) {
                        postScale(scale, scale)
                    }
                }
                val transformed = Bitmap.createBitmap(
                    decoded,
                    0,
                    0,
                    decoded.width,
                    decoded.height,
                    matrix,
                    true,
                )
                if (transformed !== decoded) {
                    decoded.recycle()
                }
                transformed
            } else {
                decoded
            }

            val out = ByteArrayOutputStream()
            var mime = "image/jpeg"
            if (finalBitmap.hasAlpha() && max(finalBitmap.width, finalBitmap.height) <= 1200) {
                finalBitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                if (out.size() <= 700_000) {
                    mime = "image/png"
                } else {
                    out.reset()
                    finalBitmap.compress(Bitmap.CompressFormat.JPEG, 86, out)
                }
            } else {
                finalBitmap.compress(Bitmap.CompressFormat.JPEG, 86, out)
            }

            val bytes = out.toByteArray()
            finalBitmap.recycle()
            val encoded = Base64.encodeToString(bytes, Base64.NO_WRAP)
            "data:$mime;base64,$encoded"
        } catch (_: Exception) {
            null
        }
    }

    private fun readExifTransform(uri: Uri): Matrix {
        val matrix = Matrix()
        try {
            contentResolver.openInputStream(uri)?.use { stream ->
                val exif = ExifInterface(stream)
                when (
                    exif.getAttributeInt(
                        ExifInterface.TAG_ORIENTATION,
                        ExifInterface.ORIENTATION_NORMAL,
                    )
                ) {
                    ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
                    ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
                    ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
                    ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.preScale(-1f, 1f)
                    ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.preScale(1f, -1f)
                }
            }
        } catch (_: Exception) {
        }
        return matrix
    }

    private fun resolveDisplayName(uri: Uri): String {
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0 && cursor.moveToFirst()) {
                        val name = cursor.getString(idx)?.trim()
                        if (!name.isNullOrEmpty()) return name
                    }
                }
        } catch (_: Exception) {
        }
        return uri.lastPathSegment?.substringAfterLast('/')?.ifEmpty { "document.pdf" }
            ?: "document.pdf"
    }

    private fun renderPickedPdfToJson(uri: Uri, maxPages: Int): String {
        val fileName = resolveDisplayName(uri)
        var tempCopy: File? = null
        var pfd: ParcelFileDescriptor? = null
        var renderer: PdfRenderer? = null
        return try {
            try {
                pfd = contentResolver.openFileDescriptor(uri, "r")
                if (pfd != null) {
                    renderer = PdfRenderer(pfd!!)
                }
            } catch (_: Exception) {
                try {
                    pfd?.close()
                } catch (_: Exception) {
                }
                pfd = null
                renderer = null
            }

            if (renderer == null) {
                val copied = File(cacheDir, "synccanvas_import_${System.currentTimeMillis()}.pdf")
                tempCopy = copied
                contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(copied).use { output ->
                        input.copyTo(output)
                    }
                } ?: return JSONObject()
                    .put("fileName", fileName)
                    .put("error", "无法读取所选 PDF 文件")
                    .toString()
                pfd = ParcelFileDescriptor.open(copied, ParcelFileDescriptor.MODE_READ_ONLY)
                renderer = PdfRenderer(pfd!!)
            }

            val activeRenderer = renderer!!
            val totalPages = activeRenderer.pageCount
            val limit = min(totalPages, maxPages)
            val pagesArray = JSONArray()

            for (i in 0 until limit) {
                activeRenderer.openPage(i).use { page ->
                    val rawW = max(1, page.width)
                    val rawH = max(1, page.height)
                    val maxSide = max(rawW, rawH)
                    val scale = (MAX_PDF_DIM.toFloat() / maxSide.toFloat()).coerceIn(0.25f, 2.4f)
                    val bmpW = max(1, (rawW * scale).roundToInt())
                    val bmpH = max(1, (rawH * scale).roundToInt())

                    val bitmap = Bitmap.createBitmap(bmpW, bmpH, Bitmap.Config.ARGB_8888)
                    val canvas = Canvas(bitmap)
                    canvas.drawColor(Color.WHITE)
                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)

                    val out = ByteArrayOutputStream()
                    bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
                    bitmap.recycle()

                    val b64 = Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
                    pagesArray.put(
                        JSONObject()
                            .put("pageNumber", i + 1)
                            .put("width", bmpW)
                            .put("height", bmpH)
                            .put("dataUrl", "data:image/jpeg;base64,$b64")
                    )
                }
            }

            JSONObject()
                .put("fileName", fileName)
                .put("totalPages", totalPages)
                .put("pages", pagesArray)
                .toString()
        } catch (e: Exception) {
            JSONObject()
                .put("fileName", fileName)
                .put("error", e.message ?: "PDF 渲染失败")
                .toString()
        } finally {
            try {
                renderer?.close()
            } catch (_: Exception) {
            }
            try {
                pfd?.close()
            } catch (_: Exception) {
            }
            try {
                tempCopy?.delete()
            } catch (_: Exception) {
            }
        }
    }

    override fun onDestroy() {
        stopSpeechRecognitionInternal()
        nearbyManager?.dispose()
        nearbyManager = null
        ioExecutor.shutdownNow()
        super.onDestroy()
    }
}
