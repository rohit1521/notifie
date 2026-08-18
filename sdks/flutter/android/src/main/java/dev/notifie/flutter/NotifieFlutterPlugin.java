package dev.notifie.flutter;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import androidx.annotation.NonNull;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.util.Map;

/**
 * Routes local notification calls to the native Android SDK.
 *
 * The channel name is retained from before the rename: it is an internal bridge
 * detail, and changing it would break hosts that registered the plugin earlier.
 */
public final class NotifieFlutterPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private static final String CHANNEL = "notifie_flutter/notifications";
    private static final String TAG = "Notifie";
    private static final String CHANNEL_ID_META =
            "com.google.firebase.messaging.default_notification_channel_id";

    private MethodChannel channel;
    private Context context;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
        channel.setMethodCallHandler(this);
        ensureDefaultChannel(context);
    }

    /**
     * Creates the notification channel that delivered pushes name.
     *
     * The native SDK creates this during its own initialize(), which a Flutter
     * host never calls -- that would start a second event pipeline alongside
     * the Dart one. So on Flutter the channel did not exist, Android logged
     * "Notification Channel requested (notifie_default) has not been created",
     * and every push fell back to Firebase's generic "Miscellaneous" channel,
     * where the developer cannot control importance and the user sees a channel
     * name that has nothing to do with the app.
     *
     * The id is read from the manifest entry the SDK already declares rather
     * than repeated here, so the two cannot drift apart.
     */
    private static void ensureDefaultChannel(Context context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        try {
            ApplicationInfo info = context.getPackageManager().getApplicationInfo(
                    context.getPackageName(), PackageManager.GET_META_DATA);
            Bundle metaData = info.metaData;
            if (metaData == null) return;
            String channelId = metaData.getString(CHANNEL_ID_META);
            if (channelId == null || channelId.trim().isEmpty()) return;

            NotificationManager manager = context.getSystemService(NotificationManager.class);
            if (manager == null || manager.getNotificationChannel(channelId) != null) return;
            manager.createNotificationChannel(new NotificationChannel(
                    channelId, "Notifie notifications", NotificationManager.IMPORTANCE_DEFAULT));
        } catch (Exception error) {
            // A missing channel degrades presentation; it must never stop the
            // plugin attaching and taking away events and local notifications.
            Log.w(TAG, "could not create the default notification channel", error);
        }
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (channel != null) {
            channel.setMethodCallHandler(null);
            channel = null;
        }
        context = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        if (context == null) {
            result.error("platform_error", "plugin is not attached to an engine", null);
            return;
        }

        switch (call.method) {
            case "scheduleLocalNotification": {
                Map<?, ?> arguments = call.arguments();
                if (arguments == null) {
                    result.error("invalid_request", "arguments are required", null);
                    return;
                }
                result.success(LocalNotificationBridge.INSTANCE.schedule(context, arguments));
                return;
            }
            case "cancelLocalNotification": {
                Map<?, ?> arguments = call.arguments();
                if (arguments != null) {
                    LocalNotificationBridge.INSTANCE.cancel(context, arguments);
                }
                result.success(null);
                return;
            }
            case "pendingLocalNotifications":
                result.success(LocalNotificationBridge.INSTANCE.pending(context));
                return;
            case "localNotificationCapabilities":
                result.success(LocalNotificationBridge.INSTANCE.capabilities(context));
                return;
            case "requestNotificationPermission":
                // Android grants notification permission through a runtime
                // request owned by the host activity, not by a background
                // plugin call. Reporting the current state keeps the Dart API
                // honest rather than pretending a prompt was shown.
                result.success(LocalNotificationBridge.INSTANCE.permissionState(context));
                return;
            default:
                result.notImplemented();
        }
    }
}
