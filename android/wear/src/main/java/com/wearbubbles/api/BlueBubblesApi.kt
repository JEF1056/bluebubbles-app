package com.wearbubbles.api

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.wearbubbles.api.dto.ApiResponse
import com.wearbubbles.api.dto.ChatDto
import com.wearbubbles.api.dto.ChatQueryRequest
import com.wearbubbles.api.dto.ContactDto
import com.wearbubbles.api.dto.CreateChatRequest
import com.wearbubbles.api.dto.ICloudContactDto
import com.wearbubbles.api.dto.MessageDto
import com.wearbubbles.api.dto.MessageQueryRequest
import com.wearbubbles.api.dto.PinnedChatsResponse
import com.wearbubbles.api.dto.ReactRequest
import com.wearbubbles.api.dto.SendMessageRequest
import okhttp3.MultipartBody
import okhttp3.RequestBody
import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.Multipart
import retrofit2.http.POST
import retrofit2.http.Part
import retrofit2.http.Path
import retrofit2.http.Query

interface BlueBubblesApi {
    @GET("/api/v1/ping")
    suspend fun ping(
        @Query("password") password: String
    ): ApiResponse<JsonElement>

    @POST("/api/v1/chat/query")
    suspend fun getChats(
        @Query("password") password: String,
        @Body body: ChatQueryRequest
    ): ApiResponse<List<ChatDto>>

    @GET("/api/v1/chat/pinned")
    suspend fun getPinnedChats(
        @Query("password") password: String
    ): ApiResponse<PinnedChatsResponse>

    @GET("/api/v1/chat/{guid}")
    suspend fun getChat(
        @Path("guid") guid: String,
        @Query("password") password: String,
        @Query("with") with: String = "participants,lastMessage"
    ): ApiResponse<ChatDto>

    @POST("/api/v1/message/query")
    suspend fun getMessages(
        @Query("password") password: String,
        @Body body: MessageQueryRequest
    ): ApiResponse<List<MessageDto>>

    @POST("/api/v1/message/text")
    suspend fun sendMessage(
        @Query("password") password: String,
        @Body body: SendMessageRequest
    ): ApiResponse<MessageDto>

    @POST("/api/v1/chat/new")
    suspend fun createChat(
        @Query("password") password: String,
        @Body body: CreateChatRequest
    ): ApiResponse<ChatDto>

    @POST("/api/v1/message/react")
    suspend fun reactToMessage(
        @Query("password") password: String,
        @Body body: ReactRequest
    ): ApiResponse<MessageDto>

    @POST("/api/v1/message/{guid}/translate")
    suspend fun translateMessage(
        @Path("guid") guid: String,
        @Query("password") password: String
    ): ApiResponse<JsonObject>

    @Multipart
    @POST("/api/v1/message/attachment")
    suspend fun sendAttachment(
        @Query("password") password: String,
        @Part("chatGuid") chatGuid: RequestBody,
        @Part("tempGuid") tempGuid: RequestBody,
        @Part("name") name: RequestBody,
        @Part("method") method: RequestBody,
        @Part("isAudioMessage") isAudioMessage: RequestBody,
        @Part attachment: MultipartBody.Part
    ): ApiResponse<MessageDto>

    @POST("/api/v1/chat/{guid}/read")
    suspend fun markChatRead(
        @Path("guid") guid: String,
        @Query("password") password: String
    ): ApiResponse<Any>

    @GET("/api/v1/contact")
    suspend fun getContacts(
        @Query("password") password: String,
        @Query("extraProperties") extraProperties: String = "avatar"
    ): ApiResponse<List<ContactDto>>

    @GET("/api/v1/icloud/contact")
    suspend fun getICloudContact(
        @Query("password") password: String
    ): ApiResponse<ICloudContactDto>
}
