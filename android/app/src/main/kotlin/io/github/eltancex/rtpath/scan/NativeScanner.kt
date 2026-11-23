package io.github.eltancex.rtpath.scan

import androidx.annotation.Keep

@Keep
internal interface ScanReceiver {
    fun onBatch(batch: ByteArray)
    fun onProblem(operation: String, error: Int)
    fun onChanges()
    fun onPath(path: ByteArray, change: Int)
    fun onCheckpoint(baseline: Boolean, fuse: Boolean, watched: Int, failed: Int, error: Int, sequence: Long)
    fun onGap(operation: String, error: Int)
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

    external fun walk(basePath: ByteArray, relativePath: ByteArray, receiver: ScanReceiver): Int

    external fun inspectDirectory(absolutePath: ByteArray, mark: Boolean, exercise: Boolean): String
}
