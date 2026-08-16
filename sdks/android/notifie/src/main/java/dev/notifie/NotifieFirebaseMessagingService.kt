package dev.notifie

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/** Receives FCM token rotations and foreground messages without host boilerplate. */
public class NotifieFirebaseMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        Notifie.registerPushToken(this, token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        Notifie.handleRemoteMessage(this, message)
    }
}