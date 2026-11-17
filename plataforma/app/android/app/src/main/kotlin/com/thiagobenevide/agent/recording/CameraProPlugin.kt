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
import android.hardware.camera2.params.DynamicRangeProfiles
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
            applyFocus(request)
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

    private fun applyFocus(request: CaptureRequest.Builder) {
        if (bool("manualFocus")) {
            request.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_OFF)
            request.set(CaptureRequest.LENS_FOCUS_DISTANCE, double("focus", 0.0).toFloat())
        } else {
            request.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
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
