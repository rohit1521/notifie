package dev.notifie.flutter;

import android.app.Activity;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import androidx.annotation.NonNull;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Routes local notification calls to the native Android SDK.
 *
 * The channel name is retained from before the rename: it is an internal bridge
 * detail, and changing it would break hosts that registered the plugin earlier.
 */
public final class NotifieFlutterPlugin
        implements FlutterPlugin,
                MethodChannel.MethodCallHandler,
                ActivityAware,
                PluginRegistry.NewIntentListener {
    private static final String CHANNEL = "notifie_flutter/notifications";
    private static final String TAG = "Notifie";
    private static final String CHANNEL_ID_META =
            "com.google.firebase.messaging.default_notification_channel_id";

    /**
     * Present on taps this SDK scheduled locally, absent on remote pushes.
     *
     * Android already delivers remote opens to Dart through
     * FirebaseMessaging.onMessageOpenedApp. Forwarding those a second time here
     * would report every remote tap twice, so this key is what keeps the two
     * paths disjoint.
     */
    private static final String LOCAL_ID_EXTRA = "notifie_local_id";

    /**
     * Set on an intent once its open has been taken.
     *
     * getIntent() keeps returning the same launch intent, so a configuration
     * change or a later re-attach would otherwise replay an old tap as a new
     * one.
     */
    private static final String CONSUMED_EXTRA = "notifie_local_open_consumed";

    private MethodChannel channel;
    private Context context;
    private ActivityPluginBinding activityBinding;

    /**
     * Opens that arrived before Dart was listening.
     *
     * A cold start from a notification tap delivers the intent long before the
     * Dart isolate registers its handler, which is exactly the case that must
     * not be dropped: it is the only signal of why the app was launched.
     */
    private final List<Map<String, Object>> bufferedOpens = new ArrayList<>();
    private boolean openHandlerReady;

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
        openHandlerReady = false;
        bufferedOpens.clear();
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activityBinding = binding;
        binding.addOnNewIntentListener(this);
        deliverOpen(binding.getActivity().getIntent());
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity();
    }

    @Override
    public void onDetachedFromActivity() {
        if (activityBinding != null) {
            activityBinding.removeOnNewIntentListener(this);
            activityBinding = null;
        }
    }

    @Override
    public boolean onNewIntent(@NonNull Intent intent) {
        deliverOpen(intent);
        // Never claims the intent: other plugins and the host activity must
        // still see a tap this one only observes.
        return false;
    }

    /**
     * Hands a locally scheduled notification's payload to Dart.
     *
     * The open activity copies the notification data into the launch intent, so
     * the extras carry the deep link and the caller's custom data verbatim.
     */
    private void deliverOpen(Intent intent) {
        if (intent == null) return;
        Bundle extras = intent.getExtras();
        if (extras == null) return;
        if (extras.getString(LOCAL_ID_EXTRA) == null) return;
        if (extras.getBoolean(CONSUMED_EXTRA, false)) return;
        intent.putExtra(CONSUMED_EXTRA, true);

        Map<String, Object> payload = new HashMap<>();
        for (String key : extras.keySet()) {
            if (CONSUMED_EXTRA.equals(key)) continue;
            Object value = extras.get(key);
            // Only the string data this SDK put there. An intent picks up
            // unrelated framework extras that would not survive the channel
            // codec and are not part of the notification.
            if (value instanceof String) payload.put(key, value);
        }
        if (payload.isEmpty()) return;

        if (!openHandlerReady || channel == null) {
            bufferedOpens.add(payload);
            return;
        }
        channel.invokeMethod("notificationOpened", payload);
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
            case "markOpenHandlerReady": {
                openHandlerReady = true;
                Map<String, Object> pending = new HashMap<>();
                pending.put("opens", new ArrayList<>(bufferedOpens));
                // No receipts on Android: a delivered notification is posted by
                // the system, and the SDK is not running to observe it.
                pending.put("receipts", new ArrayList<>());
                bufferedOpens.clear();
                result.success(pending);
                return;
            }
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
