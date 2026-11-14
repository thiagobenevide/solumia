package com.thiagobenevide.agent

import com.thiagobenevide.agent.usage.UsagePlugin
import com.thiagobenevide.agent.recording.CameraProPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var camera: CameraProPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Saúde › Consumo: screen-time reading on this device
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "agent/saude/consumo")
        UsagePlugin(this).handle(channel)
        // Empreendimento › Recording: pro camera (Camera2 + encoder) streaming to the PC
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        camera = CameraProPlugin(this, flutterEngine.renderer).also {
            MethodChannel(messenger, "agent/empreendimento/camera").setMethodCallHandler(it)
            EventChannel(messenger, "agent/empreendimento/camera/events").setStreamHandler(it)
        }
    }

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (camera?.onPermissionResult(code) != true) {
            super.onRequestPermissionsResult(code, permissions, grantResults)
        }
    }

    override fun onDestroy() {
        camera?.release()
        camera = null
        super.onDestroy()
    }
}
