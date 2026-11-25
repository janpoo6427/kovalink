package io.kova.kovalink

import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.GLES20
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// 설정 → 진단 (lib/src/features/road_view/renderer_diagnostics.dart):
/// device facts, logcat lines with tag "kovalink", and this app's own
/// recent rendering log lines.
class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "io.kova.kovalink/diagnostics"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "log" -> {
                    val text = call.arguments as? String ?: ""
                    for (line in text.split('\n')) Log.i(TAG, line)
                    result.success(null)
                }
                "deviceInfo" -> background(result) { deviceInfo() }
                "recentLog" -> background(result) { recentLog() }
                else -> result.notImplemented()
            }
        }
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        Thread {
            val value = try {
                work()
            } catch (t: Throwable) {
                Log.w(TAG, "diagnostics failed: $t")
                null
            }
            main.post { result.success(value) }
        }.start()
    }

    private fun deviceInfo(): Map<String, String> {
        val out = linkedMapOf(
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "device" to Build.DEVICE,
            "release" to Build.VERSION.RELEASE,
            "sdk" to Build.VERSION.SDK_INT.toString(),
            "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: "?"),
            "hardware" to Build.HARDWARE,
        )
        if (Build.VERSION.SDK_INT >= 31) out["soc"] = Build.SOC_MODEL
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        out["glEs"] = am.deviceConfigurationInfo.glEsVersion
        out["vulkan"] = vulkanLevel()
        out.putAll(glInfo())
        out["flutterBackend"] = flutterBackend() ?: "?"
        return out
    }

    private fun vulkanLevel(): String {
        val pm = packageManager
        val feature = pm.systemAvailableFeatures.firstOrNull {
            it.name == PackageManager.FEATURE_VULKAN_HARDWARE_VERSION
        } ?: return "없음"
        val v = feature.version
        return "${v shr 22}.${(v shr 12) and 0x3ff}"
    }

    /// GL strings from a throwaway 1x1 pbuffer context. The default EGL
    /// display is shared with Flutter and Filament, so it is never
    /// terminated here.
    private fun glInfo(): Map<String, String> {
        val out = HashMap<String, String>()
        val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (display == EGL14.EGL_NO_DISPLAY) return out
        val version = IntArray(2)
        if (!EGL14.eglInitialize(display, version, 0, version, 1)) return out
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        val attribs = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_NONE
        )
        if (!EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, count, 0) ||
            count[0] == 0
        ) return out
        val context = EGL14.eglCreateContext(
            display, configs[0], EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0
        )
        if (context == EGL14.EGL_NO_CONTEXT) return out
        val surface = EGL14.eglCreatePbufferSurface(
            display, configs[0],
            intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0
        )
        try {
            if (surface != EGL14.EGL_NO_SURFACE &&
                EGL14.eglMakeCurrent(display, surface, surface, context)
            ) {
                out["glVendor"] = GLES20.glGetString(GLES20.GL_VENDOR) ?: "?"
                out["glRenderer"] = GLES20.glGetString(GLES20.GL_RENDERER) ?: "?"
                out["glVersion"] = GLES20.glGetString(GLES20.GL_VERSION) ?: "?"
                EGL14.eglMakeCurrent(
                    display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_CONTEXT
                )
            }
        } finally {
            if (surface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, surface)
            EGL14.eglDestroyContext(display, context)
        }
        return out
    }

    /// This process's own log lines (no permission needed for own pid).
    private fun ownLog(maxLines: Int): List<String> {
        val proc = ProcessBuilder(
            "logcat", "-d", "-v", "time", "-t", maxLines.toString(),
            "--pid=${Process.myPid()}"
        ).redirectErrorStream(true).start()
        val lines = proc.inputStream.bufferedReader().readLines()
        proc.waitFor()
        return lines
    }

    private fun flutterBackend(): String? {
        val line = ownLog(3000).lastOrNull { it.contains("Impeller rendering backend") }
            ?: return null
        val start = line.indexOf('(')
        val end = line.indexOf(')', start + 1)
        return if (start >= 0 && end > start) "Impeller ${line.substring(start + 1, end)}" else "Impeller"
    }

    private fun recentLog(): List<String> {
        val keys = listOf(
            "Impeller", "thermion", "Filament", "FilamentPlugin", "kovalink",
            "EGL", "GLES", "SurfaceProducer", "ImageReader", "SurfaceTexture",
            "E/flutter", "Exception", "Error"
        )
        return ownLog(1500)
            .filter { line -> keys.any { line.contains(it) } }
            .filterNot { it.contains("I/$TAG") }
            .takeLast(30)
    }

    companion object {
        const val TAG = "kovalink"
    }
}
