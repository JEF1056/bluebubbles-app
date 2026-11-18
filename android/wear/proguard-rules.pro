# Retrofit
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes Exceptions
-keep class com.wearbubbles.api.dto.** { *; }
-keep class com.wearbubbles.relay.** { *; }
-keep,allowobfuscation,allowshrinking interface retrofit2.Call
-keep,allowobfuscation,allowshrinking class retrofit2.Response
-keep,allowobfuscation,allowshrinking class kotlin.coroutines.Continuation
-keep interface com.wearbubbles.api.BlueBubblesApi { *; }
-keep class retrofit2.** { *; }
-dontwarn retrofit2.**

# OkHttp
-keep class okhttp3.** { *; }
-dontwarn okhttp3.**
-dontwarn okio.**

# Gson
-keepattributes Signature
-keepattributes EnclosingMethod
-keep class com.google.gson.** { *; }
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken

# Socket.IO
-keep class io.socket.** { *; }
-dontwarn io.socket.**

# DataLayerListenerService payload
-keep class com.wearbubbles.DataLayerListenerService$SetupPayload { *; }

# Room
-keep class * extends androidx.room.RoomDatabase
-dontwarn androidx.room.paging.**

# Coroutines
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}
-keepclassmembers class kotlinx.coroutines.** { volatile <fields>; }
