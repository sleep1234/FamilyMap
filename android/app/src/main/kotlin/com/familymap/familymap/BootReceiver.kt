package com.familymap.familymap

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON" -> {
                launchApp(context)
            }
            "com.familymap.familymap.KEEP_ALIVE" -> {
                launchApp(context)
            }
        }
        // 每次收到广播都重设定时器，确保持续保活
        scheduleNext(context)
    }

    private fun launchApp(context: Context) {
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        launchIntent?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        context.startActivity(launchIntent)
    }

    companion object {
        private const val ALARM_INTERVAL = 5 * 60 * 1000L // 5分钟

        fun scheduleNext(context: Context) {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(context, BootReceiver::class.java).apply {
                action = "com.familymap.familymap.KEEP_ALIVE"
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context, 9527, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                SystemClock.elapsedRealtime() + ALARM_INTERVAL,
                pendingIntent
            )
        }
    }
}
