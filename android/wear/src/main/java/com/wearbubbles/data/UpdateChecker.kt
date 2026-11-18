package com.wearbubbles.data

import com.google.gson.Gson
import com.google.gson.annotations.SerializedName
import com.wearbubbles.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

data class UpdateInfo(
    val versionName: String,
    val downloadUrl: String,
    val releaseNotes: String
)

private data class GitHubRelease(
    @SerializedName("tag_name") val tagName: String,
    val body: String? = null,
    val assets: List<GitHubAsset> = emptyList()
)

private data class GitHubAsset(
    val name: String,
    @SerializedName("browser_download_url") val downloadUrl: String
)

object UpdateChecker {
    private const val RELEASES_URL =
        "https://api.github.com/repos/BlueBubblesApp/bluebubbles-app/releases/latest"

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    private val gson = Gson()

    suspend fun checkForUpdate(settings: SettingsDataStore): UpdateInfo? = withContext(Dispatchers.IO) {
        try {
            val now = System.currentTimeMillis()
            val lastCheck = settings.getLastUpdateCheck()
            if (now - lastCheck < 24 * 60 * 60 * 1000L) return@withContext null
            settings.setLastUpdateCheck(now)

            val request = Request.Builder()
                .url(RELEASES_URL)
                .header("Accept", "application/vnd.github.v3+json")
                .build()

            val response = client.newCall(request).execute()
            if (!response.isSuccessful) return@withContext null

            val body = response.body?.string() ?: return@withContext null
            val release = gson.fromJson(body, GitHubRelease::class.java) ?: return@withContext null

            val remoteVersion = release.tagName.removePrefix("v")
            val currentVersion = BuildConfig.VERSION_NAME

            if (!isNewerVersion(remoteVersion, currentVersion)) return@withContext null

            val dismissed = settings.getDismissedUpdateVersion()
            if (dismissed == remoteVersion) return@withContext null

            val apkAsset = release.assets.firstOrNull {
                it.name.endsWith(".apk") && it.name.contains("wear", ignoreCase = true)
            } ?: return@withContext null

            UpdateInfo(
                versionName = remoteVersion,
                downloadUrl = apkAsset.downloadUrl,
                releaseNotes = release.body ?: ""
            )
        } catch (_: Exception) {
            null
        }
    }

    internal fun isNewerVersion(remote: String, current: String): Boolean {
        val rParts = remote.split(".").mapNotNull { it.toIntOrNull() }
        val cParts = current.split(".").mapNotNull { it.toIntOrNull() }
        for (i in 0 until maxOf(rParts.size, cParts.size)) {
            val r = rParts.getOrElse(i) { 0 }
            val c = cParts.getOrElse(i) { 0 }
            if (r > c) return true
            if (r < c) return false
        }
        return false
    }
}
