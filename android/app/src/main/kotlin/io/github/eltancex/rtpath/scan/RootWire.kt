package io.github.eltancex.rtpath.scan

import java.io.DataInputStream
import java.io.DataOutputStream

internal fun rootScope(path: String): ScanScope {
    val absolute = path.trimEnd('/').ifEmpty { "/" }
    val relative = absolute.removePrefix("/")
    require(path.startsWith('/') && '\u0000' !in path && path.toByteArray(Charsets.UTF_8).size <= 4096 &&
        (relative.isEmpty() || relative.split('/').none { it.isEmpty() || it == "." || it == ".." })) {
        "请输入有效的绝对目录路径"
    }
    return ScanScope("root:$absolute", "root", relative, "/", absolute)
}

internal object RootWire {
    const val VERSION = 1
    private const val magic = 0x52545033
    private const val batchFrame = 1
    private const val problemFrame = 2
    private const val endFrame = 3
    private const val maxBatch = 512 * (35 + 255)

    fun writeHeader(output: DataOutputStream, id: String) {
        output.writeInt(magic)
        output.writeInt(VERSION)
        output.writeUTF(id)
    }

    fun writeBatch(output: DataOutputStream, batch: ByteArray) {
        require(batch.size in 1..maxBatch)
        output.writeByte(batchFrame)
        output.writeInt(batch.size)
        output.write(batch)
    }

    fun writeProblem(output: DataOutputStream, operation: String, error: Int) {
        output.writeByte(problemFrame)
        output.writeUTF(operation)
        output.writeInt(error)
    }

    fun writeEnd(output: DataOutputStream, outcome: Int) {
        output.writeByte(endFrame)
        output.writeByte(outcome)
        output.flush()
    }

    fun read(input: DataInputStream, id: String, receiver: ScanReceiver): Int {
        check(input.readInt() == magic && input.readInt() == VERSION && input.readUTF() == id) {
            "Root 扫描数据与当前任务不匹配"
        }
        while (!receiver.isCancelled()) {
            when (input.readUnsignedByte()) {
                batchFrame -> {
                    val size = input.readInt()
                    check(size in 1..maxBatch) { "Root 扫描批次长度无效" }
                    receiver.onBatch(ByteArray(size).also { input.readFully(it) })
                }
                problemFrame -> receiver.onProblem(input.readUTF(), input.readInt())
                endFrame -> {
                    val result = input.readUnsignedByte()
                    check(result in NativeScanner.COMPLETE..NativeScanner.FAILED && input.read() == -1) {
                        "Root 扫描结束帧无效"
                    }
                    return result
                }
                else -> error("Root 扫描数据帧无效")
            }
        }
        return NativeScanner.CANCELLED
    }
}
