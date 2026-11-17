package com.thiagobenevide.agent.recording

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.ColorSpaceTransform
import android.hardware.camera2.params.DynamicRangeProfiles
import android.hardware.camera2.params.MeteringRectangle
import android.hardware.camera2.params.RggbChannelVector
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.StreamConfigurationMap
import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaRecorder
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.PowerManager
import android.util.Range
import android.util.Size
import android.view.Surface
import android.view.WindowManager
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * Pro camera of the Recording module (channel `agent/empreendimento/camera`). Back cameras only: opens
 * the camera into a Flutter texture (preview) and, on `start`, plugs in the [Streamer] (encoder ->
 * PC over TCP and local MP4). Manual settings (ISO, shutter, focus, white balance, zoom) go into the
 * session repeating request.
 */
class CameraProPlugin(
    private val activity: Activity,
    private val textures: TextureRegistry,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val context: Context get() = activity.applicationContext
    private val manager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private val thread = HandlerThread("camera-pro").apply { start() }
    private val handler = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())

    private var events: EventChannel.EventSink? = null
    private var permissionResult: MethodChannel.Result? = null

    private var camera: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var texture: TextureRegistry.SurfaceTextureEntry? = null
    private var preview: Surface? = null
    private var characteristics: CameraCharacteristics? = null
    private var width = 1920
    private var height = 1080
    private var fps = 60
    private var hlg = false
    private var settings: Map<String, Any?> = emptyMap()
    @Volatile private var colorTransform: ColorSpaceTransform? = null
    @Volatile private var autoGains: RggbChannelVector? = null
    private var streamer: Streamer? = null
    private var multicast: WifiManager.MulticastLock? = null

    // measurements of the last second, read by the state clock
    @Volatile private var frames = 0
    @Volatile private var currentIso = 0
    @Volatile private var currentExposure = 0L
    @Volatile private var currentFocus = 0.0

    private val clock = object : Runnable {
        override fun run() {
            emitState()
            handler.postDelayed(this, 1000)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "requestPermission" -> requestPermission(result)
                "cameras" -> result.success(cameras())
                "open" -> open(call, result)
                "adjust" -> {
                    @Suppress("UNCHECKED_CAST")
                    settings = (call.arguments as? Map<String, Any?>) ?: emptyMap()
                    handler.post { applyRequest() }
                    result.success(null)
                }
                "publish" -> {
                    streamer?.sendControl(call.argument<String>("json") ?: "{}")
                    result.success(null)
                }
                "start" -> start(call, result)
                "stop" -> stop(result)
                "close" -> {
                    close()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("camera", e.message ?: e.toString(), null)
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    // ---------------------------------------------------------------- permissions

    private fun requestPermission(result: MethodChannel.Result) {
        val missing = arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
            .filter { activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) {
            result.success(true)
            return
        }
        permissionResult = result
        activity.requestPermissions(missing.toTypedArray(), PERMISSION_CODE)
    }

    /** Called by MainActivity. */
    fun onPermissionResult(code: Int): Boolean {
        if (code != PERMISSION_CODE) return false
        val granted = activity.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        permissionResult?.success(granted)
        permissionResult = null
        return true
    }

    // ---------------------------------------------------------------- capabilities

    private fun cameras(): List<Map<String, Any?>> {
        val list = mutableListOf<Map<String, Any?>>()
        for (id in manager.cameraIdList) {
            val c = manager.getCameraCharacteristics(id)
            if (c.get(CameraCharacteristics.LENS_FACING) == CameraMetadata.LENS_FACING_FRONT) continue
            val info = describe(id, c) ?: continue
            list.add(info)
        }
        return list
    }

    /**
     * Preview buffer size: the video size (e.g. 4K) is usually not a valid SurfaceTexture size, and
     * then the camera delivers another size and aspect that ends up stretched on screen. Picks the
     * largest supported preview size (up to 1920 wide) with the same aspect as the video.
     */
    private fun previewSizeFor(c: CameraCharacteristics, videoWidth: Int, videoHeight: Int): Size {
        val map = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: return Size(videoWidth, videoHeight)
        var best: Size? = null
        for (size in map.getOutputSizes(SurfaceTexture::class.java)) {
            if (size.width > 1920 || size.width.toLong() * videoHeight != size.height.toLong() * videoWidth) continue
            if (best == null || size.width > best.width) best = size
        }
        return best ?: Size(videoWidth, videoHeight)
    }

    /** Shortest frame duration among the video surfaces: some phones only report 60 fps for one. */
    private fun fastestFrame(map: StreamConfigurationMap, size: Size): Long {
        var best = 0L
        for (kind in listOf(MediaCodec::class.java, MediaRecorder::class.java)) {
            val duration = try {
                map.getOutputMinFrameDuration(kind, size)
            } catch (_: IllegalArgumentException) {
                0L
            }
            if (duration > 0 && (best == 0L || duration < best)) best = duration
        }
        return best
    }

    private fun describe(id: String, c: CameraCharacteristics): Map<String, Any?>? {
        val map = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return null
        val capabilities = c.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)?.toList() ?: emptyList()
        // 16:9 only, largest first, with the top fps the sensor delivers at that size
        val sizes = mutableListOf<Map<String, Int>>()
        val ordered = map.getOutputSizes(MediaCodec::class.java).sortedByDescending { it.width }
        for (size in ordered) {
            if (size.width < 1280 || size.width * 9 != size.height * 16) continue
            val minimum = fastestFrame(map, size)
            // rounded: 16 666 667 ns is 60 fps, and the integer division gave 59 (60 fps never offered)
            val maxFps = if (minimum > 0) Math.round(1_000_000_000.0 / minimum).toInt() else 30
            sizes.add(mapOf("width" to size.width, "height" to size.height, "maxFps" to maxFps))
        }
        val fpsList = c.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            ?.map { it.upper }?.distinct()?.sorted() ?: listOf(30)
        val iso = c.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
        val exposure = c.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)
        val ev = c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
        val evStep = c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP)
        var zoom: Range<Float>? = null
        if (Build.VERSION.SDK_INT >= 30) zoom = c.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)
        val zoomMax = zoom?.upper ?: c.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f
        val ois = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION)
            ?.contains(CameraMetadata.LENS_OPTICAL_STABILIZATION_MODE_ON) == true
        val eis = c.get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES)
            ?.contains(CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_ON) == true
        return mapOf(
            "id" to id,
            "focal" to (c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.firstOrNull() ?: 0f).toDouble(),
            "external" to (c.get(CameraCharacteristics.LENS_FACING) == CameraMetadata.LENS_FACING_EXTERNAL),
            "level" to (c.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL) ?: 0),
            "sizes" to sizes,
            "fps" to fpsList,
            "manual" to capabilities.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR),
            "isoMin" to (iso?.lower ?: 100),
            "isoMax" to (iso?.upper ?: 100),
            "exposureMinNs" to (exposure?.lower ?: 0L),
            "exposureMaxNs" to (exposure?.upper ?: 0L),
            "evMin" to (ev?.lower ?: 0),
            "evMax" to (ev?.upper ?: 0),
            "evStep" to (evStep?.toDouble() ?: 0.0),
            "focusMin" to (c.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE) ?: 0f).toDouble(),
            "zoomMin" to (zoom?.lower ?: 1f).toDouble(),
            "zoomMax" to zoomMax.toDouble(),
            "ois" to ois,
            "eis" to eis,
            "hlg" to supportsHlg(c, capabilities),
            // white balance by temperature needs the app to set the color gains itself
            "kelvin" to capabilities.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_POST_PROCESSING),
            "point" to ((c.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AF) ?: 0) > 0 ||
                (c.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AE) ?: 0) > 0),
            "hevc" to hasEncoder(MediaFormat.MIMETYPE_VIDEO_HEVC),
            "orientation" to (c.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90),
        )
    }

    private fun supportsHlg(c: CameraCharacteristics, capabilities: List<Int>): Boolean {
        if (Build.VERSION.SDK_INT < 33) return false
        if (!capabilities.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_DYNAMIC_RANGE_TEN_BIT)) return false
        val profiles = c.get(CameraCharacteristics.REQUEST_AVAILABLE_DYNAMIC_RANGE_PROFILES) ?: return false
        return profiles.supportedProfiles.contains(DynamicRangeProfiles.HLG10) &&
            hasEncoder(MediaFormat.MIMETYPE_VIDEO_HEVC)
    }

    private fun hasEncoder(mime: String): Boolean {
        for (info in MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos) {
            if (!info.isEncoder) continue
            for (type in info.supportedTypes) {
                if (type.equals(mime, ignoreCase = true)) return true
            }
        }
        return false
    }

    // ---------------------------------------------------------------- open / session

    private fun open(call: MethodCall, result: MethodChannel.Result) {
        if (activity.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            result.error("permission", "No camera permission", null)
            return
        }
        if (streamer != null) {
            result.error("busy", "Stop the stream before switching the camera", null)
            return
        }
        closeCamera()
        val id = call.argument<String>("id") ?: manager.cameraIdList.first()
        width = call.argument<Int>("width") ?: 1920
        height = call.argument<Int>("height") ?: 1080
        fps = call.argument<Int>("fps") ?: 60
        hlg = call.argument<Boolean>("hlg") ?: false
        characteristics = manager.getCameraCharacteristics(id)

        val entry = textures.createSurfaceTexture()
        val previewSize = previewSizeFor(characteristics!!, width, height)
        entry.surfaceTexture().setDefaultBufferSize(previewSize.width, previewSize.height)
        texture = entry
        preview = Surface(entry.surfaceTexture())

        if (multicast == null) {
            val wifi = context.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicast = wifi.createMulticastLock("solumia-camera").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        manager.openCamera(id, OpenCallback(entry.id(), result), handler)
    }

    private inner class OpenCallback(
        private val textureId: Long,
        private val result: MethodChannel.Result,
    ) : CameraDevice.StateCallback() {
        private var answered = false

        override fun onOpened(device: CameraDevice) {
            camera = device
            configureSession()
            handler.removeCallbacks(clock)
            handler.post(clock)
            answer { result.success(textureId) }
        }

        override fun onDisconnected(device: CameraDevice) {
            device.close()
            if (camera == device) camera = null
            emit(mapOf("type" to "error", "message" to "Camera disconnected (another app took it?)"))
        }

        override fun onError(device: CameraDevice, error: Int) {
            device.close()
            if (camera == device) camera = null
            if (answered) {
                emit(mapOf("type" to "error", "message" to "Camera error ($error)"))
            } else {
                answer { result.error("camera", "Could not open the camera ($error)", null) }
            }
        }

        private fun answer(reply: () -> Unit) {
            if (answered) return
            answered = true
            main.post(reply)
        }
    }

    /** Rebuilds the session with the preview and, if any, the encoder surface. Camera thread. */
    private fun configureSession() {
        val device = camera ?: return
        val previewSurface = preview ?: return
        session?.close()
        session = null
        val outputs = mutableListOf(previewSurface)
        streamer?.surface?.let { outputs.add(it) }
        val configurations = outputs.map { surface ->
            OutputConfiguration(surface).apply {
                if (hlg && Build.VERSION.SDK_INT >= 33) dynamicRangeProfile = DynamicRangeProfiles.HLG10
            }
        }
        @Suppress("DEPRECATION")
        device.createCaptureSessionByOutputConfigurations(configurations, SessionCallback(), handler)
    }

    private inner class SessionCallback : CameraCaptureSession.StateCallback() {
        override fun onConfigured(s: CameraCaptureSession) {
            session = s
            applyRequest()
        }

        override fun onConfigureFailed(s: CameraCaptureSession) {
            if (hlg) {
                // not every phone takes HLG on the preview and the encoder together: fall back to 8-bit
                hlg = false
                emit(mapOf("type" to "warning", "message" to "HLG 10-bit refused in this combination; using 8-bit"))
                handler.post { configureSession() }
            } else {
                emit(mapOf("type" to "error", "message" to "The camera refused the configuration (size/fps)"))
            }
        }
    }

    private val captureCallback = object : CameraCaptureSession.CaptureCallback() {
        override fun onCaptureCompleted(s: CameraCaptureSession, request: CaptureRequest, result: TotalCaptureResult) {
            frames++
            currentIso = result.get(CaptureResult.SENSOR_SENSITIVITY) ?: currentIso
            currentExposure = result.get(CaptureResult.SENSOR_EXPOSURE_TIME) ?: currentExposure
            // the camera's own color matrix, kept for manual white balance (only the gains change)
            if (settings["awb"] != "manual") {
                result.get(CaptureResult.COLOR_CORRECTION_TRANSFORM)?.let { colorTransform = it }
                result.get(CaptureResult.COLOR_CORRECTION_GAINS)?.let { autoGains = it }
            }
            currentFocus = (result.get(CaptureResult.LENS_FOCUS_DISTANCE) ?: currentFocus.toFloat()).toDouble()
        }
    }

    private fun applyRequest() {
        val s = session ?: return
        val device = camera ?: return
        val c = characteristics ?: return
        val previewSurface = preview ?: return
        val active = streamer
        try {
            val template = if (active != null) CameraDevice.TEMPLATE_RECORD else CameraDevice.TEMPLATE_PREVIEW
            val request = device.createCaptureRequest(template)
            request.addTarget(previewSurface)
            active?.surface?.let { request.addTarget(it) }
            request.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
            request.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fpsRange(c))
            applyExposure(request)
            applyWhiteBalance(request)
            applyFocus(request, c)
            applyZoom(request, c)
            applyImage(request, c)
            s.setRepeatingRequest(request.build(), captureCallback, handler)
        } catch (e: Exception) {
            emit(mapOf("type" to "error", "message" to "Setting refused: ${e.message}"))
        }
    }

    /**
     * AE range for the chosen fps: a range the camera does not list is ignored (it falls back to 30).
     * Prefers the fixed one ([60,60]), then the narrowest that tops at the fps ([30,60]).
     */
    private fun fpsRange(c: CameraCharacteristics): Range<Int> {
        val ranges = c.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
        var best: Range<Int>? = null
        if (ranges != null) {
            for (range in ranges) {
                if (range.upper != fps) continue
                if (best == null || range.lower > best.lower) best = range
            }
        }
        return best ?: Range(fps, fps)
    }

    private fun applyExposure(request: CaptureRequest.Builder) {
        val frameNs = 1_000_000_000L / fps
        if (bool("manualExposure")) {
            request.set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_OFF)
            request.set(CaptureRequest.SENSOR_SENSITIVITY, int("iso", 100))
            request.set(CaptureRequest.SENSOR_EXPOSURE_TIME, minOf(long("exposureNs", frameNs / 2), frameNs))
            request.set(CaptureRequest.SENSOR_FRAME_DURATION, frameNs)
            return
        }
        request.set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_ON)
        request.set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, int("compensation", 0))
        request.set(CaptureRequest.CONTROL_AE_LOCK, bool("lockAe"))
        request.set(CaptureRequest.CONTROL_AE_ANTIBANDING_MODE, CameraMetadata.CONTROL_AE_ANTIBANDING_MODE_AUTO)
    }

    private fun applyWhiteBalance(request: CaptureRequest.Builder) {
        if (settings["awb"] == "manual") {
            applyKelvin(request, characteristics ?: return, int("kelvin", 5000))
            return
        }
        val mode = when (settings["awb"]) {
            "incandescent" -> CameraMetadata.CONTROL_AWB_MODE_INCANDESCENT
            "fluorescent" -> CameraMetadata.CONTROL_AWB_MODE_FLUORESCENT
            "daylight" -> CameraMetadata.CONTROL_AWB_MODE_DAYLIGHT
            "cloudy" -> CameraMetadata.CONTROL_AWB_MODE_CLOUDY_DAYLIGHT
            "shade" -> CameraMetadata.CONTROL_AWB_MODE_SHADE
            else -> CameraMetadata.CONTROL_AWB_MODE_AUTO
        }
        request.set(CaptureRequest.CONTROL_AWB_MODE, mode)
        request.set(CaptureRequest.CONTROL_AWB_LOCK, bool("lockAwb"))
    }

    /**
     * White balance by color temperature: AWB off and channel gains that turn light of [kelvin] neutral.
     * The color matrix stays the one the camera was using, so only the white point changes.
     */
    private fun applyKelvin(request: CaptureRequest.Builder, c: CameraCharacteristics, kelvin: Int) {
        val gains = calibratedGains(c, kelvin) ?: relativeGains(kelvin)
        request.set(CaptureRequest.CONTROL_AWB_MODE, CameraMetadata.CONTROL_AWB_MODE_OFF)
        request.set(CaptureRequest.COLOR_CORRECTION_MODE, CameraMetadata.COLOR_CORRECTION_MODE_TRANSFORM_MATRIX)
        request.set(CaptureRequest.COLOR_CORRECTION_GAINS, gains)
        request.set(CaptureRequest.COLOR_CORRECTION_TRANSFORM, colorTransform ?: IDENTITY)
    }

    /**
     * Gains from the sensor calibration (the DNG way): the XYZ -> camera matrices the camera reports for
     * two reference lights are interpolated in mireds for [kelvin], the black-body white at [kelvin] goes
     * through it and the gains make that camera color neutral. The gains act on raw sensor values, so a
     * plain RGB formula would come out green.
     */
    private fun calibratedGains(c: CameraCharacteristics, kelvin: Int): RggbChannelVector? {
        val transform1 = c.get(CameraCharacteristics.SENSOR_COLOR_TRANSFORM1) ?: return null
        val transform2 = c.get(CameraCharacteristics.SENSOR_COLOR_TRANSFORM2) ?: return null
        val kelvin1 = illuminantKelvin(c.get(CameraCharacteristics.SENSOR_REFERENCE_ILLUMINANT1)?.toInt(), 2856.0)
        val kelvin2 = illuminantKelvin(c.get(CameraCharacteristics.SENSOR_REFERENCE_ILLUMINANT2)?.toInt(), 6504.0)
        val m1 = multiply(matrix(c.get(CameraCharacteristics.SENSOR_CALIBRATION_TRANSFORM1)), matrix(transform1))
        val m2 = multiply(matrix(c.get(CameraCharacteristics.SENSOR_CALIBRATION_TRANSFORM2)), matrix(transform2))
        val inverse = 1.0 / kelvin
        val span = 1.0 / kelvin1 - 1.0 / kelvin2
        val weight = if (span == 0.0) 0.5 else ((inverse - 1.0 / kelvin2) / span).coerceIn(0.0, 1.0)
        val xyz = planckXyz(kelvin.toDouble())
        val camera = DoubleArray(3)
        for (row in 0 until 3) {
            var sum = 0.0
            for (col in 0 until 3) {
                sum += (weight * m1[row * 3 + col] + (1 - weight) * m2[row * 3 + col]) * xyz[col]
            }
            camera[row] = sum
        }
        if (camera[0] <= 0 || camera[1] <= 0 || camera[2] <= 0) return null
        val red = (camera[1] / camera[0]).coerceIn(0.25, 8.0).toFloat()
        val blue = (camera[1] / camera[2]).coerceIn(0.25, 8.0).toFloat()
        return RggbChannelVector(red, 1f, 1f, blue)
    }

    /** No calibration data: the last automatic gains taken as 5500 K, shifted by the black-body ratio. */
    private fun relativeGains(kelvin: Int): RggbChannelVector {
        val base = autoGains ?: RggbChannelVector(2f, 1f, 1f, 1.6f)
        val (r0, g0, b0) = kelvinToRgb(5500)
        val (r, g, b) = kelvinToRgb(kelvin)
        val red = (base.red * (r0 / g0) / (r / g)).coerceIn(0.25, 8.0).toFloat()
        val blue = (base.blue * (b0 / g0) / (b / g)).coerceIn(0.25, 8.0).toFloat()
        return RggbChannelVector(red, base.greenEven, base.greenOdd, blue)
    }

    private fun applyFocus(request: CaptureRequest.Builder, c: CameraCharacteristics) {
        if (bool("manualFocus")) {
            request.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_OFF)
            request.set(CaptureRequest.LENS_FOCUS_DISTANCE, double("focus", 0.0).toFloat())
        } else {
            request.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
        }
        applyPoint(request, c)
    }

    /** Focus and metering on the chosen point (video coordinates 0..1), 1/8 of the frame wide. */
    private fun applyPoint(request: CaptureRequest.Builder, c: CameraCharacteristics) {
        val x = double("pointX", -1.0)
        val y = double("pointY", -1.0)
        if (x < 0 || y < 0) return
        val area = c.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE) ?: return
        // before Android 11 the zoom is a crop of the full array and the regions use full-array pixels;
        // with CONTROL_ZOOM_RATIO they are already relative to the zoomed view
        var left = area.left.toDouble()
        var top = area.top.toDouble()
        var width = area.width().toDouble()
        var height = area.height().toDouble()
        val zoom = double("zoom", 1.0)
        if (Build.VERSION.SDK_INT < 30 && zoom > 1) {
            left += width * (1 - 1 / zoom) / 2
            top += height * (1 - 1 / zoom) / 2
            width /= zoom
            height /= zoom
        }
        val side = (width / 8).toInt()
        val cx = (left + x.coerceIn(0.0, 1.0) * width).toInt()
        val cy = (top + y.coerceIn(0.0, 1.0) * height).toInt()
        val rx = (cx - side / 2).coerceIn(area.left, area.right - side)
        val ry = (cy - side / 2).coerceIn(area.top, area.bottom - side)
        val region = arrayOf(MeteringRectangle(rx, ry, side, side, MeteringRectangle.METERING_WEIGHT_MAX))
        if ((c.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AF) ?: 0) > 0 && !bool("manualFocus")) {
            request.set(CaptureRequest.CONTROL_AF_REGIONS, region)
        }
        if ((c.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AE) ?: 0) > 0 && !bool("manualExposure")) {
            request.set(CaptureRequest.CONTROL_AE_REGIONS, region)
        }
    }

    /** Below 1x = ultra-wide on phones that merge the lenses into one logical camera. */
    private fun applyZoom(request: CaptureRequest.Builder, c: CameraCharacteristics) {
        val zoom = double("zoom", 1.0).toFloat()
        if (Build.VERSION.SDK_INT >= 30) {
            request.set(CaptureRequest.CONTROL_ZOOM_RATIO, zoom)
            return
        }
        if (zoom <= 1f) return
        val area = c.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE) ?: return
        val w = (area.width() / zoom).toInt()
        val h = (area.height() / zoom).toInt()
        val x = (area.width() - w) / 2
        val y = (area.height() - h) / 2
        request.set(CaptureRequest.SCALER_CROP_REGION, Rect(x, y, x + w, y + h))
    }

    private fun applyImage(request: CaptureRequest.Builder, c: CameraCharacteristics) {
        // optical stabilization whenever present; the electronic one crops the image, only on demand
        val stabilization = if (bool("stabilization")) {
            CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_ON
        } else {
            CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_OFF
        }
        request.set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, stabilization)
        val ois = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION)
            ?.contains(CameraMetadata.LENS_OPTICAL_STABILIZATION_MODE_ON) == true
        if (ois) {
            request.set(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE, CameraMetadata.LENS_OPTICAL_STABILIZATION_MODE_ON)
        }
        val torch = if (bool("torch")) CameraMetadata.FLASH_MODE_TORCH else CameraMetadata.FLASH_MODE_OFF
        request.set(CaptureRequest.FLASH_MODE, torch)
        request.set(CaptureRequest.NOISE_REDUCTION_MODE, when (settings["noise"]) {
            "off" -> CameraMetadata.NOISE_REDUCTION_MODE_OFF
            "quality" -> CameraMetadata.NOISE_REDUCTION_MODE_HIGH_QUALITY
            else -> CameraMetadata.NOISE_REDUCTION_MODE_FAST
        })
        request.set(CaptureRequest.EDGE_MODE, when (settings["edge"]) {
            "off" -> CameraMetadata.EDGE_MODE_OFF
            "quality" -> CameraMetadata.EDGE_MODE_HIGH_QUALITY
            else -> CameraMetadata.EDGE_MODE_FAST
        })
    }

    // ---------------------------------------------------------------- streaming

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        if (camera == null) {
            result.error("camera", "Open the camera first", null)
            return
        }
        if (streamer != null) {
            result.success(null)
            return
        }
        val timestampSource = characteristics?.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE)
        streamer = Streamer(
            context = context,
            width = width,
            height = height,
            fps = fps,
            hevc = call.argument<String>("codec") != "avc",
            bitrate = (call.argument<Int>("bitrateMbps") ?: 80) * 1_000_000,
            hlg = hlg,
            host = call.argument<String>("host")?.takeIf { it.isNotBlank() },
            port = call.argument<Int>("port") ?: 5600,
            recordLocal = call.argument<Boolean>("recordLocal") ?: true,
            withAudio = call.argument<Boolean>("audio") ?: true,
            realtimeClock = timestampSource == CameraMetadata.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME,
            onWarning = { emit(mapOf("type" to "warning", "message" to it)) },
            onRemote = { emit(mapOf("type" to "remote", "json" to it)) },
        )
        handler.post { configureSession() }
        result.success(null)
    }

    private fun stop(result: MethodChannel.Result) {
        val active = streamer
        if (active == null) {
            result.success(null)
            return
        }
        streamer = null
        handler.post {
            // take the encoder out of the session before closing it
            configureSession()
            Thread {
                val file = active.stop()
                main.post { result.success(file) }
            }.start()
        }
    }

    // ---------------------------------------------------------------- state / close

    private fun emitState() {
        val active = streamer
        var thermal = 0
        if (Build.VERSION.SDK_INT >= 29) {
            thermal = (context.getSystemService(Context.POWER_SERVICE) as PowerManager).currentThermalStatus
        }
        val measuredFps = frames
        frames = 0
        emit(
            mapOf(
                "type" to "state",
                "fps" to measuredFps,
                "iso" to currentIso,
                "exposureNs" to currentExposure,
                "focus" to currentFocus,
                "thermal" to thermal,
                "active" to (active != null),
                "connected" to (active?.connected ?: false),
                "mbps" to (active?.mbpsLastSecond() ?: 0.0),
                "seconds" to (active?.seconds() ?: 0),
                "file" to active?.fileName,
                "hlg" to hlg,
            ),
        )
    }

    private fun emit(event: Map<String, Any?>) {
        main.post { events?.success(event) }
    }

    private fun closeCamera() {
        handler.removeCallbacks(clock)
        session?.close()
        session = null
        camera?.close()
        camera = null
        preview?.release()
        preview = null
        texture?.release()
        texture = null
    }

    fun close() {
        streamer?.let { active ->
            streamer = null
            Thread { active.stop() }.start()
        }
        closeCamera()
        multicast?.release()
        multicast = null
        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    fun release() {
        close()
        thread.quitSafely()
    }

    private fun bool(key: String) = settings[key] as? Boolean ?: false
    private fun int(key: String, default: Int) = (settings[key] as? Number)?.toInt() ?: default
    private fun long(key: String, default: Long) = (settings[key] as? Number)?.toLong() ?: default
    private fun double(key: String, default: Double) = (settings[key] as? Number)?.toDouble() ?: default

    companion object {
        const val PERMISSION_CODE = 7301
    }
}

private val IDENTITY = ColorSpaceTransform(intArrayOf(1, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 0, 1, 1, 1))

/**
 * RGB (0..1) of a black body at [kelvin] (Tanner Helland's fit of the Planckian locus, 1000-40000 K):
 * good enough for camera white balance, which is what Samsung's Kelvin slider does as well.
 */
internal fun kelvinToRgb(kelvin: Int): Triple<Double, Double, Double> {
    val t = kelvin.coerceIn(1000, 40000) / 100.0
    val r = if (t <= 66) 255.0 else 329.698727446 * Math.pow(t - 60, -0.1332047592)
    val g = if (t <= 66) 99.4708025861 * Math.log(t) - 161.1195681661 else 288.1221695283 * Math.pow(t - 60, -0.0755148492)
    val b = when {
        t >= 66 -> 255.0
        t <= 19 -> 0.0
        else -> 138.5177312231 * Math.log(t - 10) - 305.0447927307
    }
    return Triple(r.coerceIn(1.0, 255.0) / 255, g.coerceIn(1.0, 255.0) / 255, b.coerceIn(1.0, 255.0) / 255)
}

/** Color temperature of the EXIF light sources the sensor calibration uses. */
internal fun illuminantKelvin(code: Int?, fallback: Double): Double = when (code) {
    CameraMetadata.SENSOR_REFERENCE_ILLUMINANT1_STANDARD_A, CameraMetadata.SENSOR_REFERENCE_ILLUMINANT1_TUNGSTEN -> 2856.0
    CameraMetadata.SENSOR_REFERENCE_ILLUMINANT1_D50 -> 5003.0
    CameraMetadata.SENSOR_REFERENCE_ILLUMINANT1_D55, CameraMetadata.SENSOR_REFERENCE_ILLUMINANT1_DAYLIGHT -> 5503.0
    CameraMetadata.SENSOR_REFERENCE_ILLUMINANT1_D65 -> 6504.0
    CameraMetadata.SENSOR_REFERENCE_ILLUMINANT1_D75, CameraMetadata.SENSOR_REFERENCE_ILLUMINANT1_SHADE -> 7504.0
    CameraMetadata.SENSOR_REFERENCE_ILLUMINANT1_STANDARD_B -> 4874.0
    CameraMetadata.SENSOR_REFERENCE_ILLUMINANT1_STANDARD_C -> 6774.0
    CameraMetadata.SENSOR_REFERENCE_ILLUMINANT1_CLOUDY_WEATHER -> 6500.0
    CameraMetadata.SENSOR_REFERENCE_ILLUMINANT1_FLUORESCENT, CameraMetadata.SENSOR_REFERENCE_ILLUMINANT1_COOL_WHITE_FLUORESCENT -> 4150.0
    CameraMetadata.SENSOR_REFERENCE_ILLUMINANT1_DAYLIGHT_FLUORESCENT -> 6430.0
    CameraMetadata.SENSOR_REFERENCE_ILLUMINANT1_DAY_WHITE_FLUORESCENT -> 5000.0
    CameraMetadata.SENSOR_REFERENCE_ILLUMINANT1_WHITE_FLUORESCENT -> 3525.0
    CameraMetadata.SENSOR_REFERENCE_ILLUMINANT1_ISO_STUDIO_TUNGSTEN -> 3200.0
    else -> fallback
}

/** Row-major 3x3 (identity when the camera does not report the matrix). */
internal fun matrix(transform: ColorSpaceTransform?): DoubleArray {
    val result = doubleArrayOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)
    if (transform == null) return result
    for (row in 0 until 3) {
        for (col in 0 until 3) {
            result[row * 3 + col] = transform.getElement(col, row).toDouble()
        }
    }
    return result
}

internal fun multiply(a: DoubleArray, b: DoubleArray): DoubleArray {
    val result = DoubleArray(9)
    for (row in 0 until 3) {
        for (col in 0 until 3) {
            var sum = 0.0
            for (k in 0 until 3) sum += a[row * 3 + k] * b[k * 3 + col]
            result[row * 3 + col] = sum
        }
    }
    return result
}

/** XYZ (Y = 1) of the black body at [kelvin], from the Planckian locus fit of Kim et al. (1667-25000 K). */
internal fun planckXyz(kelvin: Double): DoubleArray {
    val t = kelvin.coerceIn(1667.0, 25000.0)
    val x = if (t <= 4000) {
        -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
    } else {
        -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t) + 0.2226347e3 / t + 0.240390
    }
    val y = when {
        t <= 2222 -> -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
        t <= 4000 -> -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
        else -> 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
    }
    return doubleArrayOf(x / y, 1.0, (1 - x - y) / y)
}
