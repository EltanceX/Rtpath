package io.github.eltancex.rtpath.scan

import android.content.Context
import android.system.Os
import android.util.Log
import androidx.sqlite.SQLiteConnection
import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.Executors

internal class ScanCoordinator private constructor(context: Context) {
    val locations = ScanLocations(context)
    val root = RootBackend(context)
    private val ordinaryStore by lazy { IndexStore(File(context.noBackupFilesDir, "ordinary-index.sqlite")) }
    private val rootStore by lazy { IndexStore(File(context.noBackupFilesDir, "root-index.sqlite")) }
    // Each database has one writer, including its baseline and incremental commits.
    private val ordinaryWriter = Executors.newSingleThreadExecutor()
    private val rootWriter = Executors.newSingleThreadExecutor()

    private val lock = Any()
    private var latest: ScanStatus? = null
    private var ordinarySession: Session? = null
    private var rootSession: Session? = null
    private val listeners = CopyOnWriteArraySet<(WatchStatus) -> Unit>()

    private class Session(val scope: ScanScope, val id: String, val remote: IRootScanner?) {
        @Volatile var stopReason: String? = null
        var watch = WatchStatus(scope.id, id, 0, WatchState.STARTING, 0, 0, 0)
    }

    fun addWatchListener(listener: (WatchStatus) -> Unit) { listeners.add(listener) }

    fun removeWatchListener(listener: (WatchStatus) -> Unit) { listeners.remove(listener) }

    fun watchStatus(scopeId: String): WatchStatus? = synchronized(lock) {
        val session = if (scopeId.startsWith("root:")) rootSession else ordinarySession
        session?.watch?.takeIf { it.scopeId == scopeId }
    }

    fun indexes(): List<PublishedIndex> {
        val current = locations.list()
        return ordinaryStore.indexes().filter { it.isAvailable(current) }.map { it.index }
    }

    fun rootIndexes(): List<PublishedIndex> = rootStore.indexes().map { it.index }

    fun search(scopeId: String, text: String, order: SearchOrder, descending: Boolean, cursor: SearchCursor?): SearchPage? =
        try {
            if (scopeId.startsWith("root:")) {
                rootStore.search(scopeId, text, order, descending, cursor, listOf(rootLocation))
            } else {
                ordinaryStore.search(scopeId, text, order, descending, cursor, locations.list())
            }
        } catch (error: IllegalArgumentException) {
            throw FlutterError("invalid_query", error.message)
        }

    fun status(): ScanStatus? = synchronized(lock) { latest }

    fun start(locationId: String, relativePath: String): ScanStatus =
        startScope(resolve(locationId, relativePath), null)

    fun startRoot(path: String): ScanStatus = try {
        startScope(rootScope(path), root.requireConnected())
    } catch (error: IllegalArgumentException) {
        throw FlutterError("invalid_scope", error.message)
    } catch (error: RootFailure) {
        throw FlutterError("root_unavailable", error.message)
    }

    private fun startScope(scope: ScanScope, remote: IRootScanner?): ScanStatus = synchronized(lock) {
        if (latest?.state in listOf(ScanState.RUNNING, ScanState.CANCELLING)) {
            throw FlutterError("scan_busy", "已有扫描任务在运行")
        }
        val generation = UUID.randomUUID().toString()
        val initial = ScanStatus(generation, scope.id, ScanState.RUNNING, 0, 0, 0, false)
        val previous = if (remote == null) ordinarySession else rootSession
        if (previous != null && previous.watch.state != WatchState.STOPPED) {
            stop(previous, "已切换到新的扫描任务")
        }
        val next = Session(scope, generation, remote)
        if (remote == null) ordinarySession = next else rootSession = next
        latest = initial
        listeners.forEach { it(next.watch) }
        val writer = if (remote == null) ordinaryWriter else rootWriter
        writer.execute { scan(next) }
        initial
    }

    fun cancel(taskId: String): Boolean = synchronized(lock) {
        val status = latest
        if (status?.taskId != taskId || status.state != ScanState.RUNNING) return false
        val session = checkNotNull(if (status.scopeId.startsWith("root:")) rootSession else ordinarySession)
        latest = status.copy(state = ScanState.CANCELLING)
        stop(session, "扫描已取消")
        true
    }

    private fun stop(session: Session, reason: String) {
        session.stopReason = reason
        updateWatch(session, session.watch.copy(state = WatchState.STOPPED, watched = 0, message = reason))
        if (session.remote != null) root.cancel(session.id)
    }

    private fun updateWatch(session: Session, watch: WatchStatus) {
        val previous = session.watch
        session.watch = watch
        if (watch.copy(sequence = previous.sequence) != previous) listeners.forEach { it(watch) }
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

    private fun scan(session: Session) {
        val scope = session.scope
        val generation = session.id
        val remote = session.remote
        var reason: String? = null
        try {
            val store = if (remote == null) ordinaryStore else rootStore
            store.open().use { db ->
                BatchWriter(db, generation).use { baseline ->
                    var baselineWriter: BatchWriter? = baseline
                    var changes: IndexChanges? = null
                    var count = 0L
                    var published = false
                    var done = false
                    var lastSequence = 0L
                    fun finishBaseline() {
                        if (baselineWriter == null) return
                        count = baseline.count - 1
                        baselineWriter = null
                        check(count >= 0) { "缺少扫描范围根目录" }
                    }

                    val receiver = object : ScanReceiver {
                        override fun isCancelled() = session.stopReason != null || done

                        override fun onBatch(batch: ByteArray) {
                            if (isCancelled()) return
                            val initial = baselineWriter
                            if (initial != null) {
                                initial.write(batch)
                                updateScan(generation) { it.copy(entries = initial.count - 1) }
                            } else {
                                checkNotNull(changes) { "Missing inotify transaction" }.write(batch)
                            }
                        }

                        override fun onProblem(operation: String, error: Int) {
                            val message = formatError(operation, error)
                            if (changes != null) {
                                // A partial subtree read cannot confirm deletions inside it.
                                if (operation != "mount boundary") throw IllegalStateException(message)
                                return
                            }
                            updateScan(generation) {
                                if (operation == "mount boundary") it.copy(skippedMounts = it.skippedMounts + 1)
                                else it.copy(issues = it.issues + 1, message = it.message ?: message)
                            }
                        }

                        override fun onChanges() {
                            if (isCancelled()) return
                            finishBaseline()
                            check(changes == null)
                            changes = IndexChanges(db, generation, scope.id, published)
                        }

                        override fun onPath(path: ByteArray, change: Int) {
                            if (!isCancelled()) checkNotNull(changes).path(path, change)
                        }

                        override fun onCheckpoint(
                            baseline: Boolean, fuse: Boolean, watched: Int, failed: Int, error: Int, sequence: Long,
                        ) {
                            var retired: String? = null
                            synchronized(lock) {
                                if (isCancelled()) return
                                check(watched >= 0 && failed >= 0 && sequence >= lastSequence)
                                if (remote == null) {
                                    check(resolve(scope.locationId, scope.relativePath) == scope) { "扫描位置已变更" }
                                } else {
                                    check(root.requireConnected() === remote) { "Root 连接已断开" }
                                }
                                if (baseline) {
                                    check(!published && changes == null)
                                    finishBaseline()
                                    val status = checkNotNull(latest)
                                    check(status.taskId == generation)
                                    val partial = status.issues > 0
                                    val previous = store.scopeVersion(db, scope.id)
                                    published = store.publish(db, scope, generation, count, partial)
                                    latest = status.copy(
                                        state = if (partial) ScanState.PARTIAL else ScanState.COMPLETED,
                                        entries = count,
                                        published = published,
                                    )
                                    if (!published) {
                                        done = true
                                        reason = "扫描未完整覆盖，保留历史索引"
                                        return
                                    }
                                    retired = previous
                                    if (partial) {
                                        done = true
                                        reason = "扫描未完整覆盖，重新扫描后可恢复实时更新"
                                        return
                                    }
                                }
                                var revision = session.watch.revision
                                changes?.use { delta ->
                                    count += delta.commit()
                                    if (published && delta.changed) ++revision
                                }
                                changes = null
                                if (published) {
                                    val message = buildList {
                                        if (fuse) add("FUSE 视图可能漏报底层直写")
                                        if (failed > 0) add(formatError("${failed} 个目录无法监听", error))
                                    }.joinToString(" · ").ifEmpty { null }
                                    updateWatch(session, WatchStatus(
                                        scope.id, generation, revision,
                                        if (fuse || failed > 0) WatchState.LIMITED else WatchState.LIVE,
                                        watched.toLong(), failed.toLong(), sequence, message,
                                    ))
                                }
                                lastSequence = sequence
                            }
                            retired?.let { discard(store, db, it) }
                        }

                        override fun onGap(operation: String, error: Int) {
                            reason = formatError(operation, error)
                        }
                    }

                    try {
                        val outcome = if (remote != null) root.run(remote, generation, scope, receiver)
                        else NativeScanner.walk(
                            scope.base.toByteArray(Charsets.UTF_8),
                            scope.relativePath.toByteArray(Charsets.UTF_8), receiver,
                        )
                        if (outcome == NativeScanner.FAILED) {
                            reason = reason ?: synchronized(lock) { latest?.takeIf { it.taskId == generation }?.message }
                                ?: "原生扫描失败"
                        }
                    } finally {
                        try {
                            changes?.close()
                        } finally {
                            discard(store, db, generation)
                        }
                    }
                }
            }
        } catch (error: Exception) {
            reason = failed(error)
        } catch (error: LinkageError) {
            reason = failed(error)
        } catch (error: OutOfMemoryError) {
            reason = failed(error)
        } finally {
            synchronized(lock) {
                updateScan(generation) {
                    when (it.state) {
                        ScanState.CANCELLING -> it.copy(state = ScanState.CANCELLED, message = null)
                        ScanState.RUNNING -> it.copy(state = ScanState.FAILED, message = reason ?: "扫描未完成")
                        else -> it
                    }
                }
                if (session.watch.state != WatchState.STOPPED) {
                    updateWatch(session, session.watch.copy(
                        state = WatchState.STOPPED,
                        watched = 0,
                        message = reason ?: "实时更新已停止",
                    ))
                }
            }
        }
    }

    private fun discard(store: IndexStore, db: SQLiteConnection, generation: String) {
        try {
            store.discardUnpublished(db, generation)
        } catch (error: Exception) {
            Log.w(TAG, "Index cleanup deferred to the next process start", error)
        }
    }

    private fun failed(error: Throwable): String {
        Log.w(TAG, "Scan or inotify session ended", error)
        return error.message ?: "扫描或实时更新失败"
    }

    private fun formatError(operation: String, error: Int) =
        if (error == 0) operation else "$operation: ${Os.strerror(error)}"

    private inline fun updateScan(generation: String, change: (ScanStatus) -> ScanStatus) = synchronized(lock) {
        val status = latest
        if (status?.taskId == generation) latest = change(status)
    }

    companion object {
        private const val TAG = "RtPathScan"
        private val rootLocation = ScanLocation("root", "Root", "/", false, true)
        private var instance: ScanCoordinator? = null

        @Synchronized
        fun get(context: Context): ScanCoordinator =
            instance ?: ScanCoordinator(context.applicationContext).also { instance = it }
    }
}
