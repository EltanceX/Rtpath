package io.github.eltancex.rtpath.scan

import androidx.annotation.Keep

@Keep
internal interface ScanReceiver {
    fun onBatch(batch: ByteArray)
    fun onProblem(operation: String, error: Int)
    fun isCancelled(): Boolean
}

@Keep
internal object NativeScanner {
    const val COMPLETE = 0
    const val CANCELLED = 1
    const val FAILED = 2

    init {
        System.loadLibrary("rtpath_probe")
    }

    external fun walk(basePath: ByteArray, relativePath: ByteArray, receiver: ScanReceiver): Int

    external fun inspectDirectory(absolutePath: ByteArray, mark: Boolean, exercise: Boolean): String
}
