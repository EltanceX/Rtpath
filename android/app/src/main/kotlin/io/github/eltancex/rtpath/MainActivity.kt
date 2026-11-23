package io.github.eltancex.rtpath

import io.github.eltancex.rtpath.scan.ScanApi
import io.github.eltancex.rtpath.scan.ScanCoordinator
import io.github.eltancex.rtpath.scan.SearchCursor
import io.github.eltancex.rtpath.scan.SearchOrder
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
        val scans = ScanCoordinator.get(context)
        ScanApi.setUp(messenger, object : ScanApi {
            override fun locations() = scans.locations.list()
            override fun requestSharedAccess() = scans.locations.requestSharedAccess(this@MainActivity)
            override fun indexes() = scans.indexes()
            override fun startScan(locationId: String, relativePath: String) = scans.start(locationId, relativePath)
            override fun status() = scans.status()
            override fun cancelScan(taskId: String) = scans.cancel(taskId)
            override fun search(scopeId: String, text: String, order: SearchOrder, descending: Boolean, cursor: SearchCursor?) =
                scans.search(scopeId, text, order, descending, cursor)
        })
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
        ScanApi.setUp(flutterEngine.dartExecutor.binaryMessenger, null)
        capabilitiesChannel?.setMethodCallHandler(null)
        capabilitiesChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
