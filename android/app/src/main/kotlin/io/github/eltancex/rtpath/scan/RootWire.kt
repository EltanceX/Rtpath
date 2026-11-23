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
    const val VERSION = 3
    private const val magic = 0x52545033
    private const val batchFrame = 1
    private const val problemFrame = 2
    private const val endFrame = 3
    private const val changesFrame = 4
    private const val pathFrame = 5
    private const val checkpointFrame = 6
    private const val gapFrame = 7
    private const val identityFrame = 8
    private const val repairFrame = 9
    private const val maxBatch = 512 * (35 + 255)
    private const val maxPath = 513 * 256

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

    fun writeChanges(output: DataOutputStream) = output.writeByte(changesFrame)

    fun writePath(output: DataOutputStream, path: ByteArray, change: Int) {
        output.writeByte(pathFrame)
        output.writeByte(change)
        writePathBytes(output, path)
    }

    private fun writePathBytes(output: DataOutputStream, path: ByteArray) {
        require(path.size <= maxPath)
        output.writeInt(path.size)
        output.write(path)
    }

    private fun readPathBytes(input: DataInputStream): ByteArray {
        val size = input.readInt()
        check(size in 0..maxPath) { "Root 变更路径长度无效" }
        return ByteArray(size).also { input.readFully(it) }
    }

    fun writeIdentity(output: DataOutputStream, mount: Long, device: Long, inode: Long) {
        output.writeByte(identityFrame)
        output.writeLong(mount)
        output.writeLong(device)
        output.writeLong(inode)
    }

    fun writeRepair(output: DataOutputStream, path: ByteArray, directories: Long, entries: Long, millis: Long) {
        output.writeByte(repairFrame)
        writePathBytes(output, path)
        output.writeLong(directories)
        output.writeLong(entries)
        output.writeLong(millis)
    }

    fun writeCheckpoint(
        output: DataOutputStream, baseline: Boolean, fuse: Boolean, watched: Int, failed: Int, error: Int, sequence: Long,
    ) {
        output.writeByte(checkpointFrame)
        output.writeBoolean(baseline)
        output.writeBoolean(fuse)
        output.writeInt(watched)
        output.writeInt(failed)
        output.writeInt(error)
        output.writeLong(sequence)
        output.flush()
    }

    fun writeGap(output: DataOutputStream, operation: String, error: Int) {
        output.writeByte(gapFrame)
        output.writeUTF(operation)
        output.writeInt(error)
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
                changesFrame -> receiver.onChanges()
                pathFrame -> {
                    val change = input.readUnsignedByte()
                    receiver.onPath(readPathBytes(input), change)
                }
                checkpointFrame -> receiver.onCheckpoint(
                    input.readBoolean(), input.readBoolean(), input.readInt(), input.readInt(), input.readInt(), input.readLong(),
                )
                gapFrame -> receiver.onGap(input.readUTF(), input.readInt())
                identityFrame -> receiver.onIdentity(input.readLong(), input.readLong(), input.readLong())
                repairFrame -> receiver.onRepair(readPathBytes(input), input.readLong(), input.readLong(), input.readLong())
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
