package dev.notifie

import android.app.Notification
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import java.net.URL

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
        // Resolved by action, scoped to this package, rather than by class.
        //
        // Naming the class directly looked safer and was not: the Flutter
        // plugin removes this SDK's open activity so it can hand the deep link
        // to Dart, which left every locally scheduled notification in a Flutter
        // app pointing at a class the merged manifest no longer declares. The
        // tap then failed with START_CLASS_NOT_FOUND and did nothing at all —
        // no crash, no log, no open. Remote pushes were unaffected because
        // Cloud already sends this same action as `click_action`, so this makes
        // both paths resolve identically.
        //
        // setPackage keeps it internal, so the tap can never leave the app.
        val openIntent = Intent(Notifie.notificationOpenAction).apply {
            setPackage(context.packageName)
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
            // The same integer identifies the tap intent above, so a redelivery
            // of one invocation replaces its notification rather than stacking a
            // duplicate. Deliberately not `absoluteValue`: that is a no-op for
            // Int.MIN_VALUE, which stays negative and so never made the
            // guarantee it appeared to, while a negative id is perfectly legal.
            .notify(invocationId.hashCode(), builder.build())
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
    val deepLink = Notifie.deepLink(data)
    if (deepLink != null &&
        startDestination(context, Intent(Intent.ACTION_VIEW, Uri.parse(deepLink)), data)
    ) {
        return
    }
    // A deep link the host app does not declare must never crash it, and must not
    // silently lose the tap either. Fall back to opening the app itself.
    startDestination(
        context,
        context.packageManager.getLaunchIntentForPackage(context.packageName),
        data,
    )
}

private fun startDestination(
    context: Context,
    intent: Intent?,
    data: Map<String, String>,
): Boolean {
    if (intent == null) return false
    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)

    // The notification payload travels to the destination as extras, which is what
    // makes Notifie.deepLink(...) and Notifie.notificationOpened(...) usable from a
    // host activity: without it the app is started with a bare intent and cannot
    // tell which notification produced it.
    //
    // Only when the destination is this app. An https deep link legitimately
    // resolves to a browser, and custom data is the host's own payload -- it must
    // not be handed to whichever third-party app happens to claim the scheme.
    if (resolvesToThisApp(context, intent)) {
        data.forEach { (key, value) -> intent.putExtra(key, value) }
    }

    return try {
        context.startActivity(intent)
        true
    } catch (error: ActivityNotFoundException) {
        false
    } catch (error: SecurityException) {
        false
    }
}

private fun resolvesToThisApp(context: Context, intent: Intent): Boolean {
    val resolved = context.packageManager.resolveActivity(intent, 0) ?: return false
    return resolved.activityInfo?.packageName == context.packageName
}