package com.adshield.app

import android.app.Application
import android.content.Context
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 全局崩溃采集：
 * 1. 捕获所有未处理异常（含 Flutter 引擎崩溃），写入应用外部私有目录 crash_log.txt；
 *    无需任何存储权限，用户可在文件管理器 Android/data/com.adshield.app/files 中找到并反馈。
 * 2. 记录设备/系统信息（HarmonyOS 兼容性排查用）。
 * 3. 兜底后仍回调系统默认处理器，保证系统侧也感知崩溃。
 */
class AdShieldApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        instance = this
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            runCatching {
                writeCrash(this@AdShieldApplication, thread, throwable)
            }
            previous?.uncaughtException(thread, throwable)
        }
    }

    companion object {
        @Volatile
        var instance: AdShieldApplication? = null
            private set

        fun logFile(ctx: Context): File {
            val dir = ctx.getExternalFilesDir(null) ?: ctx.filesDir
            return File(dir, "crash_log.txt")
        }

        fun appendLog(ctx: Context, text: String) {
            runCatching {
                logFile(ctx).appendText(
                    "---- ${SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.CHINA).format(Date())} ----\n$text\n"
                )
            }
        }

        private fun writeCrash(ctx: Context, thread: Thread, e: Throwable) {
            val sw = StringWriter()
            e.printStackTrace(PrintWriter(sw))
            val sys = """
                device: ${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}
                system: ${android.os.Build.VERSION.RELEASE} (API ${android.os.Build.VERSION.SDK_INT})
                thread: ${thread.name}
            """.trimIndent()
            appendLog(ctx, "[CRASH]\n$sys\n${sw}")
        }
    }
}
