package com.synccanvas.sync_canvas_notebook

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import kotlin.math.max

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.synccanvas/native_bridge"
        private const val REQ_PICK_IMAGE = 9101
        private const val REQ_SCAN_QR = 9102
        private const val MAX_IMAGE_DIM = 1600
    }

    private val ioExecutor = Executors.newSingleThreadExecutor()
    private var pendingImageResult: MethodChannel.Result? = null
    private var pendingQrResult: MethodChannel.Result? = null
    private var nearbyManager: NearbyBootstrapManager? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
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
        nearbyManager?.onRequestPermissionsResult(requestCode, grantResults)
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

    override fun onDestroy() {
        nearbyManager?.dispose()
        nearbyManager = null
        ioExecutor.shutdownNow()
        super.onDestroy()
    }
}
