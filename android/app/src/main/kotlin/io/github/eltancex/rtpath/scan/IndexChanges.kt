package io.github.eltancex.rtpath.scan

import androidx.sqlite.SQLiteConnection

/** One transaction for all paths in a reconciliation burst, including both sides of moves. */
internal class IndexChanges(
    private val db: SQLiteConnection,
    private val generation: String,
    private val scopeId: String,
    private val published: Boolean,
) : AutoCloseable {
    private data class Entry(val id: Long, val path: String, val kind: Int)

    private data class PathChange(
        val action: Int,
        val parent: Entry?,
        val name: ByteArray,
        val existing: List<Entry>,
        var records: Long = 0,
        var idOffset: Long = 0,
        var writer: IndexedEntryWriter? = null,
    )

    private var current: PathChange? = null
    private var active = false
    var changed = false
        private set
    private var lastId = 0L
    private var entriesDelta = 0L

    init {
        db.execute("BEGIN IMMEDIATE")
        active = true
        try {
            lastId = db.prepare("SELECT coalesce(max(id), 0) FROM entries WHERE generation = ?").use {
                it.bindText(1, generation)
                check(it.step())
                it.getLong(0)
            }
        } catch (failure: Throwable) {
            close()
            throw failure
        }
    }

    fun path(rawPath: ByteArray, action: Int) {
        finishPath()
        require(action in NativeScanner.REMOVE..NativeScanner.SUBTREE)
        if (rawPath.isEmpty()) {
            require(action == NativeScanner.METADATA)
            current = PathChange(action, null, byteArrayOf(), listOf(root))
            return
        }

        val names = pathComponents(rawPath)
        var parent: Entry? = root
        for (name in names.dropLast(1)) {
            val directory = parent ?: break
            parent = children(directory, name).singleOrNull()?.takeIf { it.kind == EntryKind.DIRECTORY.ordinal }
        }
        val name = names.last()
        val existing = parent?.let { children(it, name) }.orEmpty()
        if (action == NativeScanner.REMOVE) {
            existing.forEach { deleteBranch(it.id) }
        } else {
            check(parent != null) { "变更路径的父目录未入库" }
            current = PathChange(action, parent, name, existing)
        }
    }

    fun write(batch: ByteArray) {
        val path = checkNotNull(current) { "Missing inotify change path" }
        readScanBatch(batch, path.records) { id, parent, name, kind, size, modified ->
            if (id == 1L) {
                if (path.action == NativeScanner.SUBTREE) check(kind == EntryKind.DIRECTORY.ordinal)
                val existing = path.existing.singleOrNull()
                if (path.action == NativeScanner.METADATA && existing?.kind == kind) {
                    updateMetadata(existing.id, size, modified)
                    path.records = id
                    return@readScanBatch
                }
                val anchor = checkNotNull(path.parent)
                path.existing.forEach { deleteBranch(it.id) }
                path.idOffset = lastId
                path.writer = IndexedEntryWriter(db, generation, anchor.id, anchor.path)
            } else {
                check(path.action == NativeScanner.SUBTREE)
            }
            val anchor = checkNotNull(path.parent)
            checkNotNull(path.writer).insert(
                id + path.idOffset,
                if (id == 1L) anchor.id else parent + path.idOffset,
                if (id == 1L) path.name else name,
                kind, size, modified,
            )
            lastId = id + path.idOffset
            ++entriesDelta
            changed = true
            path.records = id
        }
    }

    fun commit(): Long {
        finishPath()
        if (changed && published) {
            db.prepare("""
                UPDATE scopes SET entries = entries + ?, revision = revision + 1
                WHERE id = ? AND generation = ?
            """).use {
                it.bindLong(1, entriesDelta)
                it.bindText(2, scopeId)
                it.bindText(3, generation)
                it.step()
            }
            check(changes() == 1L) { "inotify 会话已被替换" }
        }
        db.execute("COMMIT")
        active = false
        return entriesDelta
    }

    private fun finishPath() {
        val path = current ?: return
        path.writer?.close()
        current = null
        check(path.records > 0) { "Incomplete inotify change path" }
    }

    private fun deleteBranch(id: Long) {
        db.prepare("""
            WITH RECURSIVE branch(id) AS (
                VALUES (?)
                UNION ALL
                SELECT e.id FROM branch b CROSS JOIN entries e
                WHERE e.generation = ? AND e.parent_id = b.id
            )
            DELETE FROM entries WHERE generation = ? AND id IN (SELECT id FROM branch)
        """).use {
            it.bindLong(1, id)
            it.bindText(2, generation)
            it.bindText(3, generation)
            it.step()
        }
        val removed = changes()
        entriesDelta -= removed
        changed = changed || removed > 0
    }

    private fun updateMetadata(id: Long, size: Long?, modified: Long) {
        db.prepare("""
            UPDATE entries SET bytes = ?, modified_ms = ?
            WHERE generation = ? AND id = ? AND (bytes IS NOT ?1 OR modified_ms != ?2)
        """).use {
            if (size == null) it.bindNull(1) else it.bindLong(1, size)
            it.bindLong(2, modified)
            it.bindText(3, generation)
            it.bindLong(4, id)
            it.step()
        }
        changed = changed || changes() != 0L
    }

    private fun children(parent: Entry, name: ByteArray): List<Entry> = db.prepare("""
        SELECT id, relative_path, kind FROM entries
        WHERE generation = ? AND parent_id = ? AND raw_name = ?
    """).use {
        it.bindText(1, generation)
        it.bindLong(2, parent.id)
        it.bindBlob(3, name)
        buildList {
            while (it.step()) add(Entry(it.getLong(0), it.getText(1), it.getLong(2).toInt()))
        }
    }

    private fun changes(): Long = db.prepare("SELECT changes()").use {
        check(it.step())
        it.getLong(0)
    }

    override fun close() {
        try {
            current?.writer?.close()
            current = null
        } finally {
            if (active) {
                active = false
                db.execute("ROLLBACK")
            }
        }
    }

    private companion object {
        val root = Entry(1, "", EntryKind.DIRECTORY.ordinal)

        fun pathComponents(raw: ByteArray): List<ByteArray> = buildList {
            require(raw.size <= 513 * 256 && 0.toByte() !in raw)
            var start = 0
            for (end in 0..raw.size) {
                if (end < raw.size && raw[end] != '/'.code.toByte()) continue
                require(end - start in 1..255)
                val component = raw.copyOfRange(start, end)
                require(!component.contentEquals(byteArrayOf(46)) && !component.contentEquals(byteArrayOf(46, 46)))
                add(component)
                start = end + 1
            }
        }
    }
}
