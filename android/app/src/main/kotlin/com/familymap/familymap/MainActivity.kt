package com.familymap.familymap

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        tryStartKeepAlive()
    }

    override fun onResume() {
        super.onResume()
        tryStartKeepAlive()
    }

    private fun tryStartKeepAlive() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)
            == PackageManager.PERMISSION_GRANTED
        ) {
            try { KeepAliveService.start(this) } catch (_: Exception) {}
        }
    }
}
