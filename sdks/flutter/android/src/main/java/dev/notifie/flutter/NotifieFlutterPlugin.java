package dev.notifie.flutter;

import android.content.Context;
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

    private MethodChannel channel;
    private Context context;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
        channel.setMethodCallHandler(this);
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
