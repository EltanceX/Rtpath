package io.github.eltancex.rtpath.scan

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal fun verifyStorageFull(file: File) {
    val scope = ScanScope("scratch:", "scratch", "", "/rtpath-recovery", "/rtpath-recovery")
    val location = listOf(ScanLocation("scratch", "Fixture", scope.path, false, true))
    val generation = "storage-full"
    val store = IndexStore(file)
    store.open().use { db ->
        db.transaction {
            IndexedEntryWriter(db, generation).use {
                it.insert(1, 0, byteArrayOf(), EntryKind.DIRECTORY.ordinal, null, 0)
                it.insert(2, 1, "keep-committed.txt".toByteArray(), EntryKind.FILE.ordinal, 7, 0)
            }
        }
        check(store.publish(db, scope, generation, 1, false))
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        val pages = db.prepare("PRAGMA page_count").use { check(it.step()); it.getLong(0) }
        db.execute("PRAGMA max_page_count = $pages")
        val failure = runCatching {
            IndexChanges(db, generation, scope.id, true).use { changes ->
                changes.path("keep-committed.txt".toByteArray(), NativeScanner.REMOVE)
                changes.path("uncommitted".toByteArray(), NativeScanner.SUBTREE)
                changes.write(record(1, 0, "", EntryKind.DIRECTORY))
                for (id in 2L..5000L) changes.write(record(id, 1, "child-$id-${"a".repeat(200)}", EntryKind.FILE))
                changes.commit()
            }
        }.exceptionOrNull()
        check(failure?.message.orEmpty().contains("full", ignoreCase = true)) { "Expected SQLITE_FULL, got $failure" }
        val before = checkNotNull(store.search(scope.id, "", SearchOrder.NAME, false, null, location))
        check(before.revision == 0L && before.entries.single().name == "keep-committed.txt")

        db.execute("PRAGMA max_page_count = ${pages + 1000}")
        IndexChanges(db, generation, scope.id, true).use { changes ->
            changes.path("keep-committed.txt".toByteArray(), NativeScanner.REMOVE)
            changes.path("after-retry.txt".toByteArray(), NativeScanner.METADATA)
            changes.write(record(1, 0, "", EntryKind.FILE))
            changes.commit()
        }
        val after = checkNotNull(store.search(scope.id, "", SearchOrder.NAME, false, null, location))
        check(after.revision == 1L && after.entries.single().name == "after-retry.txt")
    }
}

private fun record(id: Long, parent: Long, name: String, kind: EntryKind): ByteArray {
    val raw = name.toByteArray()
    return ByteBuffer.allocate(35 + raw.size).order(ByteOrder.LITTLE_ENDIAN).apply {
        putLong(id)
        putLong(parent)
        put(kind.ordinal.toByte())
        putLong(if (kind == EntryKind.FILE) 4 else -1)
        putLong(0)
        putShort(raw.size.toShort())
        put(raw)
    }.array()
}
