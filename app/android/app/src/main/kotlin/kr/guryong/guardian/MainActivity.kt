package kr.guryong.guardian

import android.content.Context
import android.content.Intent
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 대피 경보(재난문자처럼, 2026-10-11): 경보 알림으로 열리면 잠금 화면 위에 화면을 켜서 띄우고,
 * 앱(services/evac_alarm.dart)이 채널 guardian/alarm 으로 손전등 깜빡임·잠금 화면 표시 해제를 부른다.
 * 잠금 화면 위 표시는 경보 화면에서만 — 평소 앱 화면은 잠금 화면 위에 나오지 않는다.
 */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        if (isEvacAlarm(intent)) showOverLock(true)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        if (isEvacAlarm(intent)) showOverLock(true)
        super.onNewIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "guardian/alarm").setMethodCallHandler { call, result ->
            when (call.method) {
                "lockScreen" -> { showOverLock(call.arguments == true); result.success(null) }
                "torch" -> result.success(torch(call.arguments == true))
                else -> result.notImplemented()
            }
        }
    }

    /** flutter_local_notifications 가 알림(전체 화면 포함)으로 열 때 붙이는 action + 우리 payload 표시 */
    private fun isEvacAlarm(i: Intent?): Boolean =
        i?.action == "SELECT_NOTIFICATION" && (i.getStringExtra("payload")?.contains("\"evac_alarm\"") == true)

    private fun showOverLock(on: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (on) window.addFlags(flags) else window.clearFlags(flags)
        }
        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    /** 카메라 플래시 켜기/끄기 (권한 필요 없음). 플래시가 없거나 카메라를 다른 앱이 쓰면 false */
    private fun torch(on: Boolean): Boolean = try {
        val cm = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val id = cm.cameraIdList.firstOrNull {
            cm.getCameraCharacteristics(it).get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        }
        if (id == null) false else { cm.setTorchMode(id, on); true }
    } catch (e: Exception) {
        false
    }
}
