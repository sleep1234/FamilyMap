package com.familymap.familymap

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        KeepAliveService.start(this)
    }

    override fun onResume() {
        super.onResume()
        KeepAliveService.start(this)
    }
}
