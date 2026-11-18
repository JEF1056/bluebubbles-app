package com.bluebubbles.messaging.services.network

import retrofit2.Call
import retrofit2.http.*

/**
 * Retrofit API interface for BlueBubbles server endpoints
 */
interface BlueBubblesApi {
    
    /**
     * Send a text message
     */
    @POST("message/text")
    fun sendMessage(
        @Query("guid") guid: String,
        @Body request: SendMessageRequest
    ): Call<ApiResponse>
    
    /**
     * Send a reaction/tapback
     */
    @POST("message/react")
    fun sendTapback(
        @Query("guid") guid: String,
        @Body request: SendTapbackRequest
    ): Call<ApiResponse>
    
    /**
     * Ping the server
     */
    @GET("ping")
    fun ping(
        @Query("guid") guid: String
    ): Call<ApiResponse>

    @POST("facetime/call")
    fun placeFaceTimeCall(
        @Query("guid") guid: String,
        @Body request: FaceTimeCallRequest
    ): Call<ApiResponse>

    @POST("facetime/decline/{callUuid}")
    fun declineFaceTimeCall(
        @Path("callUuid") callUuid: String,
        @Query("guid") guid: String
    ): Call<ApiResponse>

    @POST("facetime/leave/{callUuid}")
    fun leaveFaceTimeCall(
        @Path("callUuid") callUuid: String,
        @Query("guid") guid: String
    ): Call<ApiResponse>

    @POST("facetime/set-muted/{callUuid}")
    fun setFaceTimeMuted(
        @Path("callUuid") callUuid: String,
        @Query("guid") guid: String,
        @Body request: FaceTimeSetMutedRequest
    ): Call<ApiResponse>
}
