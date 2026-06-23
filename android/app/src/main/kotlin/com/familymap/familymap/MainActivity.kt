package com.familymap.familymap

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 启动时设定时保活
        BootReceiver.scheduleNext(this)
    }

    override fun onResume() {
        super.onResume()
        // 每次回到前台都刷新定时器
        BootReceiver.scheduleNext(this)
    }
}
