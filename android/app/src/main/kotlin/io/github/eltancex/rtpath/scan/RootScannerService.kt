package io.github.eltancex.rtpath.scan

import android.content.Intent
import android.os.Binder
import android.os.Bundle
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.Process
import android.system.Os
import android.util.Log
import com.topjohnwu.superuser.ipc.RootService
import java.io.BufferedOutputStream
import java.io.DataOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class RootScannerService : RootService() {
    private val lock = Any()
    private val worker = Executors.newSingleThreadExecutor()
    private var running: Job? = null
    private var destroyed = false
    private var probing = false

    private class Job(val id: String, val client: IBinder) {
        @Volatile var cancelled = false
        val death = IBinder.DeathRecipient { cancelled = true }
        val done = CountDownLatch(1)
    }

    private fun authorize() {
        check(Os.getuid() == 0 && Os.geteuid() == 0) { "Root 服务以普通 UID 启动" }
        if (Binder.getCallingUid() != applicationInfo.uid) throw SecurityException("Unexpected Root client UID")
    }

    private val binder = object : IRootScanner.Stub() {
        override fun inspect(): Bundle {
            authorize()
            val user = applicationInfo.uid / 100000
            val paths = listOf("/data/user/$user", "/data/user_de/$user", "/data/media/$user", "/storage/emulated/$user")
            return Bundle().apply {
                putInt("protocol", RootWire.VERSION)
                putInt("pid", Process.myPid())
                putInt("uid", Os.geteuid())
                putString("namespace", Os.readlink("/proc/self/ns/mnt"))
                putString("selinux", File("/proc/self/attr/current").readText().trim().trimEnd('\u0000'))
                putStringArrayList("mounts", ArrayList(paths.map { inspectKnown(it) }))
            }
        }

        override fun start(
            taskId: String, absolutePath: String, mount: Long, device: Long, inode: Long,
            output: ParcelFileDescriptor, client: IBinder,
        ) {
            try {
                authorize()
                UUID.fromString(taskId)
                val scope = rootScope(absolutePath)
                synchronized(lock) {
                    check(running == null && !destroyed && !probing) { "Root 服务正在处理其他操作" }
                    val job = Job(taskId, client)
                    client.linkToDeath(job.death, 0)
                    running = job
                    worker.execute { stream(job, scope, ScopeIdentity(mount, device, inode), output) }
                }
            } catch (failure: Throwable) {
                output.close()
                throw failure
            }
        }

        override fun cancel(taskId: String) {
            authorize()
            synchronized(lock) { running?.takeIf { it.id == taskId }?.cancelled = true }
        }

        override fun awaitIdle(taskId: String): Boolean {
            authorize()
            val job = synchronized(lock) { running?.takeIf { it.id == taskId } } ?: return true
            return job.done.await(3, TimeUnit.SECONDS)
        }

        override fun probeFanotify(absolutePath: String): List<String> {
            authorize()
            val scope = rootScope(absolutePath)
            synchronized(lock) {
                check(!destroyed && !probing) { "Root 服务正在处理其他操作" }
                probing = true
            }
            try {
                val user = applicationInfo.uid / 100000
                val appCache = File(applicationInfo.dataDir, "cache").canonicalPath
                val external = "/storage/emulated/$user/Android/data/$packageName/cache"
                return listOf(
                    render(scope, mark = true, exercise = false),
                    render(rootScope(appCache), mark = true, exercise = true),
                    render(rootScope(external), mark = true, exercise = true),
                )
            } finally {
                synchronized(lock) { probing = false }
            }
        }
    }

    private fun inspectKnown(path: String): String {
        val canonical = File(path).canonicalPath
        val description = render(rootScope(canonical), mark = false, exercise = false)
        return if (canonical == path) description else "$path → $description"
    }

    private fun render(scope: ScanScope, mark: Boolean, exercise: Boolean): String =
        "${scope.path} · " + NativeScanner.inspectDirectory(
            scope.path.toByteArray(Charsets.UTF_8), mark, exercise,
        )

    private fun stream(job: Job, scope: ScanScope, expected: ScopeIdentity, fd: ParcelFileDescriptor) {
        val output = DataOutputStream(BufferedOutputStream(ParcelFileDescriptor.AutoCloseOutputStream(fd)))
        try {
            RootWire.writeHeader(output, job.id)
            val result = NativeScanner.run(
                scope, File(applicationInfo.dataDir, "no_backup").absolutePath, expected,
                object : ScanReceiver {
                    override fun isCancelled() = job.cancelled
                    override fun onBatch(batch: ByteArray) = RootWire.writeBatch(output, batch)
                    override fun onProblem(operation: String, error: Int) = RootWire.writeProblem(output, operation, error)
                    override fun onChanges() = RootWire.writeChanges(output)
                    override fun onPath(path: ByteArray, change: Int) = RootWire.writePath(output, path, change)
                    override fun onCheckpoint(
                        baseline: Boolean, fuse: Boolean, watched: Int, failed: Int, error: Int, sequence: Long,
                    ) = RootWire.writeCheckpoint(output, baseline, fuse, watched, failed, error, sequence)
                    override fun onGap(operation: String, error: Int) = RootWire.writeGap(output, operation, error)
                    override fun onIdentity(mount: Long, device: Long, inode: Long) =
                        RootWire.writeIdentity(output, mount, device, inode)
                    override fun onRepair(path: ByteArray, directories: Long, entries: Long, millis: Long) =
                        RootWire.writeRepair(output, path, directories, entries, millis)
                },
            )
            RootWire.writeEnd(output, result)
        } catch (error: Exception) {
            if (!job.cancelled) Log.w(TAG, "Root scan stream ended without a result", error)
        } finally {
            synchronized(lock) {
                running = null
                job.done.countDown()
            }
            try {
                job.client.unlinkToDeath(job.death, 0)
            } finally {
                try { output.close() } catch (_: Exception) { }
            }
        }
    }

    override fun onBind(intent: Intent): IBinder = binder

    override fun onDestroy() {
        synchronized(lock) {
            destroyed = true
            running?.cancelled = true
        }
        worker.shutdown()
        super.onDestroy()
    }

    private companion object {
        const val TAG = "RtPathRoot"
    }
}
