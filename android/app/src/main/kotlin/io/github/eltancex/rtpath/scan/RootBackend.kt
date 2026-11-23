package io.github.eltancex.rtpath.scan

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Binder
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import com.topjohnwu.superuser.Shell
import com.topjohnwu.superuser.ipc.RootService
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.EOFException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

internal class RootBackend(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val authorization = Executors.newSingleThreadExecutor()
    private val commands = Executors.newSingleThreadExecutor()
    private val lock = Any()
    private val client = Binder()
    private var session: Connection? = null
    private var stream: ActiveStream? = null
    private var access = RootAccess(state = RootState.IDLE, mounts = emptyList())

    private inner class Connection : ServiceConnection {
        val connected = CompletableFuture<IRootScanner>()
        var binding = false // Main thread only.
        var remote: IRootScanner? = null // Read under lock.

        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            synchronized(lock) {
                binding = true
                if (session !== this) {
                    main.post { release(this) }
                    return
                }
                remote = IRootScanner.Stub.asInterface(binder)
                connected.complete(checkNotNull(remote))
            }
        }

        override fun onServiceDisconnected(name: ComponentName) = lost(this)
        override fun onBindingDied(name: ComponentName) = lost(this)
        override fun onNullBinding(name: ComponentName) = lost(this)
    }

    private data class ActiveStream(
        val id: String,
        val remote: IRootScanner,
        val read: ParcelFileDescriptor,
    )

    // Invoked from the explicit action on the Flutter main channel.
    fun connect() {
        val next = synchronized(lock) {
            if (session != null) return
            Connection().also {
                session = it
                access = RootAccess(state = RootState.REQUESTING, mounts = emptyList())
            }
        }
        authorization.execute { bind(next) }
    }

    fun disconnect() {
        val previous = synchronized(lock) {
            val current = session
            session = null
            access = RootAccess(state = RootState.IDLE, mounts = emptyList())
            current?.connected?.completeExceptionally(RootFailure("Root 已断开"))
            stream?.read?.closeQuietly()
            current
        }
        if (previous != null) {
            release(previous)
            authorization.execute { closeShell() }
        }
    }

    fun state(): RootAccess = synchronized(lock) { access }

    fun requireConnected(): IRootScanner = synchronized(lock) {
        val root = session?.remote
        if (access.state != RootState.CONNECTED || root == null || !root.asBinder().isBinderAlive) {
            throw RootFailure("请先连接 Root")
        }
        root
    }

    fun probe(path: String): List<String> {
        val root = requireConnected()
        val scope = rootScope(path)
        // These directories belong to the ordinary UID. The Root probe uses only
        // these two caches for its temporary event fixtures.
        context.cacheDir
        runCatching { context.externalCacheDir }
        val report = root.probeFanotify(scope.path)
        check(requireConnected() === root) { "探测期间 Root 连接已断开" }
        return report
    }

    fun run(root: IRootScanner, id: String, scope: ScanScope, receiver: ScanReceiver): Int {
        val pipe = ParcelFileDescriptor.createReliablePipe()
        val active = ActiveStream(id, root, pipe[0])
        var started = false
        var finished = false
        try {
            synchronized(lock) {
                check(requireConnected() === root && stream == null)
                stream = active
            }
            if (receiver.isCancelled()) return NativeScanner.CANCELLED
            pipe[1].use { root.start(id, scope.path, it, client) }
            started = true
            if (receiver.isCancelled()) return NativeScanner.CANCELLED
            val outcome = DataInputStream(BufferedInputStream(ParcelFileDescriptor.AutoCloseInputStream(pipe[0]))).use {
                RootWire.read(it, id, receiver)
            }
            finished = !receiver.isCancelled()
            if (outcome != NativeScanner.CANCELLED && requireConnected() !== root) {
                throw RootFailure("Root 连接已断开")
            }
            return outcome
        } catch (failure: Exception) {
            if (receiver.isCancelled()) return NativeScanner.CANCELLED
            if (!isCurrent(root)) throw RootFailure("Root 连接已断开", failure)
            if (failure is EOFException) throw RootFailure("Root 服务的索引数据流提前结束", failure)
            throw failure
        } finally {
            pipe.forEach { it.closeQuietly() }
            synchronized(lock) { if (stream === active) stream = null }
            if (started && !finished) stopAndWait(root, id)
        }
    }

    fun cancel(taskId: String) {
        val root = synchronized(lock) {
            val active = stream?.takeIf { it.id == taskId } ?: return
            active.remote
        }
        cancelRemote(root, taskId)
    }

    private fun bind(connection: Connection) {
        try {
            if (!Shell.getShell().isRoot) throw RootFailure("Root 授权被拒绝或设备没有可用的 su")
            main.post {
                synchronized(lock) {
                    if (session !== connection) return@post
                    try {
                        connection.binding = true
                        RootService.bind(Intent(context, RootScannerService::class.java), connection)
                    } catch (failure: Exception) {
                        connection.connected.completeExceptionally(failure)
                    }
                }
            }
            val remote = connection.connected.get(20, TimeUnit.SECONDS)
            val info = remote.inspect()
            check(info.getInt("protocol") == RootWire.VERSION && info.getInt("uid", -1) == 0)
            synchronized(lock) {
                if (session !== connection) return
                access = RootAccess(
                    state = RootState.CONNECTED,
                    mounts = info.getStringArrayList("mounts").orEmpty(),
                    pid = info.getInt("pid").toLong(),
                    uid = info.getInt("uid").toLong(),
                    namespace = info.getString("namespace"),
                    selinux = info.getString("selinux"),
                )
            }
        } catch (failure: Exception) {
            Log.w(TAG, "Root connection failed", failure)
            synchronized(lock) {
                if (session === connection) {
                    session = null
                    access = RootAccess(
                        state = RootState.UNAVAILABLE,
                        mounts = emptyList(),
                        message = (failure as? RootFailure)?.message ?: "Root 服务启动失败或连接超时",
                    )
                }
            }
            main.post { release(connection) }
            closeShell()
        }
    }

    private fun lost(connection: Connection) {
        connection.binding = false // libsu is removing this connection now.
        synchronized(lock) {
            if (session !== connection) return
            session = null
            val message = "Root 服务已断开"
            access = RootAccess(state = RootState.UNAVAILABLE, mounts = emptyList(), message = message)
            connection.connected.completeExceptionally(RootFailure(message))
            stream?.read?.closeQuietly()
        }
    }

    private fun isCurrent(root: IRootScanner): Boolean =
        synchronized(lock) { session?.remote === root && root.asBinder().isBinderAlive }

    private fun cancelRemote(root: IRootScanner, id: String) {
        commands.execute {
            try { root.cancel(id) } catch (failure: Exception) {
                Log.d(TAG, "Root cancel RPC ended", failure)
            }
        }
    }

    private fun stopAndWait(root: IRootScanner, id: String) {
        try {
            root.cancel(id)
            if (!root.awaitIdle(id)) main.post { if (isCurrent(root)) disconnect() }
        } catch (failure: Exception) {
            Log.d(TAG, "Root stream released", failure)
        }
    }

    private fun release(connection: Connection) {
        if (!connection.binding) return
        connection.binding = false
        try { RootService.unbind(connection) } catch (failure: Exception) {
            Log.d(TAG, "Root binding already released", failure)
        }
    }

    private fun closeShell() {
        try { Shell.getCachedShell()?.close() } catch (failure: Exception) {
            Log.d(TAG, "Root shell closed", failure)
        }
    }

    private fun ParcelFileDescriptor.closeQuietly() {
        try { close() } catch (_: Exception) { }
    }

    private companion object {
        const val TAG = "RtPathRoot"

        init {
            Shell.setDefaultBuilder(Shell.Builder.create().setFlags(Shell.FLAG_MOUNT_MASTER).setTimeout(15))
        }
    }
}

internal class RootFailure(message: String, cause: Throwable? = null) : Exception(message, cause)
