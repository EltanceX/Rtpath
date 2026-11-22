package io.github.eltancex.rtpath

import android.content.Context
import android.os.Build
import android.os.Environment
import android.system.Os
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import java.io.File
import java.io.IOException
import java.nio.file.Files

internal object NativeFilesystemProbe {
    init {
        System.loadLibrary("rtpath_probe")
    }

    external fun inspect(fixturePath: ByteArray): Array<String>
}

internal object CapabilityProbe {
    @Suppress("DEPRECATION") // The legacy path is intentionally probed as a real FUSE entry.
    fun inspect(context: Context): Map<String, Any?> {
        val fixture = Files.createTempDirectory(context.cacheDir.toPath(), "rtpath-probe-").toFile()
        val (nativeAbi, fileError, inotifyError) = try {
            File(fixture, "seed.txt").writeText("rtpath\n")
            NativeFilesystemProbe.inspect(fixture.absolutePath.toByteArray(Charsets.UTF_8))
        } finally {
            fixture.deleteRecursively()
        }

        return mapOf(
            "androidRelease" to Build.VERSION.RELEASE,
            "androidApi" to Build.VERSION.SDK_INT,
            "kernelRelease" to Os.uname().release,
            "nativeAbi" to nativeAbi,
            "applicationUid" to Os.getuid(),
            "fileError" to fileError.ifEmpty { null },
            "inotifyError" to inotifyError.ifEmpty { null },
            "sqlite" to sqlite(),
            "allFilesAccess" to if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager() else null,
            "directories" to listOf(
                directory("应用内部目录", context.filesDir),
                directory("应用外部专属目录", context.getExternalFilesDir(null)),
                directory("共享存储根目录", Environment.getExternalStorageDirectory()),
            ),
        )
    }

    private fun sqlite(): Map<String, Any?> {
        var version: String? = null
        val error = try {
            BundledSQLiteDriver().open(":memory:").use { connection ->
                connection.prepare("SELECT sqlite_version()").use { statement ->
                    check(statement.step()) { "SQLite did not return a version" }
                    version = statement.getText(0)
                }
                connection.prepare("CREATE VIRTUAL TABLE names USING fts5(name, tokenize='trigram')").use {
                    it.step()
                }
                connection.prepare("INSERT INTO names VALUES (?), (?)").use {
                    it.bindText(1, "RtPath-项目-索引.kt")
                    it.bindText(2, "RtPath-项目说明.kt")
                    it.step()
                }
                connection.prepare("SELECT rowid FROM names WHERE names MATCH ? ORDER BY rowid").use {
                    it.bindText(1, "\"项目-\"")
                    check(it.step() && it.getLong(0) == 1L && !it.step()) {
                        "FTS5 trigram did not return the expected Chinese substring match"
                    }
                }
            }
            null
        } catch (failure: Exception) {
            failure.message ?: failure.javaClass.simpleName
        } catch (failure: LinkageError) {
            failure.message ?: failure.javaClass.simpleName
        }
        return mapOf("version" to version, "trigramError" to error)
    }

    private fun directory(label: String, file: File?): Map<String, String?> {
        val error = if (file == null) {
            "目录不可用"
        } else {
            try {
                Files.newDirectoryStream(file.toPath()).use { it.iterator().hasNext() }
                null
            } catch (failure: IOException) {
                failure.message ?: failure.javaClass.simpleName
            } catch (failure: SecurityException) {
                failure.message ?: failure.javaClass.simpleName
            }
        }
        return mapOf("label" to label, "path" to file?.absolutePath, "error" to error)
    }
}
