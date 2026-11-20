package com.synccanvas.sync_canvas_notebook

import android.Manifest
import android.animation.ValueAnimator
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.graphics.SurfaceTexture
import android.graphics.drawable.GradientDrawable
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.Image
import android.media.ImageReader
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.provider.MediaStore
import android.util.Size
import android.util.TypedValue
import android.view.Gravity
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.view.animation.LinearInterpolator
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

class QrScannerActivity : Activity() {
    companion object {
        const val EXTRA_QR_RESULT = "qr_result"
        private const val REQ_CAMERA_PERMISSION = 9201
        private const val REQ_PICK_QR_IMAGE = 9202
    }

    private lateinit var textureView: TextureView
    private lateinit var statusHintText: TextView
    private lateinit var torchButton: Button
    private lateinit var overlayView: ScannerOverlayView

    private var cameraThread: HandlerThread? = null
    private var cameraHandler: Handler? = null
    private val decodeExecutor = Executors.newSingleThreadExecutor()

    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var previewBuilder: CaptureRequest.Builder? = null
    private var imageReader: ImageReader? = null

    private var previewSize: Size = Size(1280, 720)
    private var hasFlash = false
    private var torchOn = false
    private var lastDecodeAttemptMs = 0L
    private var invertNextFrame = false
    private val deliveredResult = AtomicBoolean(false)

    private val qrReader = MultiFormatReader().apply {
        setHints(
            mapOf(
                DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                DecodeHintType.TRY_HARDER to true,
            ),
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildScannerLayout())
        ensureCameraOrRequestPermission()
    }

    private fun buildScannerLayout(): View {
        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            fitsSystemWindows = true
        }

        textureView = TextureView(this).apply {
            surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                override fun onSurfaceTextureAvailable(
                    surface: SurfaceTexture,
                    width: Int,
                    height: Int,
                ) {
                    configureTextureTransform(width, height)
                    openCameraIfPermitted()
                }

                override fun onSurfaceTextureSizeChanged(
                    surface: SurfaceTexture,
                    width: Int,
                    height: Int,
                ) {
                    configureTextureTransform(width, height)
                }

                override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean = true

                override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {}
            }
        }
        root.addView(
            textureView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        overlayView = ScannerOverlayView(this)
        root.addView(
            overlayView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        statusHintText = TextView(this).apply {
            text = "将电脑 / 平板「三端连接」二维码放入框内"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            gravity = Gravity.CENTER
            setPadding(dp(20), dp(8), dp(20), dp(8))
        }
        root.addView(
            statusHintText,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL,
            ).apply {
                bottomMargin = dp(120)
            },
        )

        val topBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(10))
        }

        val closeBtn = createPillButton("关闭") {
            setResult(Activity.RESULT_CANCELED)
            finish()
        }
        torchButton = createPillButton("补光灯: 关") {
            toggleTorch()
        }.apply {
            visibility = View.GONE
        }

        val spacer = View(this)
        topBar.addView(closeBtn)
        topBar.addView(
            spacer,
            LinearLayout.LayoutParams(0, 1, 1f),
        )
        topBar.addView(torchButton)

        root.addView(
            topBar,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP,
            ),
        )

        val galleryBtn = createPillButton("从相册选二维码图片", primary = true) {
            launchGalleryQrPicker()
        }
        root.addView(
            galleryBtn,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL,
            ).apply {
                bottomMargin = dp(44)
            },
        )

        return root
    }

    private fun createPillButton(
        label: String,
        primary: Boolean = false,
        onClick: () -> Unit,
    ): Button {
        return Button(this).apply {
            text = label
            isAllCaps = false
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setPadding(dp(18), dp(10), dp(18), dp(10))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(999).toFloat()
                setColor(
                    if (primary) Color.parseColor("#CC4F46E5")
                    else Color.parseColor("#991E293B"),
                )
                setStroke(dp(1), Color.parseColor("#55FFFFFF"))
            }
            setOnClickListener { onClick() }
        }
    }

    private fun ensureCameraOrRequestPermission() {
        if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            if (textureView.isAvailable) {
                openCameraIfPermitted()
            }
        } else {
            requestPermissions(arrayOf(Manifest.permission.CAMERA), REQ_CAMERA_PERMISSION)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_CAMERA_PERMISSION) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                if (textureView.isAvailable) {
                    openCameraIfPermitted()
                }
            } else {
                statusHintText.text = "未开启相机权限，可点击下方按钮从相册选取二维码截图"
            }
        }
    }

    override fun onResume() {
        super.onResume()
        startCameraThread()
        overlayView.startScanAnimation()
        if (textureView.isAvailable &&
            checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        ) {
            openCameraIfPermitted()
        }
    }

    override fun onPause() {
        overlayView.stopScanAnimation()
        closeCamera()
        stopCameraThread()
        super.onPause()
    }

    override fun onDestroy() {
        decodeExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun startCameraThread() {
        if (cameraThread != null) return
        cameraThread = HandlerThread("SyncCanvasQrCam").apply {
            start()
            cameraHandler = Handler(looper)
        }
    }

    private fun stopCameraThread() {
        cameraThread?.quitSafely()
        try {
            cameraThread?.join(500)
        } catch (_: InterruptedException) {
        }
        cameraThread = null
        cameraHandler = null
    }

    private fun openCameraIfPermitted() {
        if (cameraDevice != null) return
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            return
        }
        if (!textureView.isAvailable) return

        startCameraThread()
        val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        try {
            val selectedId = selectCameraId(manager)
            if (selectedId == null) {
                statusHintText.text = "未检测到可用摄像头，请从相册选取二维码图片"
                return
            }

            val chars = manager.getCameraCharacteristics(selectedId)
            hasFlash = chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
            runOnUiThread {
                torchButton.visibility = if (hasFlash) View.VISIBLE else View.GONE
            }

            val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            if (map != null) {
                previewSize = chooseBestSize(
                    map.getOutputSizes(SurfaceTexture::class.java),
                    targetWidth = 1280,
                    targetHeight = 720,
                )
            }
            val analysisSize = if (map != null) {
                chooseBestSize(
                    map.getOutputSizes(ImageFormat.YUV_420_888),
                    targetWidth = 960,
                    targetHeight = 720,
                )
            } else {
                Size(960, 720)
            }

            runOnUiThread {
                configureTextureTransform(textureView.width, textureView.height)
            }

            imageReader = ImageReader.newInstance(
                analysisSize.width,
                analysisSize.height,
                ImageFormat.YUV_420_888,
                2,
            ).apply {
                setOnImageAvailableListener({ reader ->
                    val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
                    processCameraFrame(image)
                }, cameraHandler)
            }

            manager.openCamera(
                selectedId,
                object : CameraDevice.StateCallback() {
                    override fun onOpened(camera: CameraDevice) {
                        cameraDevice = camera
                        createPreviewSession(camera)
                    }

                    override fun onDisconnected(camera: CameraDevice) {
                        camera.close()
                        cameraDevice = null
                    }

                    override fun onError(camera: CameraDevice, error: Int) {
                        camera.close()
                        cameraDevice = null
                        runOnUiThread {
                            statusHintText.text = "相机启动失败，可改用相册选取二维码"
                        }
                    }
                },
                cameraHandler,
            )
        } catch (_: SecurityException) {
            statusHintText.text = "未开启相机权限，可从相册选取二维码截图"
        } catch (_: Exception) {
            statusHintText.text = "无法打开相机，请从相册选取二维码图片"
        }
    }

    private fun createPreviewSession(camera: CameraDevice) {
        val surfaceTexture = textureView.surfaceTexture ?: return
        surfaceTexture.setDefaultBufferSize(previewSize.width, previewSize.height)
        val previewSurface = Surface(surfaceTexture)
        val readerSurface = imageReader?.surface ?: return

        try {
            val builder = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                addTarget(previewSurface)
                addTarget(readerSurface)
                set(
                    CaptureRequest.CONTROL_AF_MODE,
                    CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE,
                )
                set(
                    CaptureRequest.FLASH_MODE,
                    if (torchOn && hasFlash) CaptureRequest.FLASH_MODE_TORCH else CaptureRequest.FLASH_MODE_OFF,
                )
            }
            previewBuilder = builder

            val stateCallback = object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    if (cameraDevice == null) return
                    captureSession = session
                    try {
                        session.setRepeatingRequest(builder.build(), null, cameraHandler)
                    } catch (_: Exception) {
                    }
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {}
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val outputs = listOf(
                    OutputConfiguration(previewSurface),
                    OutputConfiguration(readerSurface),
                )
                val config = SessionConfiguration(
                    SessionConfiguration.SESSION_REGULAR,
                    outputs,
                    { runnable -> cameraHandler?.post(runnable) },
                    stateCallback,
                )
                camera.createCaptureSession(config)
            } else {
                @Suppress("DEPRECATION")
                camera.createCaptureSession(
                    listOf(previewSurface, readerSurface),
                    stateCallback,
                    cameraHandler,
                )
            }
        } catch (_: Exception) {
        }
    }

    private fun toggleTorch() {
        if (!hasFlash) return
        val session = captureSession ?: return
        val builder = previewBuilder ?: return
        torchOn = !torchOn
        torchButton.text = if (torchOn) "补光灯: 开" else "补光灯: 关"
        try {
            builder.set(
                CaptureRequest.FLASH_MODE,
                if (torchOn) CaptureRequest.FLASH_MODE_TORCH else CaptureRequest.FLASH_MODE_OFF,
            )
            session.setRepeatingRequest(builder.build(), null, cameraHandler)
        } catch (_: Exception) {
        }
    }

    private fun closeCamera() {
        try {
            captureSession?.close()
        } catch (_: Exception) {
        }
        captureSession = null
        try {
            cameraDevice?.close()
        } catch (_: Exception) {
        }
        cameraDevice = null
        try {
            imageReader?.close()
        } catch (_: Exception) {
        }
        imageReader = null
        previewBuilder = null
    }

    private fun processCameraFrame(image: Image) {
        if (deliveredResult.get()) {
            image.close()
            return
        }
        val now = SystemClock.elapsedRealtime()
        if (now - lastDecodeAttemptMs < 130L) {
            image.close()
            return
        }
        lastDecodeAttemptMs = now

        val width = image.width
        val height = image.height
        val yData = extractYPlane(image)
        image.close()
        if (yData == null) return

        val invert = invertNextFrame
        invertNextFrame = !invertNextFrame

        decodeExecutor.execute {
            if (deliveredResult.get()) return@execute
            try {
                val baseSource = PlanarYUVLuminanceSource(
                    yData,
                    width,
                    height,
                    0,
                    0,
                    width,
                    height,
                    false,
                )
                val source = if (invert) baseSource.invert() else baseSource
                val bitmap = BinaryBitmap(HybridBinarizer(source))
                val decoded = qrReader.decodeWithState(bitmap)
                deliverQrText(decoded.text)
            } catch (_: Exception) {
                qrReader.reset()
            }
        }
    }

    private fun extractYPlane(image: Image): ByteArray? {
        val plane = image.planes.firstOrNull() ?: return null
        val width = image.width
        val height = image.height
        val buffer = plane.buffer
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride

        val out = ByteArray(width * height)
        if (pixelStride == 1 && rowStride == width) {
            buffer.get(out, 0, out.size)
            return out
        }

        val rowBuffer = ByteArray(rowStride)
        for (row in 0 until height) {
            val remaining = buffer.remaining()
            if (remaining <= 0) break
            val toRead = min(rowStride, remaining)
            buffer.get(rowBuffer, 0, toRead)
            val rowOffset = row * width
            if (pixelStride == 1) {
                System.arraycopy(rowBuffer, 0, out, rowOffset, min(width, toRead))
            } else {
                for (col in 0 until width) {
                    val srcIdx = col * pixelStride
                    if (srcIdx < toRead) {
                        out[rowOffset + col] = rowBuffer[srcIdx]
                    }
                }
            }
        }
        return out
    }

    private fun launchGalleryQrPicker() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Intent(MediaStore.ACTION_PICK_IMAGES).apply { type = "image/*" }
        } else {
            Intent(Intent.ACTION_GET_CONTENT).apply {
                type = "image/*"
                addCategory(Intent.CATEGORY_OPENABLE)
            }
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQ_PICK_QR_IMAGE)
        } catch (_: Exception) {
            val fallback = Intent(Intent.ACTION_GET_CONTENT).apply {
                type = "image/*"
                addCategory(Intent.CATEGORY_OPENABLE)
            }
            @Suppress("DEPRECATION")
            startActivityForResult(fallback, REQ_PICK_QR_IMAGE)
        }
    }

    @Deprecated("Compatibility across API 24+")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_PICK_QR_IMAGE && resultCode == Activity.RESULT_OK) {
            val uri = data?.data ?: return
            decodeExecutor.execute {
                val decoded = decodeQrFromImageUri(uri)
                runOnUiThread {
                    if (decoded != null) {
                        deliverQrText(decoded)
                    } else {
                        statusHintText.text = "未能从所选图片中识别到有效二维码"
                    }
                }
            }
        }
    }

    private fun decodeQrFromImageUri(uri: Uri): String? {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            contentResolver.openInputStream(uri)?.use {
                BitmapFactory.decodeStream(it, null, bounds)
            }
            var sampleSize = 1
            while (max(bounds.outWidth / sampleSize, bounds.outHeight / sampleSize) > 1600) {
                sampleSize *= 2
            }
            val opts = BitmapFactory.Options().apply { inSampleSize = sampleSize }
            val bitmap = contentResolver.openInputStream(uri)?.use {
                BitmapFactory.decodeStream(it, null, opts)
            } ?: return null

            val w = bitmap.width
            val h = bitmap.height
            val pixels = IntArray(w * h)
            bitmap.getPixels(pixels, 0, w, 0, 0, w, h)
            bitmap.recycle()

            val rgbSource = RGBLuminanceSource(w, h, pixels)
            for (candidate in listOf(rgbSource, rgbSource.invert())) {
                try {
                    val result = qrReader.decodeWithState(BinaryBitmap(HybridBinarizer(candidate)))
                    if (!result.text.isNullOrBlank()) {
                        return result.text
                    }
                } catch (_: Exception) {
                    qrReader.reset()
                }
            }
            null
        } catch (_: Exception) {
            null
        }
    }

    private fun deliverQrText(text: String?) {
        val clean = text?.trim()
        if (clean.isNullOrEmpty()) return
        if (!deliveredResult.compareAndSet(false, true)) return
        runOnUiThread {
            setResult(
                Activity.RESULT_OK,
                Intent().putExtra(EXTRA_QR_RESULT, clean),
            )
            finish()
        }
    }

    private fun selectCameraId(manager: CameraManager): String? {
        var fallback: String? = null
        for (id in manager.cameraIdList) {
            if (fallback == null) fallback = id
            val chars = manager.getCameraCharacteristics(id)
            if (chars.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK) {
                return id
            }
        }
        return fallback
    }

    private fun chooseBestSize(
        choices: Array<Size>?,
        targetWidth: Int,
        targetHeight: Int,
    ): Size {
        if (choices == null || choices.isEmpty()) return Size(targetWidth, targetHeight)
        val targetArea = targetWidth * targetHeight
        return choices.minByOrNull { size ->
            val areaDiff = abs(size.width * size.height - targetArea)
            val ratioDiff = abs(
                (size.width.toFloat() / size.height.toFloat()) -
                    (targetWidth.toFloat() / targetHeight.toFloat()),
            )
            areaDiff + (ratioDiff * 400_000).toInt()
        } ?: choices.first()
    }

    private fun configureTextureTransform(viewWidth: Int, viewHeight: Int) {
        if (viewWidth == 0 || viewHeight == 0) return
        val rotation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            display?.rotation ?: Surface.ROTATION_0
        } else {
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay.rotation
        }

        val matrix = Matrix()
        val viewRect = RectF(0f, 0f, viewWidth.toFloat(), viewHeight.toFloat())
        val bufferRect = RectF(0f, 0f, previewSize.height.toFloat(), previewSize.width.toFloat())
        val centerX = viewRect.centerX()
        val centerY = viewRect.centerY()

        if (Surface.ROTATION_90 == rotation || Surface.ROTATION_270 == rotation) {
            bufferRect.offset(centerX - bufferRect.centerX(), centerY - bufferRect.centerY())
            matrix.setRectToRect(viewRect, bufferRect, Matrix.ScaleToFit.FILL)
            val scale = max(
                viewHeight.toFloat() / previewSize.height.toFloat(),
                viewWidth.toFloat() / previewSize.width.toFloat(),
            )
            matrix.postScale(scale, scale, centerX, centerY)
            matrix.postRotate((90 * (rotation - 2)).toFloat(), centerX, centerY)
        } else {
            val previewRatio = previewSize.height.toFloat() / previewSize.width.toFloat()
            val viewRatio = viewWidth.toFloat() / viewHeight.toFloat()
            val sx: Float
            val sy: Float
            if (viewRatio < previewRatio) {
                sx = previewRatio / viewRatio
                sy = 1f
            } else {
                sx = 1f
                sy = viewRatio / previewRatio
            }
            matrix.setScale(sx, sy, centerX, centerY)
            if (Surface.ROTATION_180 == rotation) {
                matrix.postRotate(180f, centerX, centerY)
            }
        }
        textureView.setTransform(matrix)
    }

    private fun dp(value: Int): Int {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            resources.displayMetrics,
        ).roundToInt()
    }
}

private class ScannerOverlayView(context: Context) : View(context) {
    private val scrimPaint = Paint().apply {
        color = Color.parseColor("#88000000")
        style = Paint.Style.FILL
    }
    private val clearPaint = Paint().apply {
        xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR)
    }
    private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#818CF8")
        style = Paint.Style.STROKE
        strokeWidth = 6f
    }
    private val laserPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#38BDF8")
        style = Paint.Style.STROKE
        strokeWidth = 5f
    }

    private var scanProgress = 0f
    private var animator: ValueAnimator? = null

    init {
        setLayerType(LAYER_TYPE_SOFTWARE, null)
    }

    fun startScanAnimation() {
        if (animator != null) return
        animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 2100L
            repeatMode = ValueAnimator.REVERSE
            repeatCount = ValueAnimator.INFINITE
            interpolator = LinearInterpolator()
            addUpdateListener {
                scanProgress = it.animatedValue as Float
                invalidate()
            }
            start()
        }
    }

    fun stopScanAnimation() {
        animator?.cancel()
        animator = null
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0f || h <= 0f) return

        val boxSize = min(w, h) * 0.66f
        val left = (w - boxSize) * 0.5f
        val top = (h - boxSize) * 0.44f
        val rect = RectF(left, top, left + boxSize, top + boxSize)

        canvas.drawRect(0f, 0f, w, h, scrimPaint)
        canvas.drawRoundRect(rect, 32f, 32f, clearPaint)

        val cornerLen = boxSize * 0.14f
        // Top-left
        canvas.drawLine(rect.left, rect.top + cornerLen, rect.left, rect.top, borderPaint)
        canvas.drawLine(rect.left, rect.top, rect.left + cornerLen, rect.top, borderPaint)
        // Top-right
        canvas.drawLine(rect.right - cornerLen, rect.top, rect.right, rect.top, borderPaint)
        canvas.drawLine(rect.right, rect.top, rect.right, rect.top + cornerLen, borderPaint)
        // Bottom-left
        canvas.drawLine(rect.left, rect.bottom - cornerLen, rect.left, rect.bottom, borderPaint)
        canvas.drawLine(rect.left, rect.bottom, rect.left + cornerLen, rect.bottom, borderPaint)
        // Bottom-right
        canvas.drawLine(rect.right - cornerLen, rect.bottom, rect.right, rect.bottom, borderPaint)
        canvas.drawLine(rect.right, rect.bottom - cornerLen, rect.right, rect.bottom, borderPaint)

        val scanY = rect.top + 24f + (rect.height() - 48f) * scanProgress
        canvas.drawLine(rect.left + 20f, scanY, rect.right - 20f, scanY, laserPaint)
    }
}
