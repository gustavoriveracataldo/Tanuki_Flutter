package com.toonami.tanuki

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.view.WindowManager

class PlaybackPowerKeeper(private val activity: Activity) {
    private val handler = Handler(Looper.getMainLooper())
    private var enabled = false
    private var wakeLock: PowerManager.WakeLock? = null

    private val pulseRunnable = object : Runnable {
        override fun run() {
            if (!enabled || activity.isFinishing || activity.isDestroyed) {
                return
            }
            applyKeepScreenOn()
            acquireWakeLockPulse()
            handler.postDelayed(this, PULSE_INTERVAL_MS)
        }
    }

    fun setEnabled(value: Boolean) {
        if (enabled == value) {
            if (value) {
                applyKeepScreenOn()
                acquireWakeLockPulse()
            }
            return
        }
        enabled = value
        handler.removeCallbacks(pulseRunnable)
        if (value) {
            applyKeepScreenOn()
            acquireWakeLockPulse()
            handler.postDelayed(pulseRunnable, PULSE_INTERVAL_MS)
        } else {
            clearKeepScreenOn()
            releaseWakeLock()
        }
    }

    fun onResume() {
        if (enabled) {
            applyKeepScreenOn()
            acquireWakeLockPulse()
            handler.removeCallbacks(pulseRunnable)
            handler.postDelayed(pulseRunnable, PULSE_INTERVAL_MS)
        }
    }

    fun dispose() {
        enabled = false
        handler.removeCallbacks(pulseRunnable)
        clearKeepScreenOn()
        releaseWakeLock()
    }

    private fun applyKeepScreenOn() {
        activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        activity.window.decorView.keepScreenOn = true
    }

    private fun clearKeepScreenOn() {
        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        activity.window.decorView.keepScreenOn = false
    }

    @Suppress("DEPRECATION")
    private fun acquireWakeLockPulse() {
        val lock = wakeLock ?: run {
            val powerManager =
                activity.getSystemService(Context.POWER_SERVICE) as PowerManager
            powerManager.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ON_AFTER_RELEASE,
                "Tanuki:PlaybackPowerKeeper",
            ).apply {
                setReferenceCounted(false)
                wakeLock = this
            }
        }
        runCatching {
            lock.acquire(WAKE_LOCK_PULSE_MS)
        }
    }

    private fun releaseWakeLock() {
        val lock = wakeLock ?: return
        runCatching {
            if (lock.isHeld) {
                lock.release()
            }
        }
        wakeLock = null
    }

    private companion object {
        const val PULSE_INTERVAL_MS = 25_000L
        const val WAKE_LOCK_PULSE_MS = 35_000L
    }
}
