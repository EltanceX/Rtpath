package io.github.eltancex.rtpath.scan

import android.icu.lang.UCharacter
import java.math.BigDecimal
import java.text.Normalizer
import java.util.Locale

internal enum class NameMatch { SUBSTRING, EXACT, PREFIX }

internal data class SizeFilter(val operator: String, val bytes: Long)

internal data class SearchQuery(
    val name: String,
    val mode: NameMatch,
    val extension: String?,
    val directory: String?,
    val sizes: List<SizeFilter>,
) {
    fun relativeDirectory(root: String): String? {
        val filter = directory ?: return ""
        if (!filter.startsWith('/')) return if (filter == ".") "" else filter
        val base = root.trimEnd('/')
        if (filter == "/" || filter == base || base.startsWith("$filter/")) return ""
        return if (filter.startsWith("$base/")) filter.substring(base.length + 1) else null
    }

    companion object {
        private val field = Regex("(name|prefix|ext|path|size):", RegexOption.IGNORE_CASE)
        private val size = Regex("(<=|>=|<|>|=)?([0-9]+(?:\\.[0-9]+)?)(B|KB|MB|GB|TB|KiB|MiB|GiB|TiB)?", RegexOption.IGNORE_CASE)

        fun parse(text: String): SearchQuery {
            require(text.length <= 4096 && '\u0000' !in text) { "请输入不超过 4096 字符的查询" }
            val plain = StringBuilder()
            var plainEnd: Int? = null
            var named: String? = null
            var mode = NameMatch.SUBSTRING
            var extension: String? = null
            var directory: String? = null
            val sizes = mutableListOf<SizeFilter>()
            var offset = 0
            while (offset < text.length) {
                if (text[offset].isWhitespace()) {
                    offset++
                    continue
                }
                val tokenStart = offset
                val directive = field.matchAt(text, tokenStart)
                if (directive != null) offset = directive.range.last + 1
                val token = readToken(text, offset)
                offset = token.end
                if (directive == null) {
                    if (plain.isNotEmpty()) plain.append(plainEnd?.let { text.substring(it, tokenStart) } ?: " ")
                    plain.append(token.value)
                    plainEnd = offset
                    continue
                }

                plainEnd = null
                val value = token.value
                require(value.isNotEmpty()) { "请填写 ${directive.value} 的筛选值" }
                when (directive.groupValues[1].lowercase(Locale.ROOT)) {
                    "name", "prefix" -> {
                        require(named == null) { "请选择一种名称匹配方式" }
                        mode = if (directive.value.equals("name:", ignoreCase = true)) NameMatch.EXACT else NameMatch.PREFIX
                        named = value
                    }
                    "ext" -> {
                        require(extension == null) { "查询只支持一个 ext: 扩展名" }
                        val suffix = value.removePrefix(".")
                        require(suffix.isNotEmpty() && '.' !in suffix && '/' !in suffix) { "请输入最后一段扩展名，例如 ext:kt" }
                        extension = searchKey(suffix)
                    }
                    "path" -> {
                        require(directory == null) { "查询只支持一个 path: 目录" }
                        val path = value.trimEnd('/').ifEmpty { "/" }
                        require(path == "/" || path == "." ||
                            path.removePrefix("/").split('/').none { it.isEmpty() || it == "." || it == ".." }) {
                            "请输入索引范围内的有效目录路径"
                        }
                        directory = path
                    }
                    "size" -> {
                        require(sizes.size < 16) { "最多支持 16 个大小条件" }
                        sizes.add(parseSize(value))
                    }
                }
            }
            require(named == null || plain.isEmpty()) { "name: 和 prefix: 各自使用一个名称，可用引号包住空格" }
            return SearchQuery(searchKey(named ?: plain.toString()), mode, extension, directory, sizes)
        }

        private data class Token(val value: String, val end: Int)

        private fun readToken(text: String, start: Int): Token {
            var end = start
            if (start == text.length || text[start] != '"') {
                while (end < text.length && !text[end].isWhitespace()) end++
                return Token(text.substring(start, end), end)
            }
            end++
            val value = StringBuilder()
            while (end < text.length) {
                val next = text[end++]
                if (next == '"') {
                    require(end == text.length || text[end].isWhitespace()) { "引号后的查询条件需要用空格分隔" }
                    return Token(value.toString(), end)
                }
                if (next == '\\' && end < text.length && (text[end] == '"' || text[end] == '\\')) {
                    value.append(text[end++])
                } else {
                    value.append(next)
                }
            }
            throw IllegalArgumentException("请补全查询中的双引号")
        }

        private fun parseSize(text: String): SizeFilter {
            val match = size.matchEntire(text) ?: throw IllegalArgumentException("大小格式示例为 size:>100MB 或 size:<=2MiB")
            val (operator, amount, unit) = match.destructured
            val suffix = unit.uppercase(Locale.ROOT)
            val exponent = " KMGT".indexOf(suffix.firstOrNull() ?: 'B').coerceAtLeast(0)
            val base = if (suffix.endsWith("IB")) 1024 else 1000
            val bytes = try {
                BigDecimal(amount).multiply(BigDecimal(base).pow(exponent)).longValueExact()
            } catch (_: ArithmeticException) {
                throw IllegalArgumentException("大小条件必须换算为有效的整数字节数")
            }
            return SizeFilter(operator.ifEmpty { "=" }, bytes)
        }
    }
}

internal fun searchKey(text: String): String {
    val normalized = Normalizer.normalize(text, Normalizer.Form.NFC)
    return Normalizer.normalize(UCharacter.foldCase(normalized, true), Normalizer.Form.NFC)
}

internal fun extensionKey(name: String, kind: Int): String? {
    val dot = name.lastIndexOf('.')
    return if (kind == EntryKind.DIRECTORY.ordinal || dot <= 0 || dot == name.lastIndex) null else searchKey(name.substring(dot + 1))
}

// SQLite's BINARY collation orders UTF-8 by code point. Increment the last
// incrementable code point to get the exclusive bound of a literal prefix.
internal fun prefixEnd(value: String): String? {
    var end = value.length
    while (end > 0) {
        val point = value.codePointBefore(end)
        end -= Character.charCount(point)
        if (point == Character.MAX_CODE_POINT) continue
        val next = if (point == 0xd7ff) 0xe000 else point + 1
        return value.substring(0, end) + String(Character.toChars(next))
    }
    return null
}
