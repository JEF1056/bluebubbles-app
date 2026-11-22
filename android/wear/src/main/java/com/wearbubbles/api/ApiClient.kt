package com.wearbubbles.api

import com.wearbubbles.socket.SocketManager
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import retrofit2.Retrofit
import retrofit2.converter.gson.GsonConverterFactory
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

object ApiClient {
    @Volatile
    private var currentBaseUrl: String = ""

    @Volatile
    private var configuredServerUrl: HttpUrl? = null

    @Volatile
    private var currentHeaders: Map<String, String> = emptyMap()

    @Volatile
    private var api: BlueBubblesApi? = null

    internal fun shouldAttachCustomHeaders(requestUrl: HttpUrl, serverUrl: HttpUrl?): Boolean {
        if (serverUrl == null) return false
        if (!requestUrl.host.equals(serverUrl.host, ignoreCase = true)) return false
        if (requestUrl.port != serverUrl.port) return false
        if (serverUrl.isHttps && !requestUrl.isHttps) return false
        return true
    }

    val okHttpClient: OkHttpClient by lazy {
        val headersInterceptor = Interceptor { chain ->
            val request = chain.request()
            if (shouldAttachCustomHeaders(request.url, configuredServerUrl)) {
                val builder = request.newBuilder()
                currentHeaders.forEach { (k, v) ->
                    if (k.isNotBlank()) builder.header(k, v)
                }
                chain.proceed(builder.build())
            } else {
                chain.proceed(request)
            }
        }
        OkHttpClient.Builder()
            .dns(SocketManager.ipv4FirstDns)
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .addInterceptor(headersInterceptor)
            .build()
    }

    fun configureHeaders(serverUrl: String, headers: Map<String, String>) {
        configuredServerUrl = serverUrl.trim().toHttpUrlOrNull()
        val merged = headers.toMutableMap()
        if (serverUrl.contains("ngrok")) {
            merged["ngrok-skip-browser-warning"] = "true"
        } else if (serverUrl.contains("zrok")) {
            merged["skip_zrok_interstitial"] = "true"
        }
        currentHeaders = merged
    }

    fun getApi(serverUrl: String, customHeaders: Map<String, String> = currentHeaders): BlueBubblesApi {
        val normalized = serverUrl.trim().trimEnd('/') + "/"
        configureHeaders(normalized, customHeaders)
        if (api == null || currentBaseUrl != normalized) {
            synchronized(this) {
                if (api == null || currentBaseUrl != normalized) {
                    currentBaseUrl = normalized
                    api = Retrofit.Builder()
                        .baseUrl(normalized)
                        .client(okHttpClient)
                        .addConverterFactory(GsonConverterFactory.create())
                        .build()
                        .create(BlueBubblesApi::class.java)
                }
            }
        }
        return api!!
    }

    fun getAttachmentUrl(
        serverUrl: String,
        password: String,
        attachmentGuid: String,
        mimeType: String? = null
    ): String {
        val base = serverUrl.trim().trimEnd('/')
        val encodedGuid = URLEncoder.encode(attachmentGuid, "UTF-8")
        val encodedPass = URLEncoder.encode(password, "UTF-8")
        val normalizedMime = mimeType?.substringBefore(';')?.trim()?.lowercase()
        val resizeSuffix = if (normalizedMime != null && normalizedMime.startsWith("image/") && normalizedMime != "image/gif") {
            "&width=512&quality=good"
        } else {
            ""
        }
        return "$base/api/v1/attachment/$encodedGuid/download?password=$encodedPass$resizeSuffix"
    }

    @Synchronized
    fun reset() {
        currentBaseUrl = ""
        configuredServerUrl = null
        currentHeaders = emptyMap()
        api = null
    }
}
