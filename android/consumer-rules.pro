# asset-delivery-ktx references an annotation from play-services-basement that
# the library does not ship; it is never needed at runtime.
-dontwarn com.google.android.gms.common.annotation.NoNullnessRewrite

# asset-delivery uses WorkManager 2.9, whose Room database is created by
# reflection (WorkDatabase_Impl). AGP 9's R8 full mode strips its constructor,
# crashing the app at startup in androidx.startup.InitializationProvider.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
