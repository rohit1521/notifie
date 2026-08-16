package dev.notifie.flutter;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;

public class NotifieNotificationOpenActivity extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);

        Intent launchIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (launchIntent != null) {
            Bundle extras = getIntent().getExtras();
            if (extras != null) {
                launchIntent.putExtras(extras);
            }
            launchIntent.addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK
                    | Intent.FLAG_ACTIVITY_CLEAR_TOP
                    | Intent.FLAG_ACTIVITY_SINGLE_TOP
            );
            startActivity(launchIntent);
        }
        finish();
    }
}
