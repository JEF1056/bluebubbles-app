package com.wearbubbles.api

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
    private var currentHeaders: Map<String, String> = emptyMap()

    @Volatile
    private var api: BlueBubblesApi? = null

    val okHttpClient: OkHttpClient by lazy {
        val headersInterceptor = Interceptor { chain ->
            val builder = chain.request().newBuilder()
            currentHeaders.forEach { (k, v) ->
                if (k.isNotBlank()) builder.header(k, v)
            }
            chain.proceed(builder.build())
        }
        OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .addInterceptor(headersInterceptor)
            .build()
    }

    fun configureHeaders(serverUrl: String, headers: Map<String, String>) {
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

    fun getAttachmentUrl(serverUrl: String, password: String, attachmentGuid: String): String {
        val base = serverUrl.trim().trimEnd('/')
        val encodedGuid = URLEncoder.encode(attachmentGuid, "UTF-8")
        val encodedPass = URLEncoder.encode(password, "UTF-8")
        return "$base/api/v1/attachment/$encodedGuid/download?password=$encodedPass"
    }
}
