package io.github.eltancex.rtpath.scan

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.Settings
import java.io.File

internal data class ScanScope(
    val id: String,
    val locationId: String,
    val relativePath: String,
    val base: String,
    val path: String,
)

internal class ScanLocations(private val context: Context) {
    @Suppress("DEPRECATION")
    private fun sharedAllowed(): Boolean = if (Build.VERSION.SDK_INT >= 30) {
        Environment.isExternalStorageManager()
    } else {
        Environment.isExternalStorageLegacy() &&
            context.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
    }

    @Suppress("DEPRECATION")
    fun list(): List<ScanLocation> = buildList {
        add(ScanLocation("app-files", "应用内部目录", context.filesDir.absolutePath, false, true))
        context.getExternalFilesDir(null)?.let {
            add(ScanLocation("app-external", "应用外部专属目录", it.absolutePath, false, true))
        }

        val allowed = sharedAllowed()
        if (Build.VERSION.SDK_INT >= 30) {
            for (volume in context.getSystemService(StorageManager::class.java).storageVolumes) {
                val directory = volume.directory ?: continue
                if (volume.state !in setOf(Environment.MEDIA_MOUNTED, Environment.MEDIA_MOUNTED_READ_ONLY)) continue
                val identity = if (volume.isPrimary) "primary" else volume.uuid ?: continue
                add(ScanLocation("shared-$identity", volume.getDescription(context), directory.absolutePath, true, allowed))
            }
        } else {
            add(ScanLocation("shared-primary", "共享存储", Environment.getExternalStorageDirectory().absolutePath, true, allowed))
        }
    }

    fun resolve(location: ScanLocation, relativePath: String): ScanScope {
        require(location.canScan) { "该范围需要存储授权" }
        val relative = relativePath.trimEnd('/')
        require(!relativePath.startsWith('/') && '\u0000' !in relative &&
            (relative.isEmpty() || relative.split('/').all { it.isNotEmpty() && it != "." && it != ".." })) {
            "请输入范围内的相对目录"
        }
        val path = if (relative.isEmpty()) location.path else File(location.path, relative).absolutePath
        return ScanScope("${location.id}:$relative", location.id, relative, location.path, path)
    }

    @Suppress("DEPRECATION")
    fun requestSharedAccess(activity: Activity) {
        if (Build.VERSION.SDK_INT < 30) {
            activity.requestPermissions(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE), 1)
            return
        }

        val packageUri = Uri.fromParts("package", context.packageName, null)
        val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, packageUri)
        try {
            activity.startActivity(intent)
        } catch (_: android.content.ActivityNotFoundException) {
            activity.startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
        }
    }
}
