package io.github.eltancex.rtpath.scan

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.SQLiteStatement
import java.util.UUID

internal class EntrySearch(
    private val db: SQLiteConnection,
    private val index: PublishedIndex,
    private val revision: Long,
    private val query: SearchQuery,
    private val order: SearchOrder,
    private val descending: Boolean,
    private val hasTrigram: Boolean,
) {
    private val directory = query.relativeDirectory(index.path)
    private val directoryPrefix = directory?.takeIf { it.isNotEmpty() }?.let { "$it/" }
    private val directoryEnd = directoryPrefix?.let { prefixEnd(it) }
    private val sortColumn = when (order) {
        SearchOrder.NAME -> "e.name_key"
        SearchOrder.PATH -> "e.relative_path"
        SearchOrder.SIZE -> "e.size_key"
        SearchOrder.MODIFIED -> "e.modified_ms"
    }
    private val orderedIndex = when (order) {
        SearchOrder.NAME -> if (query.extension == null) "entries_name" else "entries_extension"
        SearchOrder.PATH -> "entries_path"
        SearchOrder.SIZE -> "entries_size"
        SearchOrder.MODIFIED -> "entries_modified"
    }
    private val textOrder = order == SearchOrder.NAME || order == SearchOrder.PATH
    private val useSubstring = query.mode == NameMatch.SUBSTRING && query.name.isNotEmpty()
    private val canUseFts = useSubstring && hasTrigram && query.name.codePointCount(0, query.name.length) >= 3
    private val phrase = "\"${query.name.replace("\"", "\"\"")}\""
    private val narrowDirectory by lazy {
        val prefix = directoryPrefix ?: return@lazy false
        // Restrict a small subtree before applying a different sort order.
        SearchSql("""
            SELECT 1 FROM entries INDEXED BY entries_path
            WHERE generation = ? AND relative_path >= ? AND relative_path < ?
            LIMIT 1 OFFSET 16384
        """, listOf(index.generation, prefix, checkNotNull(directoryEnd))).prepare(db).use { !it.step() }
    }

    fun page(queryKey: String, cursor: SearchCursor?): SearchPage {
        if (cursor != null) {
            if (cursor.generation != index.generation || cursor.revision != revision) {
                return SearchPage(index.generation, revision, emptyList(), true)
            }
            require(cursor.queryKey == queryKey && cursor.id > 1 &&
                if (textOrder) cursor.textKey != null else cursor.numberKey != null) {
                "搜索条件已变更，请重新查询"
            }
        }
        if (directory == null) return SearchPage(index.generation, revision, emptyList(), false)

        val scanCandidates = if (canUseFts) cursor?.scanCandidates ?: useCandidates() else useSubstring
        val maxChecked = if (scanCandidates) candidateLimit else pageSize
        val matches = ArrayList<SearchEntry>(pageSize)
        val root = index.path.trimEnd('/') + "/"
        var checked = 0
        var lastId = 0L
        var textKey: String? = null
        var numberKey: Long? = null
        var next: SearchCursor? = null
        select(canUseFts && !scanCandidates, cursor, maxChecked + 1).prepare(db).use { rows ->
            while (rows.step()) {
                if (checked == maxChecked || matches.size == pageSize) {
                    next = SearchCursor(index.generation, revision, queryKey, lastId, scanCandidates, textKey, numberKey)
                    break
                }
                checked++
                val match = !scanCandidates || rows.getText(2).contains(query.name)
                if (match || checked == maxChecked) {
                    lastId = rows.getLong(0)
                    if (textOrder) textKey = rows.getText(1) else numberKey = rows.getLong(1)
                }
                if (!match) continue
                matches.add(
                    SearchEntry(
                        name = rows.getText(3),
                        path = root + rows.getText(4),
                        kind = EntryKind.entries[rows.getLong(5).toInt()],
                        bytes = if (rows.isNull(6)) null else rows.getLong(6),
                        modifiedMillis = rows.getLong(7),
                    ),
                )
            }
        }
        return SearchPage(index.generation, revision, matches, false, next)
    }

    private fun useCandidates(): Boolean {
        if (!useSubstring) return false
        if (!canUseFts) return true
        if (index.entries <= candidateLimit) return true
        // Sorting a large posting list for every page is costlier than seeking in
        // the result order and checking a bounded number of names.
        return SearchSql(
            "SELECT rowid FROM entry_names WHERE entry_names MATCH ? LIMIT 1 OFFSET $denseThreshold",
            listOf(phrase),
        ).prepare(db).use { it.step() }
    }

    fun select(fts: Boolean, cursor: SearchCursor?, limit: Int): SearchSql {
        val args = mutableListOf<Any>(index.generation)
        val where = mutableListOf("e.generation = ?", "e.id > 1")
        query.extension?.let {
            where.add("e.extension = ?")
            args.add(it)
        }
        directoryPrefix?.let {
            where.add("e.relative_path >= ? AND e.relative_path < ?")
            args.add(it)
            args.add(checkNotNull(directoryEnd))
        }
        if (query.sizes.isNotEmpty()) where.add("e.size_key >= 0")
        query.sizes.forEach {
            where.add("e.size_key ${it.operator} ?")
            args.add(it.bytes)
        }
        when (query.mode) {
            NameMatch.EXACT -> {
                where.add("e.name_key = ?")
                args.add(query.name)
            }
            NameMatch.PREFIX -> {
                where.add("e.name_key >= ?")
                args.add(query.name)
                prefixEnd(query.name)?.let {
                    where.add("e.name_key < ?")
                    args.add(it)
                }
            }
            NameMatch.SUBSTRING -> if (fts) {
                where.add("entry_names MATCH ?")
                args.add(phrase)
            }
        }
        if (cursor != null) {
            val comparison = if (descending) "<" else ">"
            if (order == SearchOrder.NAME && query.mode == NameMatch.EXACT) {
                where.add("e.id $comparison ?")
            } else {
                where.add("($sortColumn, e.id) $comparison (?, ?)")
                args.add(checkNotNull(if (textOrder) cursor.textKey else cursor.numberKey))
            }
            args.add(cursor.id)
        }
        val from = when {
            fts -> "entry_names CROSS JOIN entries e ON e.row_key = entry_names.rowid"
            order != SearchOrder.PATH && query.mode == NameMatch.SUBSTRING && narrowDirectory ->
                "entries e INDEXED BY entries_path"
            query.mode == NameMatch.SUBSTRING || order == SearchOrder.NAME -> "entries e INDEXED BY $orderedIndex"
            else -> "entries e"
        }
        val columns = "e.id, $sortColumn, e.name_key, e.name, e.relative_path, e.kind, e.bytes, e.modified_ms"
        val direction = if (descending) "DESC" else "ASC"
        val tail = "ORDER BY $sortColumn $direction, e.id $direction LIMIT $limit"
        return SearchSql("SELECT $columns FROM $from WHERE ${where.joinToString(" AND ")} $tail", args)
    }

    companion object {
        const val pageSize = 100
        const val candidateLimit = 2048
        private const val denseThreshold = 8192

        fun key(scope: String, text: String, order: SearchOrder, descending: Boolean): String =
            UUID.nameUUIDFromBytes("$scope\u0000$text\u0000$order\u0000$descending".toByteArray(Charsets.UTF_8)).toString()
    }
}

internal data class SearchSql(val sql: String, val args: List<Any>) {
    fun prepare(db: SQLiteConnection, explain: Boolean = false): SQLiteStatement {
        val query = db.prepare(if (explain) "EXPLAIN QUERY PLAN $sql" else sql)
        try {
            args.forEachIndexed { index, value ->
                when (value) {
                    is String -> query.bindText(index + 1, value)
                    is Long -> query.bindLong(index + 1, value)
                    else -> error("Unsupported search parameter")
                }
            }
            return query
        } catch (failure: Throwable) {
            query.close()
            throw failure
        }
    }
}
