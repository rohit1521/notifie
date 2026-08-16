package dev.notifie

import android.app.Notification
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import java.net.URL
import kotlin.math.absoluteValue

internal object NotifieNotifications {
    fun createDefaultChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(Notifie.defaultChannelId) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                Notifie.defaultChannelId,
                "Notifie notifications",
                NotificationManager.IMPORTANCE_DEFAULT,
            ),
        )
    }

    fun show(
        context: Context,
        title: String,
        body: String,
        imageUrl: String?,
        data: Map<String, String>,
    ) {
        if (title.isBlank() && body.isBlank()) return
        createDefaultChannel(context)
        val invocationId = data[Notifie.invocationIdKey] ?: System.nanoTime().toString()
        val openIntent = Intent(context, NotifieNotificationOpenActivity::class.java).apply {
            data.forEach { (key, value) -> putExtra(key, value) }
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            invocationId.hashCode(),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, Notifie.defaultChannelId)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(context)
        }
        builder
            .setSmallIcon(resolveSmallIcon(context))
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
        downloadImage(imageUrl)?.let { image ->
            builder.setStyle(
                Notification.BigPictureStyle().bigPicture(image).bigLargeIcon(null as Bitmap?),
            )
        }

        context.getSystemService(NotificationManager::class.java)
            .notify(invocationId.hashCode().absoluteValue, builder.build())
    }

    internal fun resolveSmallIcon(applicationInfo: ApplicationInfo): Int {
        val configured = applicationInfo.metaData
            ?.getInt("com.google.firebase.messaging.default_notification_icon", 0)
            ?: 0
        return configured.takeIf { it != 0 }
            ?: applicationInfo.icon.takeIf { it != 0 }
            ?: R.drawable.notifie_notification
    }

    @Suppress("DEPRECATION")
    private fun resolveSmallIcon(context: Context): Int {
        val applicationInfo = runCatching {
            context.packageManager.getApplicationInfo(
                context.packageName,
                PackageManager.GET_META_DATA,
            )
        }.getOrElse { context.applicationInfo }
        return resolveSmallIcon(applicationInfo)
    }

    private fun downloadImage(rawUrl: String?) = rawUrl?.let {
        runCatching {
            val connection = URL(it).openConnection().apply {
                connectTimeout = 5_000
                readTimeout = 5_000
            }
            connection.getInputStream().use(BitmapFactory::decodeStream)
        }.getOrNull()
    }
}

public class NotifieNotificationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val data = intent.extras?.keySet()?.associateWith {
            intent.extras?.getString(it).orEmpty()
        }.orEmpty()
        Notifie.recordNotificationOpen(context, data)
        launchNotificationDestination(context, data)
    }
}

public class NotifieNotificationOpenActivity : Activity() {
    override fun onCreate(state: android.os.Bundle?) {
        super.onCreate(state)
        val data = intent.extras?.keySet()?.associateWith {
            intent.extras?.getString(it).orEmpty()
        }.orEmpty()
        Notifie.recordNotificationOpen(this, data)
        launchNotificationDestination(this, data)
        finish()
    }
}

private fun launchNotificationDestination(context: Context, data: Map<String, String>) {
    val launchIntent = Notifie.deepLink(data)?.let {
        Intent(Intent.ACTION_VIEW, Uri.parse(it))
    } ?: context.packageManager.getLaunchIntentForPackage(context.packageName)
    launchIntent?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
    if (launchIntent != null) context.startActivity(launchIntent)
}