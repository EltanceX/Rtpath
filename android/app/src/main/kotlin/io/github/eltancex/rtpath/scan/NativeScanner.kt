package io.github.eltancex.rtpath.scan

import androidx.annotation.Keep

@Keep
internal interface ScanReceiver {
    fun onBatch(batch: ByteArray)
    fun onProblem(operation: String, error: Int)
    fun onBackend(fanotify: Boolean, reason: String)
    fun onChanges()
    fun onPath(path: ByteArray, change: Int)
    fun onCheckpoint(baseline: Boolean, fuse: Boolean, watched: Int, failed: Int, error: Int, sequence: Long)
    fun onGap(operation: String, error: Int)
    fun onIdentity(mount: Long, device: Long, inode: Long)
    fun onRepair(path: ByteArray, directories: Long, entries: Long, millis: Long)
    fun isCancelled(): Boolean
}

@Keep
internal object NativeScanner {
    const val COMPLETE = 0
    const val CANCELLED = 1
    const val FAILED = 2
    const val REMOVE = 0
    const val METADATA = 1
    const val SUBTREE = 2

    init {
        System.loadLibrary("rtpath_probe")
    }

    fun run(
        scope: ScanScope, indexDirectory: String, expected: ScopeIdentity, receiver: ScanReceiver,
        fixtures: ByteArray? = null,
    ): Int = walk(
        scope.base.toByteArray(Charsets.UTF_8), scope.relativePath.toByteArray(Charsets.UTF_8),
        indexDirectory.toByteArray(Charsets.UTF_8), expected.mount, expected.device, expected.inode, fixtures, receiver,
    )

    private external fun walk(
        basePath: ByteArray, relativePath: ByteArray, indexDirectoryPath: ByteArray,
        mount: Long, device: Long, inode: Long, fixturePaths: ByteArray?, receiver: ScanReceiver,
    ): Int

    external fun inspectDirectory(absolutePath: ByteArray, fixturePaths: ByteArray? = null): String
}

internal data class ScopeIdentity(val mount: Long = 0, val device: Long = 0, val inode: Long = 0)
