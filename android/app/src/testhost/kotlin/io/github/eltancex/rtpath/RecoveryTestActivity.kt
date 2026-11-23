package io.github.eltancex.rtpath

import android.os.Debug
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

internal object RecoveryTestLimits {
    init { System.loadLibrary("rtpath_probe") }
    external fun configure(watches: Int, pending: Int)
}

class RecoveryTestActivity : MainActivity() {
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        check(packageName == "io.github.eltancex.rtpath.testhost")
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rtpath/test-recovery").also {
            it.setMethodCallHandler { call, reply ->
                if (call.method == "limits") {
                    val watches = call.argument<Int>("watches") ?: 0
                    val pending = call.argument<Int>("pending") ?: 0
                    RecoveryTestLimits.configure(watches, pending)
                    reply.success(null)
                } else if (call.method == "resources") {
                    reply.success(buildMap {
                        put("appPssKiB", Debug.getPss())
                        for (name in listOf("ordinary-index.sqlite", "root-index.sqlite")) {
                            put(name, File(noBackupFilesDir, name).length())
                            put("$name-wal", File(noBackupFilesDir, "$name-wal").length())
                        }
                    })
                } else {
                    reply.notImplemented()
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel?.setMethodCallHandler(null)
        RecoveryTestLimits.configure(0, 0)
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
