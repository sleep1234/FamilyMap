package com.familymap.familymap

import android.os.Bundle
import androidx.work.*
import io.flutter.embedding.android.FlutterActivity
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        scheduleKeepAlive()
    }

    override fun onResume() {
        super.onResume()
        scheduleKeepAlive()
    }

    private fun scheduleKeepAlive() {
        val request = PeriodicWorkRequestBuilder<KeepAliveWorker>(
            15, TimeUnit.MINUTES
        ).setConstraints(
            Constraints.Builder()
                .setRequiresBatteryNotLow(false)
                .build()
        ).build()

        WorkManager.getInstance(this).enqueueUniquePeriodicWork(
            "familymap_keep_alive",
            ExistingPeriodicWorkPolicy.UPDATE,
            request
        )
    }
}
