package io.github.eltancex.rtpath.scan

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.SQLiteStatement
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal data class StoredIndex(
    val locationId: String,
    val relativePath: String,
    val index: PublishedIndex,
    val revision: Long,
) {
    fun isAvailable(locations: List<ScanLocation>): Boolean = locations.any {
        it.id == locationId && it.canScan &&
            (if (relativePath.isEmpty()) it.path else File(it.path, relativePath).absolutePath) == index.path
    }
}

internal class IndexStore(private val file: File) {
    internal val hasTrigram = open().use(IndexSchema::initialize)

    fun open(): SQLiteConnection {
        val connection = BundledSQLiteDriver().open(file.absolutePath)
        try {
            connection.execute("PRAGMA busy_timeout = 3000")
            return connection
        } catch (failure: Throwable) {
            connection.close()
            throw failure
        }
    }

    fun indexes(): List<StoredIndex> = open().use { db ->
        db.prepare("""
            SELECT id, location_id, relative_path, path, generation, entries, partial, revision
            FROM scopes ORDER BY updated_at DESC, id
        """).use { query ->
            buildList { while (query.step()) add(query.readIndex()) }
        }
    }

    fun publish(
        db: SQLiteConnection,
        scope: ScanScope,
        generation: String,
        entries: Long,
        partial: Boolean,
    ): Boolean = db.transaction {
        if (partial && readIndex(db, scope.id) != null) return@transaction false
        db.prepare("""
            INSERT INTO scopes(id, location_id, relative_path, path, generation, entries, partial, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET location_id = excluded.location_id, relative_path = excluded.relative_path,
                path = excluded.path, generation = excluded.generation, entries = excluded.entries,
                partial = excluded.partial, updated_at = excluded.updated_at, revision = 0
        """).use {
            it.bindText(1, scope.id)
            it.bindText(2, scope.locationId)
            it.bindText(3, scope.relativePath)
            it.bindText(4, scope.path)
            it.bindText(5, generation)
            it.bindLong(6, entries)
            it.bindLong(7, if (partial) 1 else 0)
            it.bindLong(8, System.currentTimeMillis())
            it.step()
        }
        true
    }

    fun scopeVersion(db: SQLiteConnection, scopeId: String): String? = readIndex(db, scopeId)?.index?.generation

    fun discardUnpublished(db: SQLiteConnection, generation: String) {
        db.prepare("""
            DELETE FROM entries WHERE generation = ?
                AND NOT EXISTS(SELECT 1 FROM scopes WHERE generation = ?)
        """).use {
            it.bindText(1, generation)
            it.bindText(2, generation)
            it.step()
        }
    }

    fun search(
        scopeId: String,
        text: String,
        order: SearchOrder,
        descending: Boolean,
        cursor: SearchCursor?,
        locations: List<ScanLocation>,
    ): SearchPage? = open().use { db ->
        val specification = SearchQuery.parse(text)
        db.transaction(readOnly = true) query@{
            val stored = readIndex(db, scopeId) ?: return@query null
            if (!stored.isAvailable(locations)) return@query null
            EntrySearch(db, stored.index, stored.revision, specification, order, descending, hasTrigram)
                .page(EntrySearch.key(scopeId, text, order, descending), cursor)
        }
    }

    private fun readIndex(db: SQLiteConnection, scopeId: String): StoredIndex? = db.prepare("""
        SELECT id, location_id, relative_path, path, generation, entries, partial, revision
        FROM scopes WHERE id = ?
    """).use {
        it.bindText(1, scopeId)
        if (it.step()) it.readIndex() else null
    }

    private fun SQLiteStatement.readIndex(): StoredIndex = StoredIndex(
        locationId = getText(1),
        relativePath = getText(2),
        index = PublishedIndex(getText(0), getText(4), getText(3), getLong(5), getLong(6) != 0L),
        revision = getLong(7),
    )
}

internal class BatchWriter(private val db: SQLiteConnection, generation: String) : AutoCloseable {
    private val writer = IndexedEntryWriter(db, generation)
    var count = 0L
        private set

    fun write(batch: ByteArray) {
        var lastId = count
        db.transaction {
            readScanBatch(batch, lastId) { id, parent, name, kind, size, modified ->
                writer.insert(id, parent, name, kind, size, modified)
                lastId = id
            }
        }
        count = lastId
    }

    override fun close() = writer.close()
}

internal inline fun readScanBatch(
    batch: ByteArray,
    lastId: Long,
    record: (Long, Long, ByteArray, Int, Long?, Long) -> Unit,
) {
    val data = ByteBuffer.wrap(batch).order(ByteOrder.LITTLE_ENDIAN)
    var nextId = lastId + 1
    while (data.hasRemaining()) {
        require(data.remaining() >= 35) { "Truncated native scan record" }
        val id = data.long
        val parent = data.long
        val kind = data.get().toInt()
        val size = data.long
        val modified = data.long
        val nameSize = data.short.toInt() and 0xffff
        require(id == nextId++ && kind in EntryKind.entries.indices && nameSize <= 255 && data.remaining() >= nameSize)
        require(if (id == 1L) parent == 0L && nameSize == 0 else parent in 1 until id && nameSize != 0)
        val rawName = ByteArray(nameSize).also { data.get(it) }
        record(id, parent, rawName, kind, size.takeIf { it >= 0 }, modified)
    }
}

internal fun SQLiteConnection.execute(sql: String) {
    prepare(sql).use { it.step() }
}

internal inline fun <T> SQLiteConnection.transaction(readOnly: Boolean = false, run: () -> T): T {
    execute(if (readOnly) "BEGIN" else "BEGIN IMMEDIATE")
    try {
        val result = run()
        execute("COMMIT")
        return result
    } catch (failure: Throwable) {
        try {
            execute("ROLLBACK")
        } catch (rollback: Throwable) {
            failure.addSuppressed(rollback)
        }
        throw failure
    }
}
