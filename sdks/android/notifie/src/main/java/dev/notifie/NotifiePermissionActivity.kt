package dev.notifie

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle

/** Owns the Android 13 permission callback so host activities need no boilerplate. */
public class NotifiePermissionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) {
            Notifie.onNotificationPermissionResult(true)
            finish()
            return
        }
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), requestCode)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != Companion.requestCode) return
        Notifie.onNotificationPermissionResult(
            grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED,
        )
        finish()
    }

    private companion object {
        const val requestCode = 9401
    }
}