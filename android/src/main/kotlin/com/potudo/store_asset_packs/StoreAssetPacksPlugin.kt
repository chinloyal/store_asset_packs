package com.potudo.store_asset_packs

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import com.google.android.play.core.assetpacks.AssetPackManager
import com.google.android.play.core.assetpacks.AssetPackManagerFactory
import com.google.android.play.core.assetpacks.AssetPackState
import com.google.android.play.core.assetpacks.AssetPackStateUpdateListener
import com.google.android.play.core.assetpacks.model.AssetPackStatus
import com.google.android.play.core.assetpacks.model.AssetPackStorageMethod
import com.google.android.play.core.ktx.requestFetch
import com.google.android.play.core.ktx.requestPackStates
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/** Play Asset Delivery behind the store_asset_packs channels. */
class StoreAssetPacksPlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private lateinit var events: EventChannel
    private var manager: AssetPackManager? = null
    private var activity: Activity? = null
    private var sink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    private var scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private val listener = AssetPackStateUpdateListener { state ->
        main.post { sink?.success(encode(state)) }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        channel = MethodChannel(binding.binaryMessenger, "store_asset_packs")
        channel.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "store_asset_packs/updates")
        events.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        manager?.unregisterListener(listener)
        sink = null
        scope.cancel()
    }

    private fun manager(): AssetPackManager =
        manager ?: AssetPackManagerFactory.getInstance(context).also { manager = it }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getStates" -> launch(result) {
                val packs = call.packs()
                try {
                    val states = manager().requestPackStates(packs).packStates()
                    packs.associateWith { name ->
                        states[name]?.let(::encode)
                            ?: mapOf("name" to name, "status" to "unknown")
                    }
                } catch (e: Exception) {
                    // E.g. -1 APP_UNAVAILABLE for an install that didn't come from Play
                    // (flutter run): report it per pack instead of failing the call.
                    packs.associateWith { name ->
                        mapOf(
                            "name" to name,
                            "status" to "failed",
                            "errorCode" to (errorCode(e) ?: -100),
                            "errorMessage" to (e.message ?: e.toString()),
                        )
                    }
                }
            }
            "fetch" -> launch(result) {
                manager().requestFetch(call.packs())
                null
            }
            "getPackPath" -> result.success(packPath(call.argument<String>("pack")!!))
            "showCellularDataConfirmation" -> showConfirmation(result)
            "release" -> result.success(null)
            // The app-specific external files dir (/sdcard/Android/data/<pkg>/files),
            // which `adb push` can write to without run-as.
            "getDevOverrideRoot" -> result.success(
                File(context.getExternalFilesDir(null) ?: context.filesDir, DEV_DIR).absolutePath,
            )
            else -> result.notImplemented()
        }
    }

    private fun MethodCall.packs(): List<String> = argument<List<String>>("packs") ?: emptyList()

    private fun launch(result: Result, block: suspend () -> Any?) {
        scope.launch {
            try {
                result.success(block())
            } catch (e: Exception) {
                result.error("store_asset_packs", e.message ?: e.toString(), errorCode(e))
            }
        }
    }

    /**
     * The directory holding the pack's files: <assetsPath>/<pack>, since the
     * generated module puts them under a folder named after the pack (Play needs
     * every asset path to be unique across packs). Only fast-follow and on-demand
     * packs, which Play stores as files, have one: install-time packs live inside
     * the APK and are read through AssetManager instead, so this returns null for
     * them.
     */
    private fun packPath(pack: String): String? {
        val location = manager().getPackLocation(pack) ?: return null
        if (location.packStorageMethod() != AssetPackStorageMethod.STORAGE_FILES) return null
        val assets = location.assetsPath() ?: return null
        return File(assets, pack).takeIf { it.isDirectory }?.absolutePath
    }

    private fun showConfirmation(result: Result) {
        val activity = activity
        if (activity == null) {
            result.error("store_asset_packs", "showCellularDataConfirmation needs an Activity", null)
            return
        }
        manager().showConfirmationDialog(activity)
            .addOnSuccessListener { code -> result.success(code == Activity.RESULT_OK) }
            .addOnFailureListener { e ->
                // -14 CONFIRMATION_NOT_REQUIRED: nothing to confirm, so the download can go ahead.
                if (errorCode(e) == -14) result.success(true)
                else result.error("store_asset_packs", e.message ?: e.toString(), errorCode(e))
            }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        manager().registerListener(listener)
    }

    override fun onCancel(arguments: Any?) {
        manager?.unregisterListener(listener)
        sink = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    companion object {
        const val DEV_DIR = "store_asset_packs_dev"

        private fun errorCode(e: Exception): Int? =
            (e as? com.google.android.play.core.assetpacks.AssetPackException)?.errorCode

        fun statusName(status: Int): String = when (status) {
            AssetPackStatus.NOT_INSTALLED -> "notInstalled"
            AssetPackStatus.PENDING -> "pending"
            AssetPackStatus.DOWNLOADING -> "downloading"
            AssetPackStatus.TRANSFERRING -> "transferring"
            AssetPackStatus.WAITING_FOR_WIFI -> "waitingForWifi"
            AssetPackStatus.REQUIRES_USER_CONFIRMATION -> "requiresUserConfirmation"
            AssetPackStatus.COMPLETED -> "completed"
            AssetPackStatus.FAILED -> "failed"
            AssetPackStatus.CANCELED -> "canceled"
            else -> "unknown"
        }

        fun encode(state: AssetPackState): Map<String, Any?> {
            val status = state.status()
            val total = state.totalBytesToDownload()
            val done = state.bytesDownloaded()
            val progress = when {
                status == AssetPackStatus.COMPLETED || status == AssetPackStatus.TRANSFERRING -> 1.0
                total > 0 -> done.toDouble() / total
                else -> 0.0
            }
            return mapOf(
                "name" to state.name(),
                "status" to statusName(status),
                "bytesDownloaded" to done,
                "totalBytes" to total,
                "progress" to progress,
                "errorCode" to state.errorCode().takeIf { it != 0 },
            )
        }
    }
}
