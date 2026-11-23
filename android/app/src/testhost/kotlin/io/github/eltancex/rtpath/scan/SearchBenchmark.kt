package io.github.eltancex.rtpath.scan

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import android.os.Debug
import android.os.SystemClock
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import java.io.File
import java.nio.file.Files

class SearchBenchmark : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val result = Bundle()
        val report = StringBuilder()
        try {
            check(targetContext.packageName == "io.github.eltancex.rtpath.testhost")
            val work = Files.createTempDirectory(targetContext.cacheDir.toPath(), "search-benchmark-").toFile()
            try {
                verifyMigration(File(work, "legacy.sqlite"))
                report.appendLine("Legacy v0 migration and literal fallback verified.")
                verifyStorageFull(File(work, "recovery.sqlite"))
                report.appendLine("RtPath phase 5: SQLite page cap triggered SQLITE_FULL; committed revision survived and retry succeeded.")
                for (count in listOf(100_000, 1_000_000)) {
                    benchmark(File(work, "$count.sqlite"), count, report)
                }
            } finally {
                work.deleteRecursively()
            }
            result.putString("stream", report.toString())
            finish(Activity.RESULT_OK, result)
        } catch (error: Throwable) {
            result.putString("stream", report.toString() + error.stackTraceToString())
            finish(Activity.RESULT_CANCELED, result)
        }
    }

    private fun benchmark(file: File, count: Int, report: StringBuilder) {
        val root = "/rtpath-benchmark"
        val location = ScanLocation("bench", "Synthetic", root, false, true)
        val scope = ScanScope("bench:", location.id, "", root, root)
        val generation = "00000000-0000-0000-0000-000000000001"
        val store = IndexStore(file)
        check(store.hasTrigram)
        val build = timed {
            store.open().use { db ->
                IndexedEntryWriter(db, generation).use { writer ->
                    var id = 1L
                    db.transaction { writer.insert(id++, 0, byteArrayOf(), EntryKind.DIRECTORY.ordinal, null, 0) }
                    val chunk = (count - 100) / 100
                    repeat(100) { group ->
                        db.transaction {
                            val parent = id++
                            val directory = "module-" + group.toString().padStart(3, '0')
                            writer.insert(parent, 1, directory.toByteArray(), EntryKind.DIRECTORY.ordinal, null, 1_710_000_000_000)
                            repeat(chunk) { position ->
                                val i = group * chunk + position
                                val name = fixtureName(i, count - 100)
                                writer.insert(
                                    id++, parent, name.toByteArray(), EntryKind.FILE.ordinal,
                                    (i * 5227L) % 4_000_000, 1_710_000_000_000 + (i % 347) * 1000L,
                                )
                            }
                        }
                    }
                    check(id == count + 2L)
                }
                check(store.publish(db, scope, generation, count.toLong(), false))
                db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            }
        }
        val cases = listOf(
            Scenario("exact", "name:item-000002.bin"),
            Scenario("prefix", "prefix:item-000"),
            Scenario("common", "export"),
            Scenario("rare", "稀有标记"),
            Scenario("miss", "absent-qqq"),
            Scenario("literal", "\"\\\"100%\\\"\""),
            Scenario("one-high", "件"),
            Scenario("two-high", "文件"),
            Scenario("one-low", "蓝", shortTail = true),
            Scenario("two-low", "项目", shortTail = true),
            Scenario("combined", "export ext:kt path:module-037 size:>=1MiB", SearchOrder.SIZE, true),
            Scenario("path-sort", "prefix:item-000", SearchOrder.PATH),
        )
        fun query(case: Scenario, cursor: SearchCursor? = null): SearchPage =
            checkNotNull(store.search(scope.id, case.text, case.order, case.descending, cursor, listOf(location)))

        val firstRead = timed { query(cases.first()) }
        progress("$count rows seeded; timing search plans")
        val index = store.indexes().single()
        val sql = cases.associateWith { case ->
            val first = query(case)
            val parsed = SearchQuery.parse(case.text)
            val fts = parsed.mode == NameMatch.SUBSTRING && parsed.name.codePointCount(0, parsed.name.length) >= 3 &&
                first.next?.scanCandidates != true
            val plan = store.open().use { db ->
                EntrySearch(db, index.index, index.revision, parsed, case.order, case.descending, store.hasTrigram)
                    .select(fts, null, EntrySearch.pageSize + 1).prepare(db, explain = true).use {
                        buildList { while (it.step()) add(it.getText(3)) }.joinToString(" | ")
                    }
            }
            Sample(first, timings { query(case) }, plan)
        }
        val sqlPss = pss()

        lateinit var memory: MemoryIndex
        val loadMemory = timed { memory = MemoryIndex.load(store, generation) }
        val memoryPss = pss()
        progress("$count rows sorted in memory; comparing result pages")
        report.appendLine(
            "$count rows; db=${file.length()} B; build=${ms(build)} ms; first SQL=${ms(firstRead)} ms; " +
                "memory-load-and-sort=${ms(loadMemory)} ms; SQL-PSS=$sqlPss KiB; memory-PSS=$memoryPss KiB",
        )
        for (case in cases) {
            val sample = sql.getValue(case)
            val memoryHits = memory.search(root, case)
            var page = sample.first
            while (page.entries.isEmpty() && page.next != null) page = query(case, page.next)
            check(page.entries == memoryHits.take(page.entries.size)) { "SQL and memory disagree for ${case.label}" }
            check(page.entries.isNotEmpty() == memoryHits.isNotEmpty()) { "SQL and memory hit counts disagree for ${case.label}" }
            val reference = timings { memory.search(root, case) }
            report.appendLine(
                "${case.label} sql=${sample.latency.summary()} mem=${reference.summary()} " +
                    "first-rows=${sample.first.entries.size}; plan=${sample.plan}",
            )
            if (case.shortTail) {
                var total = 0
                var batches = 0
                var firstMatch = 0L
                val started = SystemClock.elapsedRealtimeNanos()
                var cursor: SearchCursor? = null
                val elapsed = timed {
                    do {
                        val batch = query(case, cursor)
                        batches++
                        if (total == 0 && batch.entries.isNotEmpty()) firstMatch = SystemClock.elapsedRealtimeNanos() - started
                        total += batch.entries.size
                        cursor = batch.next
                    } while (cursor != null)
                }
                check(total == memoryHits.size)
                report.appendLine(
                    "${case.label} first-hit=${ms(firstMatch)} ms; complete=${ms(elapsed)} ms; batches=$batches; hits=$total",
                )
            }
        }

        progress("$count rows; checking every name-ordered and size-ordered page")
        for (order in listOf(SearchOrder.NAME, SearchOrder.SIZE)) {
            val all = Scenario("keyset", "", order)
            val expected = memory.sorted.getValue(order)
            var total = 0
            var pages = 0
            var cursor: SearchCursor? = null
            val elapsed = timed {
                do {
                    val page = query(all, cursor)
                    check(!page.reset)
                    pages++
                    for (entry in page.entries) {
                        check(entry == expected[total].entry(root)) { "Pagination differs at row $total" }
                        total++
                    }
                    cursor = page.next
                } while (cursor != null)
            }
            check(total == count && total == expected.size)
            report.appendLine("keyset $order checked=$total; pages=$pages; elapsed=${ms(elapsed)} ms")
            val next = checkNotNull(query(all).next)
            val seekPlan = store.open().use { db ->
                EntrySearch(db, index.index, index.revision, SearchQuery.parse(""), order, false, true)
                    .select(false, next, EntrySearch.pageSize + 1).prepare(db, explain = true).use {
                        buildList { while (it.step()) add(it.getText(3)) }.joinToString(" | ")
                    }
            }
            report.appendLine("keyset $order seek-plan=$seekPlan")
        }
    }

    private fun progress(message: String) =
        sendStatus(1, Bundle().apply { putString("stream", "$message\n") })

    private fun fixtureName(i: Int, total: Int): String = when (i) {
        total - 1 -> "z-稀有标记-project-蓝.txt"
        total - 2 -> "z-稀有标记-项目.txt"
        total - 3 -> "z-Quote \"100%\".kt"
        else -> {
            val number = i.toString().padStart(6, '0')
            if (i % 20 == 0) "item-export-文件-$number.kt"
            else if (i % 3 == 0) "item-export-$number.kt"
            else "item-$number.bin"
        }
    }

    private fun verifyMigration(file: File) {
        BundledSQLiteDriver().open(file.absolutePath).use { db ->
            db.execute("""
                CREATE TABLE scopes(id TEXT PRIMARY KEY, location_id TEXT NOT NULL, relative_path TEXT NOT NULL,
                path TEXT NOT NULL, generation TEXT NOT NULL UNIQUE, entries INTEGER NOT NULL, partial INTEGER NOT NULL, updated_at INTEGER NOT NULL)
            """)
            db.execute("""
                CREATE TABLE entries(generation TEXT NOT NULL, id INTEGER NOT NULL, parent_id INTEGER NOT NULL,
                raw_name BLOB NOT NULL, name TEXT NOT NULL, name_key TEXT NOT NULL, kind INTEGER NOT NULL,
                bytes INTEGER, modified_ms INTEGER NOT NULL, PRIMARY KEY (generation, id)) WITHOUT ROWID
            """)
            db.execute("INSERT INTO scopes VALUES('legacy:', 'legacy', '', '/legacy', 'published', 2, 0, 0)")
            db.execute("""
                INSERT INTO entries VALUES
                  ('published', 1, 0, x'', '', '', 1, NULL, 0),
                  ('published', 2, 1, x'737263', 'src', 'src', 1, NULL, 0),
                  ('published', 3, 2, x'546573742e6b74', 'Test.kt', 'test.kt', 0, 12, 100),
                  ('orphan', 1, 0, x'', '', '', 1, NULL, 0)
            """)
        }
        val index = IndexStore(file)
        val locations = listOf(ScanLocation("legacy", "Legacy", "/legacy", false, true))
        val page = index.search("legacy:", "est ext:kt path:src", SearchOrder.PATH, false, null, locations)
        check(page?.generation == "published" && page.entries.single().path == "/legacy/src/Test.kt")
        val published = index.indexes().single()
        index.open().use { db ->
            db.prepare("SELECT count(*) FROM entries").use { check(it.step() && it.getLong(0) == 3L) }
            val query = SearchQuery.parse("est")
            val fallback = EntrySearch(db, published.index, 0, query, SearchOrder.NAME, false, false)
            check(fallback.page("fallback", null).entries.single().path == "/legacy/src/Test.kt")
        }
    }

    private data class Sample(val first: SearchPage, val latency: Latency, val plan: String)

    private data class Scenario(
        val label: String,
        val text: String,
        val order: SearchOrder = SearchOrder.NAME,
        val descending: Boolean = false,
        val shortTail: Boolean = false,
    )

    private data class MemoryRow(
        val id: Long,
        val path: String,
        val name: String,
        val key: String,
        val extension: String?,
        val bytes: Long,
        val modified: Long,
        val kind: EntryKind,
    ) {
        fun entry(root: String) = SearchEntry(name, "$root/$path", kind, modified, bytes.takeIf { it >= 0 })
    }

    private class MemoryIndex(rows: List<MemoryRow>) {
        val sorted = mapOf(
            SearchOrder.NAME to rows.sortedWith(compareBy<MemoryRow> { it.key }.thenBy { it.id }),
            SearchOrder.PATH to rows.sortedWith(compareBy<MemoryRow> { it.path }.thenBy { it.id }),
            SearchOrder.SIZE to rows.sortedWith(compareBy<MemoryRow> { it.bytes }.thenBy { it.id }),
            SearchOrder.MODIFIED to rows.sortedWith(compareBy<MemoryRow> { it.modified }.thenBy { it.id }),
        )

        fun search(root: String, case: Scenario): List<SearchEntry> {
            val query = SearchQuery.parse(case.text)
            val directory = query.relativeDirectory(root) ?: return emptyList()
            val prefix = directory.takeIf { it.isNotEmpty() }?.let { "$it/" }
            val rows = sorted.getValue(case.order)
            val ordered = if (case.descending) rows.asReversed() else rows
            val matches = ArrayList<SearchEntry>(EntrySearch.pageSize)
            for (row in ordered) {
                if (prefix != null && !row.path.startsWith(prefix)) continue
                if (query.extension != null && query.extension != row.extension) continue
                if (!query.sizes.matches(row.bytes)) continue
                val matched = when (query.mode) {
                    NameMatch.EXACT -> row.key == query.name
                    NameMatch.PREFIX -> row.key.startsWith(query.name)
                    NameMatch.SUBSTRING -> row.key.contains(query.name)
                }
                if (!matched) continue
                matches.add(row.entry(root))
                if (matches.size == EntrySearch.pageSize) break
            }
            return matches
        }

        companion object {
            fun load(store: IndexStore, generation: String): MemoryIndex = store.open().use { db ->
                db.prepare("""
                    SELECT id, relative_path, name, name_key, extension, coalesce(bytes, -1), modified_ms, kind
                    FROM entries WHERE generation = ? AND id > 1 ORDER BY id
                """).use { rows ->
                    rows.bindText(1, generation)
                    val entries = ArrayList<MemoryRow>()
                    while (rows.step()) {
                        val name = rows.getText(2)
                        val key = rows.getText(3)
                        entries.add(MemoryRow(
                            rows.getLong(0), rows.getText(1), name, if (key == name) name else key,
                            if (rows.isNull(4)) null else rows.getText(4).intern(),
                            rows.getLong(5), rows.getLong(6), EntryKind.entries[rows.getLong(7).toInt()],
                        ))
                    }
                    MemoryIndex(entries)
                }
            }
        }
    }

    companion object {
        private fun List<SizeFilter>.matches(bytes: Long): Boolean = all {
            bytes >= 0 && when (it.operator) {
                "<" -> bytes < it.bytes
                "<=" -> bytes <= it.bytes
                "=" -> bytes == it.bytes
                ">=" -> bytes >= it.bytes
                ">" -> bytes > it.bytes
                else -> error("Unexpected size operator")
            }
        }

        private inline fun timed(block: () -> Unit): Long {
            val start = SystemClock.elapsedRealtimeNanos()
            block()
            return SystemClock.elapsedRealtimeNanos() - start
        }

        private data class Latency(val p50: Long, val p95: Long) {
            fun summary() = "${ms(p50)}/${ms(p95)} ms"
        }

        private inline fun timings(block: () -> Unit): Latency {
            repeat(5) { block() }
            val samples = LongArray(100) { timed(block) }.apply { sort() }
            return Latency(samples[49], samples[94])
        }

        private fun ms(nanos: Long) = "%.3f".format(java.util.Locale.ROOT, nanos / 1_000_000.0)

        private fun pss(): Long {
            Runtime.getRuntime().gc()
            return Debug.getPss()
        }
    }
}
