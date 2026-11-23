package io.github.eltancex.rtpath.scan

import android.icu.lang.UCharacter
import androidx.sqlite.SQLiteConnection
import androidx.sqlite.SQLiteStatement
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.text.Normalizer

internal data class StoredIndex(
    val locationId: String,
    val relativePath: String,
    val index: PublishedIndex,
) {
    fun isAvailable(locations: List<ScanLocation>): Boolean = locations.any {
        it.id == locationId && it.canScan &&
            (if (relativePath.isEmpty()) it.path else File(it.path, relativePath).absolutePath) == index.path
    }
}

internal class IndexStore(private val file: File) {
    init {
        open().use { connection ->
            connection.execute("PRAGMA journal_mode = WAL")
            connection.transaction {
                connection.execute("""
                    CREATE TABLE IF NOT EXISTS scopes(
                        id TEXT PRIMARY KEY, location_id TEXT NOT NULL, relative_path TEXT NOT NULL,
                        path TEXT NOT NULL, generation TEXT NOT NULL UNIQUE, entries INTEGER NOT NULL,
                        partial INTEGER NOT NULL, updated_at INTEGER NOT NULL)
                """)
                connection.execute("""
                    CREATE TABLE IF NOT EXISTS entries(
                        generation TEXT NOT NULL, id INTEGER NOT NULL, parent_id INTEGER NOT NULL,
                        raw_name BLOB NOT NULL, name TEXT NOT NULL, name_key TEXT NOT NULL,
                        kind INTEGER NOT NULL, bytes INTEGER, modified_ms INTEGER NOT NULL,
                        PRIMARY KEY (generation, id)) WITHOUT ROWID
                """)
                // A process can stop before the scope pointer changes or just after it changes.
                connection.execute("DELETE FROM entries WHERE generation NOT IN (SELECT generation FROM scopes)")
            }
        }
    }

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
            SELECT id, location_id, relative_path, path, generation, entries, partial
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
                partial = excluded.partial, updated_at = excluded.updated_at
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

    fun search(scopeId: String, text: String, locations: List<ScanLocation>): SearchPage? = open().use { db ->
        db.transaction(readOnly = true) query@{
            val stored = readIndex(db, scopeId) ?: return@query null
            if (!stored.isAvailable(locations)) return@query null

            val index = stored.index
            val paths = EntryPaths(index.path, index.generation, db)
            val matches = ArrayList<SearchEntry>(searchLimit)
            var hasMore = false
            paths.use {
                db.prepare("""
                    SELECT parent_id, name, kind, bytes, modified_ms FROM entries
                    WHERE generation = ? AND id > 1 AND instr(name_key, ?) > 0
                    ORDER BY id LIMIT ${searchLimit + 1}
                """).use { query ->
                    query.bindText(1, index.generation)
                    query.bindText(2, searchKey(text))
                    while (query.step()) {
                        if (matches.size == searchLimit) {
                            hasMore = true
                            break
                        }

                        val name = query.getText(1)
                        val path = paths.resolve(query.getLong(0), name)
                        matches.add(
                            SearchEntry(
                                name = name,
                                path = path,
                                kind = EntryKind.entries[query.getLong(2).toInt()],
                                bytes = if (query.isNull(3)) null else query.getLong(3),
                                modifiedMillis = query.getLong(4),
                            ),
                        )
                    }
                }
            }
            SearchPage(index.generation, matches, hasMore)
        }
    }

    private fun readIndex(db: SQLiteConnection, scopeId: String): StoredIndex? = db.prepare("""
        SELECT id, location_id, relative_path, path, generation, entries, partial
        FROM scopes WHERE id = ?
    """).use {
        it.bindText(1, scopeId)
        if (it.step()) it.readIndex() else null
    }

    private fun SQLiteStatement.readIndex(): StoredIndex = StoredIndex(
        locationId = getText(1),
        relativePath = getText(2),
        index = PublishedIndex(getText(0), getText(4), getText(3), getLong(5), getLong(6) != 0L),
    )

    private class EntryPaths(
        private val root: String,
        private val generation: String,
        db: SQLiteConnection,
    ) : AutoCloseable {
        private data class Parent(val id: Long, val name: String)

        private val parents = mutableMapOf<Long, Parent>()
        private val query = db.prepare("SELECT parent_id, name FROM entries WHERE generation = ? AND id = ?")

        fun resolve(parentId: Long, name: String): String {
            val components = ArrayDeque<String>()
            components.addFirst(name)
            var current = parentId
            while (current > 1) {
                val parent = parents.getOrPut(current) {
                    query.bindText(1, generation)
                    query.bindLong(2, current)
                    check(query.step()) { "Indexed directory is missing" }
                    Parent(query.getLong(0), query.getText(1)).also { query.reset() }
                }
                check(parent.id in 1 until current) { "Indexed directory has an invalid parent" }
                components.addFirst(parent.name)
                current = parent.id
            }
            return root.trimEnd('/') + "/" + components.joinToString("/")
        }

        override fun close() = query.close()
    }

    private companion object {
        const val searchLimit = 100
    }
}

internal class BatchWriter(private val db: SQLiteConnection, private val generation: String) : AutoCloseable {
    private val insert = db.prepare("""
        INSERT INTO entries(generation, id, parent_id, raw_name, name, name_key, kind, bytes, modified_ms)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    """)
    var count = 0L
        private set

    fun write(batch: ByteArray) {
        val data = ByteBuffer.wrap(batch).order(ByteOrder.LITTLE_ENDIAN)
        var nextId = count + 1
        db.transaction {
            while (data.hasRemaining()) {
                require(data.remaining() >= 35) { "Truncated native scan record" }
                val id = data.long
                val parent = data.long
                val kind = data.get().toInt()
                val size = data.long
                val modified = data.long
                val nameSize = data.short.toInt() and 0xffff
                require(id == nextId++ && kind in EntryKind.entries.indices && data.remaining() >= nameSize)
                require(if (id == 1L) parent == 0L && nameSize == 0 else parent in 1 until id && nameSize != 0)
                val rawName = ByteArray(nameSize).also { data.get(it) }
                val name = rawName.toString(Charsets.UTF_8)
                insert.bindText(1, generation)
                insert.bindLong(2, id)
                insert.bindLong(3, parent)
                insert.bindBlob(4, rawName)
                insert.bindText(5, name)
                insert.bindText(6, searchKey(name))
                insert.bindLong(7, kind.toLong())
                if (size >= 0) insert.bindLong(8, size) else insert.bindNull(8)
                insert.bindLong(9, modified)
                insert.step()
                insert.reset()
            }
        }
        count = nextId - 1
    }

    override fun close() = insert.close()
}

private fun searchKey(text: String): String {
    val normalized = Normalizer.normalize(text, Normalizer.Form.NFC)
    return Normalizer.normalize(UCharacter.foldCase(normalized, true), Normalizer.Form.NFC)
}

private fun SQLiteConnection.execute(sql: String) {
    prepare(sql).use { it.step() }
}

private inline fun <T> SQLiteConnection.transaction(readOnly: Boolean = false, run: () -> T): T {
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
