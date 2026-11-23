package io.github.eltancex.rtpath.scan

import android.content.Context
import android.system.Os
import android.util.Log
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

internal class ScanCoordinator private constructor(context: Context) {
    val locations = ScanLocations(context)
    private val store by lazy { IndexStore(File(context.noBackupFilesDir, "ordinary-index.sqlite")) }
    private val writer = Executors.newSingleThreadExecutor()

    private val lock = Any()
    private var latest: ScanStatus? = null
    @Volatile private var cancellationRequested = false

    fun indexes(): List<PublishedIndex> {
        val current = locations.list()
        return store.indexes().filter { it.isAvailable(current) }.map { it.index }
    }

    fun search(scopeId: String, text: String, order: SearchOrder, descending: Boolean, cursor: SearchCursor?): SearchPage? =
        try {
            store.search(scopeId, text, order, descending, cursor, locations.list())
        } catch (error: IllegalArgumentException) {
            throw FlutterError("invalid_query", error.message)
        }

    fun status(): ScanStatus? = synchronized(lock) { latest }

    fun start(locationId: String, relativePath: String): ScanStatus {
        val scope = resolve(locationId, relativePath)
        return synchronized(lock) {
            if (latest?.state in listOf(ScanState.RUNNING, ScanState.CANCELLING)) {
                throw FlutterError("scan_busy", "已有扫描任务在运行")
            }
            val generation = UUID.randomUUID().toString()
            val initial = ScanStatus(generation, scope.id, ScanState.RUNNING, 0, 0, 0, false)
            latest = initial
            cancellationRequested = false
            writer.execute { scan(scope, generation) }
            initial
        }
    }

    fun cancel(taskId: String): Boolean = synchronized(lock) {
        val status = latest
        if (status?.taskId != taskId || status.state != ScanState.RUNNING) {
            return@synchronized false
        }
        cancellationRequested = true
        latest = status.copy(state = ScanState.CANCELLING)
        true
    }

    private fun resolve(locationId: String, relativePath: String): ScanScope {
        val location = locations.list().firstOrNull { it.id == locationId }
            ?: throw FlutterError("location_unavailable", "扫描位置不可用")
        return try {
            locations.resolve(location, relativePath)
        } catch (error: IllegalArgumentException) {
            throw FlutterError("invalid_scope", error.message)
        }
    }

    private fun scan(scope: ScanScope, generation: String) {
        try {
            store.open().use { db ->
                var previous: String? = null
                try {
                    val outcome = BatchWriter(db, generation).use { batchWriter ->
                        NativeScanner.walk(
                            scope.base.toByteArray(Charsets.UTF_8),
                            scope.relativePath.toByteArray(Charsets.UTF_8),
                            object : ScanReceiver {
                                override fun isCancelled() = cancellationRequested

                                override fun onBatch(batch: ByteArray) {
                                    if (isCancelled()) return
                                    batchWriter.write(batch)
                                    updateStatus { it.copy(entries = batchWriter.count - 1) }
                                }

                                override fun onProblem(operation: String, error: Int) {
                                    updateStatus {
                                        if (operation == "mount boundary") {
                                            it.copy(skippedMounts = it.skippedMounts + 1)
                                        } else {
                                            val message = if (error == 0) operation else "$operation: ${Os.strerror(error)}"
                                            it.copy(issues = it.issues + 1, message = it.message ?: message)
                                        }
                                    }
                                }
                            },
                        )
                    }
                    if (outcome == NativeScanner.COMPLETE && !cancellationRequested) {
                        check(resolve(scope.locationId, scope.relativePath) == scope) { "扫描位置已变更" }
                    }
                    // Cancellation and the scope pointer commit share one lock.
                    updateStatus { status ->
                        when {
                            cancellationRequested || outcome == NativeScanner.CANCELLED ->
                                status.copy(state = ScanState.CANCELLED, message = null)
                            outcome == NativeScanner.FAILED ->
                                status.copy(state = ScanState.FAILED, message = status.message ?: "原生扫描失败")
                            else -> {
                                check(outcome == NativeScanner.COMPLETE)
                                val partial = status.issues > 0
                                previous = store.scopeVersion(db, scope.id)
                                val published = store.publish(db, scope, generation, status.entries, partial)
                                status.copy(
                                    state = if (partial) ScanState.PARTIAL else ScanState.COMPLETED,
                                    published = published,
                                )
                            }
                        }
                    }
                } finally {
                    try {
                        store.discardUnpublished(db, generation)
                        previous?.let { store.discardUnpublished(db, it) }
                    } catch (error: Exception) {
                        Log.w(TAG, "Index cleanup deferred to the next process start", error)
                    }
                }
            }
        } catch (error: Exception) {
            scanFailed(generation, error)
        } catch (error: LinkageError) {
            scanFailed(generation, error)
        } catch (error: OutOfMemoryError) {
            scanFailed(generation, error)
        }
    }

    private fun scanFailed(generation: String, error: Throwable) {
        Log.w(TAG, "Scan failed", error)
        updateStatus {
            if (it.taskId != generation) return@updateStatus it
            when (it.state) {
                ScanState.CANCELLING -> it.copy(state = ScanState.CANCELLED, message = null)
                ScanState.RUNNING -> it.copy(state = ScanState.FAILED, message = error.message ?: "扫描失败")
                else -> it
            }
        }
    }

    private inline fun updateStatus(change: (ScanStatus) -> ScanStatus) = synchronized(lock) {
        latest = change(checkNotNull(latest))
    }

    companion object {
        private const val TAG = "RtPathScan"
        private var instance: ScanCoordinator? = null

        @Synchronized
        fun get(context: Context): ScanCoordinator =
            instance ?: ScanCoordinator(context.applicationContext).also { instance = it }
    }
}
