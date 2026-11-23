package io.github.eltancex.rtpath.scan

import androidx.sqlite.SQLiteConnection

internal object IndexSchema {
    private const val version = 4L

    fun initialize(db: SQLiteConnection): Boolean {
        db.execute("PRAGMA journal_mode = WAL")
        return db.transaction {
            val previousVersion = db.prepare("PRAGMA user_version").use {
                check(it.step())
                it.getLong(0)
            }
            check(previousVersion in 0..version) { "This index was created by a newer RtPath version" }
            if (previousVersion < 2) createOrMigrate(db)
            if (previousVersion < 3) {
                db.execute("ALTER TABLE entries ADD COLUMN size_key INTEGER AS (coalesce(bytes, -1)) VIRTUAL")
                db.execute("DROP INDEX IF EXISTS entries_size")
                db.execute("CREATE INDEX entries_size ON entries(generation, size_key, id)")
            }
            if (previousVersion < 4) db.execute("CREATE INDEX entries_children ON entries(generation, parent_id, raw_name)")
            if (previousVersion < version) db.execute("PRAGMA user_version = $version")
            val trigram = ensureTrigram(db)

            // A process can stop before the active pointer changes or just after it changes.
            db.execute("DELETE FROM entries WHERE generation NOT IN (SELECT generation FROM scopes)")
            trigram
        }
    }

    private fun createOrMigrate(db: SQLiteConnection) {
        val legacy = db.hasTable("entries")
        if (legacy) {
            db.execute("ALTER TABLE entries RENAME TO legacy_entries")
            db.execute("ALTER TABLE scopes ADD COLUMN revision INTEGER NOT NULL DEFAULT 0")
        } else {
            db.execute("""
                CREATE TABLE scopes(
                    id TEXT PRIMARY KEY, location_id TEXT NOT NULL, relative_path TEXT NOT NULL,
                    path TEXT NOT NULL, generation TEXT NOT NULL UNIQUE, entries INTEGER NOT NULL,
                    partial INTEGER NOT NULL, updated_at INTEGER NOT NULL, revision INTEGER NOT NULL DEFAULT 0)
            """)
        }
        db.execute("""
            CREATE TABLE entries(
                row_key INTEGER PRIMARY KEY,
                generation TEXT NOT NULL, id INTEGER NOT NULL, parent_id INTEGER NOT NULL,
                raw_name BLOB NOT NULL, name TEXT NOT NULL, name_key TEXT NOT NULL,
                kind INTEGER NOT NULL, bytes INTEGER, modified_ms INTEGER NOT NULL,
                relative_path TEXT NOT NULL, extension TEXT,
                UNIQUE (generation, id))
        """)
        if (legacy) migratePublished(db)

        db.execute("CREATE INDEX entries_name ON entries(generation, name_key, id)")
        db.execute("CREATE INDEX entries_path ON entries(generation, relative_path, id)")
        db.execute("CREATE INDEX entries_modified ON entries(generation, modified_ms, id)")
        db.execute("CREATE INDEX entries_extension ON entries(generation, extension, name_key, id)")
    }

    private fun migratePublished(db: SQLiteConnection) {
        db.prepare("SELECT generation FROM scopes").use { published ->
            while (published.step()) {
                val generation = published.getText(0)
                db.prepare("""
                    SELECT id, parent_id, raw_name, kind, bytes, modified_ms, name, name_key
                    FROM legacy_entries WHERE generation = ? ORDER BY id
                """).use { rows ->
                    rows.bindText(1, generation)
                    IndexedEntryWriter(db, generation).use { writer ->
                        while (rows.step()) {
                            writer.insert(
                                rows.getLong(0), rows.getLong(1), rows.getBlob(2), rows.getLong(3).toInt(),
                                if (rows.isNull(4)) null else rows.getLong(4), rows.getLong(5),
                                rows.getText(6), rows.getText(7),
                            )
                        }
                    }
                }
            }
        }
        db.execute("DROP TABLE legacy_entries")
    }

    private fun ensureTrigram(db: SQLiteConnection): Boolean {
        if (db.hasTable("entry_names")) return true
        try {
            db.execute("""
                CREATE VIRTUAL TABLE entry_names USING fts5(
                    name_key, content='entries', content_rowid='row_key', tokenize='trigram case_sensitive 1')
            """)
        } catch (error: Exception) {
            val message = error.message.orEmpty()
            if ("no such module: fts5" in message || "no such tokenizer: trigram" in message) return false
            throw error
        }
        db.execute("INSERT INTO entry_names(entry_names) VALUES('rebuild')")
        db.execute("""
            CREATE TRIGGER entries_names_insert AFTER INSERT ON entries BEGIN
                INSERT INTO entry_names(rowid, name_key) VALUES (new.row_key, new.name_key);
            END
        """)
        db.execute("""
            CREATE TRIGGER entries_names_delete AFTER DELETE ON entries BEGIN
                INSERT INTO entry_names(entry_names, rowid, name_key) VALUES ('delete', old.row_key, old.name_key);
            END
        """)
        db.execute("""
            CREATE TRIGGER entries_names_update AFTER UPDATE OF name_key ON entries WHEN old.name_key <> new.name_key BEGIN
                INSERT INTO entry_names(entry_names, rowid, name_key) VALUES ('delete', old.row_key, old.name_key);
                INSERT INTO entry_names(rowid, name_key) VALUES (new.row_key, new.name_key);
            END
        """)
        return true
    }

    private fun SQLiteConnection.hasTable(name: String): Boolean =
        prepare("SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ?").use {
            it.bindText(1, name)
            it.step()
        }
}

internal class IndexedEntryWriter(
    db: SQLiteConnection,
    private val generation: String,
    parentId: Long = 0,
    parentPath: String = "",
) : AutoCloseable {
    private val insert = db.prepare("""
        INSERT INTO entries(generation, id, parent_id, raw_name, name, name_key, kind, bytes, modified_ms, relative_path, extension)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """)
    private data class Directory(val id: Long, val path: String)

    private val directories = ArrayDeque<Directory>().apply {
        if (parentId != 0L) addLast(Directory(parentId, parentPath))
    }

    fun insert(
        id: Long,
        parentId: Long,
        rawName: ByteArray,
        kind: Int,
        size: Long?,
        modified: Long,
        name: String = rawName.toString(Charsets.UTF_8),
        nameKey: String = searchKey(name),
    ) {
        val path = if (parentId == 0L) {
            ""
        } else {
            while (directories.lastOrNull()?.id != parentId && directories.isNotEmpty()) directories.removeLast()
            val parent = checkNotNull(directories.lastOrNull()) { "Indexed directory is missing" }
            if (parent.path.isEmpty()) name else parent.path + "/" + name
        }
        if (kind == EntryKind.DIRECTORY.ordinal) directories.addLast(Directory(id, path))

        insert.bindText(1, generation)
        insert.bindLong(2, id)
        insert.bindLong(3, parentId)
        insert.bindBlob(4, rawName)
        insert.bindText(5, name)
        insert.bindText(6, nameKey)
        insert.bindLong(7, kind.toLong())
        if (size == null) insert.bindNull(8) else insert.bindLong(8, size)
        insert.bindLong(9, modified)
        insert.bindText(10, path)
        val extension = extensionKey(name, kind)
        if (extension == null) insert.bindNull(11) else insert.bindText(11, extension)
        insert.step()
        insert.reset()
    }

    override fun close() = insert.close()
}
