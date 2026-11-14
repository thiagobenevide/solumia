package com.thiagobenevide.agent

import com.thiagobenevide.agent.consumo.ConsumoPlugin
import com.thiagobenevide.agent.recording.CameraProPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var camera: CameraProPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Saúde › Consumo: leitura do tempo de uso neste aparelho
        val canal = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "agent/saude/consumo")
        ConsumoPlugin(this).handle(canal)
        // Empreendimento › Gravação: pro camera (Camera2 + encoder) streaming to the PC
        val mensageiro = flutterEngine.dartExecutor.binaryMessenger
        camera = CameraProPlugin(this, flutterEngine.renderer).also {
            MethodChannel(mensageiro, "agent/empreendimento/camera").setMethodCallHandler(it)
            EventChannel(mensageiro, "agent/empreendimento/camera/events").setStreamHandler(it)
        }
    }

    override fun onRequestPermissionsResult(codigo: Int, permissoes: Array<out String>, concedidas: IntArray) {
        if (camera?.onPermissionResult(codigo) != true) {
            super.onRequestPermissionsResult(codigo, permissoes, concedidas)
        }
    }

    override fun onDestroy() {
        camera?.release()
        camera = null
        super.onDestroy()
    }
}
