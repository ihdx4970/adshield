package com.adshield.app

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Build
import androidx.annotation.NonNull
import androidx.window.core.ExperimentalWindowApi
import androidx.window.layout.DisplayFeature
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker
import androidx.window.layout.WindowLayoutInfo
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicLong

/// MainActivity：
/// 1. MethodChannel "adshield/native" —— VPN 启停 / 状态 / 统计 / 规则重载
/// 2. EventChannel  "adshield/fold"   —— 折叠屏姿态（Jetpack WindowManager）
class MainActivity : FlutterActivity() {

    private val scope = MainScope()
    private var vpnPermissionFuture: ((Boolean) -> Unit)? = null
    private var foldSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger: BinaryMessenger = flutterEngine.dartExecutor.binaryMessenger

        // ---------- MethodChannel ----------
        MethodChannel(messenger, "adshield/native").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                "startEngine" -> requestVpnPermission { granted ->
                    if (granted) {
                        FilterVpnService.isRunning.set(false)
                        startForegroundServiceCompat()
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "stopEngine" -> {
                    stopService(Intent(this, FilterVpnService::class.java))
                    FilterVpnService.isRunning.set(false)
                    result.success(true)
                }
                "getStatus" -> {
                    result.success(
                        if (FilterVpnService.isRunning.get()) "running" else "off"
                    )
                }
                "getStats" -> {
                    val prefs = getSharedPreferences("adshield_stats", MODE_PRIVATE)
                    val day = prefs.getLong("stats_date", 0)
                    val sameDay = isSameLocalDay(day, System.currentTimeMillis())
                    result.success(
                        mapOf(
                            "blockedToday" to if (sameDay) prefs.getLong("blocked_today", 0) else 0L,
                            "allowedToday" to if (sameDay) prefs.getLong("allowed_today", 0) else 0L,
                            "totalBlocked" to FilterVpnService.totalBlocked.get(),
                        )
                    )
                }
                "reloadRules" -> {
                    FilterVpnService.instance?.loadRules()
                    result.success(FilterVpnService.instance != null || !FilterVpnService.isRunning.get())
                }
                else -> result.notImplemented()
                }
            } catch (e: Exception) {
                AdShieldApplication.appendLog(this, "[MethodChannel ${call.method}]\n${e.stackTraceToString()}")
                if (e.message?.contains("already") == true) return
                result.error("NATIVE_ERROR", e.message, null)
            }
        }

        // ---------- EventChannel：折叠姿态 ----------
        EventChannel(messenger, "adshield/fold").setStreamHandler(
            object : EventChannel.StreamHandler {
                private var foldJob: kotlinx.coroutines.Job? = null
                private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

                /// 保证 sink 只在主线程调用，且吞掉发送异常（对端销毁时 Flutter 层会抛错）
                private fun safeSend(data: Any?) {
                    mainHandler.post {
                        try {
                            sink?.success(data)
                        } catch (_: Exception) {
                        }
                    }
                }

                @OptIn(ExperimentalWindowApi::class)
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    foldSink = sink
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                        safeSend(mapOf("posture" to "unknown", "hingeOrientation" to "none"))
                        return
                    }
                    // 每次监听用独立 Job，取消后仍可重新监听（修复旧版 scope 永久失效问题）
                    foldJob = scope.launch(Dispatchers.Main) {
                        try {
                            WindowInfoTracker.getOrCreate(this@MainActivity)
                                .windowLayoutInfo(this@MainActivity)
                                .collectLatest { info ->
                                    val f = info.displayFeatures.firstNotNullOfOrNull {
                                        it as? FoldingFeature
                                    }
                                    safeSend(
                                        f?.toMap() ?: mapOf(
                                            "posture" to "flat",
                                            "hingeOrientation" to "none",
                                        )
                                    )
                                }
                        } catch (_: Exception) {
                            // 某些 ROM（含鸿蒙）上 WindowManager API 可能异常，姿态退化为 unknown，不影响拦截功能
                            safeSend(mapOf("posture" to "unknown", "hingeOrientation" to "none"))
                        }
                    }
                }

                override fun onCancel(args: Any?) {
                    foldJob?.cancel()
                    foldJob = null
                    foldSink = null
                }
            }
        )
    }

    private fun FoldingFeature.toMap(): Map<String, String> {
        val postureName = when (state) {
            FoldingFeature.State.FLAT -> "flat"
            FoldingFeature.State.HALF_OPENED -> "halfOpened"
            else -> "closed"
        }
        val orient = when (orientation) {
            FoldingFeature.Orientation.HORIZONTAL -> "horizontal"
            FoldingFeature.Orientation.VERTICAL -> "vertical"
            else -> "none"
        }
        return mapOf("posture" to postureName, "hingeOrientation" to orient)
    }

    @SuppressLint("NewApi")
    private fun startForegroundServiceCompat() {
        val intent = Intent(this, FilterVpnService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    /// VPN 权限申请（VpnService.prepare）
    private fun requestVpnPermission(onResult: (Boolean) -> Unit) {
        val intent = VpnService.prepare(this)
        if (intent == null) {
            onResult(true)
            return
        }
        vpnPermissionFuture = onResult
        startActivityForResult(intent, REQ_VPN)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_VPN) {
            vpnPermissionFuture?.invoke(resultCode == Activity.RESULT_OK)
            vpnPermissionFuture = null
        }
    }

    private fun isSameLocalDay(t1: Long, t2: Long): Boolean {
        val c1 = java.util.Calendar.getInstance().apply { timeInMillis = t1 }
        val c2 = java.util.Calendar.getInstance().apply { timeInMillis = t2 }
        return c1.get(java.util.Calendar.YEAR) == c2.get(java.util.Calendar.YEAR) &&
                c1.get(java.util.Calendar.DAY_OF_YEAR) == c2.get(java.util.Calendar.DAY_OF_YEAR)
    }

    companion object {
        private const val REQ_VPN = 1001
    }
}
