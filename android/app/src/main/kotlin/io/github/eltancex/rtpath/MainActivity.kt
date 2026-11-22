package io.github.eltancex.rtpath

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

class MainActivity : FlutterActivity() {
    private var capabilitiesChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val context = applicationContext
        capabilitiesChannel = MethodChannel(
            messenger,
            "io.github.eltancex.rtpath/capabilities",
            StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue(),
        ).apply {
            setMethodCallHandler { call, result ->
                if (call.method == "inspect") {
                    try {
                        result.success(CapabilityProbe.inspect(context))
                    } catch (error: Exception) {
                        result.error("probe_failed", error.localizedMessage, null)
                    } catch (error: LinkageError) {
                        result.error("native_load_failed", error.localizedMessage, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        capabilitiesChannel?.setMethodCallHandler(null)
        capabilitiesChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
