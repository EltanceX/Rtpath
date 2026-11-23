package io.github.eltancex.rtpath

import io.github.eltancex.rtpath.scan.FlutterError
import io.github.eltancex.rtpath.scan.IndexUpdates
import io.github.eltancex.rtpath.scan.ScanApi
import io.github.eltancex.rtpath.scan.ScanCoordinator
import io.github.eltancex.rtpath.scan.SearchCursor
import io.github.eltancex.rtpath.scan.SearchOrder
import io.github.eltancex.rtpath.scan.WatchStatus
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class MainActivity : FlutterActivity() {
    private var capabilitiesChannel: MethodChannel? = null
    private var watchListener: ((WatchStatus) -> Unit)? = null
    private var watchNotifications: CoroutineScope? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val context = applicationContext
        val scans = ScanCoordinator.get(context)
        val updates = IndexUpdates(messenger)
        val notifications = CoroutineScope(Dispatchers.Main + SupervisorJob())
        watchNotifications = notifications
        val listener: (WatchStatus) -> Unit = { status ->
            notifications.launch {
                // The Dart handler may not yet be attached. It reads the current state on attach.
                try { updates.changed(status) } catch (_: FlutterError) { }
            }
        }
        watchListener = listener
        scans.addWatchListener(listener)
        ScanApi.setUp(messenger, object : ScanApi {
            override fun locations() = scans.locations.list()
            override fun requestSharedAccess() = scans.locations.requestSharedAccess(this@MainActivity)
            override fun indexes() = scans.indexes()
            override fun startScan(locationId: String, relativePath: String) = scans.start(locationId, relativePath)
            override fun rootIndexes() = scans.rootIndexes()
            override fun connectRoot() = scans.root.connect()
            override fun disconnectRoot() = scans.root.disconnect()
            override fun rootAccess() = scans.root.state()
            override fun startRootScan(absolutePath: String) = scans.startRoot(absolutePath)
            override fun probeRoot(absolutePath: String) = scans.root.probe(absolutePath)
            override fun status() = scans.status()
            override fun watchStatus(scopeId: String) = scans.watchStatus(scopeId)
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
        watchListener?.let { ScanCoordinator.get(applicationContext).removeWatchListener(it) }
        watchListener = null
        watchNotifications?.cancel()
        watchNotifications = null
        ScanApi.setUp(flutterEngine.dartExecutor.binaryMessenger, null)
        capabilitiesChannel?.setMethodCallHandler(null)
        capabilitiesChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
