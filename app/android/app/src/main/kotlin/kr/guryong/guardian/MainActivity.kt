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
 *
 * 주의보·경보 등 일반 재난 알림(services/alert_notifications.dart, 같은 날): 꺼진 화면에서는 소리만 나고 화면이 안 켜졌다 →
 * 전체 화면 알림으로 열리면 화면만 잠깐 켜고 바로 잠금 화면 위 표시를 풀어, 잠금 화면에 알림 카드가 보이게 한다.
 */
class MainActivity : FlutterActivity() {
    /** 대피 경보가 잠금 화면 위에 떠 있는 중 — 일반 알림이 이 표시를 풀지 않게 */
    private var evacOverLock = false

    override fun onCreate(savedInstanceState: Bundle?) {
        handleIntent(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        handleIntent(intent)
        super.onNewIntent(intent)
    }

    private fun handleIntent(i: Intent?) {
        when {
            isNotification(i, "evac_alarm") -> { evacOverLock = true; showOverLock(true) }
            // 방재단 도착 안내(시각장애인 음성, 2026-10-12): 읽는 동안 잠금 화면 위에 — 다 읽으면 앱이 lockScreen(false)
            isNotification(i, "responder_eta") -> { evacOverLock = true; showOverLock(true) }
            isNotification(i, "alert_notice") -> wakeForNotice()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "guardian/alarm").setMethodCallHandler { call, result ->
            when (call.method) {
                "lockScreen" -> {
                    evacOverLock = call.arguments == true
                    showOverLock(evacOverLock)
                    result.success(null)
                }
                "torch" -> result.success(torch(call.arguments == true))
                else -> result.notImplemented()
            }
        }
    }

    /** flutter_local_notifications 가 알림(전체 화면 포함)으로 열 때 붙이는 action + 우리 payload 의 kind */
    private fun isNotification(i: Intent?, kind: String): Boolean =
        i?.action == "SELECT_NOTIFICATION" && (i.getStringExtra("payload")?.contains("\"$kind\"") == true)

    /** 화면을 켜고 잠시 뒤 잠금 화면 위 표시를 푼다 → 잠금 화면(알림 카드)이 다시 보인다. 잠금이 없는 기기는 앱이 열린 채 */
    private fun wakeForNotice() {
        if (evacOverLock) return
        showOverLock(true)
        window.decorView.postDelayed({ if (!evacOverLock) showOverLock(false) }, NOTICE_WAKE_MS)
    }

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

    private companion object {
        const val NOTICE_WAKE_MS = 1500L
    }
}
