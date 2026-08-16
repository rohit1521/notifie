# Notifie iOS demo

A small SwiftUI app that exercises the real Swift SDK from this repository
against a locally running Notifie.

It exists to answer one question honestly: **does an event emitted by a real
iOS app end up triggering a real notification?**

## What this proves, and what it cannot

| Step | Simulator | Real device |
|---|---|---|
| SDK initialises, identifies, tracks | yes | yes |
| Lifecycle events collected automatically | yes | yes |
| Events reach the dashboard over HTTP | yes | yes |
| Automation triggers and resolves an audience | yes | yes |
| Notification permission prompt | yes | yes |
| A **real APNs device token** | no | yes |
| Delivery from Apple to the device | no | needs an APNs key |

A simulator can show the permission prompt but never receives a real push.
Everything up to the network call to Apple is identical either way.

## Running it on a simulator

No Apple account required.

```bash
cd examples/ios
./generate.sh
xcodebuild -project NotifieDemo.xcodeproj -scheme NotifieDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build build

xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/NotifieDemo.app
xcrun simctl launch booted dev.notifie.demo
```

Paste an API key into the first field and tap **Initialize**. Events appear in
the dashboard within a few seconds.

## Running it on a real device

Events work on a device without any push setup. Push needs one extra step.

```bash
cd examples/ios
GK_TEAM_ID=YOURTEAMID GK_BUNDLE_ID=com.yourname.notifiedemo ./generate.sh
xcodebuild -project NotifieDemo.xcodeproj -scheme NotifieDemo \
  -destination 'platform=iOS,id=<device-udid>' \
  -derivedDataPath build-device -allowProvisioningUpdates build

xcrun devicectl device install app --device <device-udid> \
  build-device/Build/Products/Debug-iphoneos/NotifieDemo.app
```

Find the device id with `xcrun devicectl list devices`.

### Point the app at your machine, not the phone

`127.0.0.1` on a phone means *the phone*. Pass your Mac's LAN address, or the
app will look like it is doing nothing:

```bash
ipconfig getifaddr en0     # e.g. 192.168.1.14

xcrun devicectl device process launch --device <device-udid> \
  --terminate-existing com.yourname.notifiedemo -- \
  -notifie.demo.apiKey "gk_live_…" \
  -notifie.demo.baseURL "http://192.168.1.14:3000" \
  -notifie.demo.trackOnLaunch "purchase_completed"
```

The phone and the Mac must be on the same network.

### Turning on push

The push entitlement is **off by default**, because asking for
`aps-environment` makes the build fail outright unless the provisioning profile
already carries the Push Notifications capability:

```
Provisioning profile "iOS Team Provisioning Profile: *"
doesn't include the aps-environment entitlement.
```

To enable it:

1. Sign in to **Xcode → Settings → Accounts** — this is what lets Xcode create
   an App ID with the capability. Without an account you get
   `error: No Accounts: Add a new account in Accounts settings.`
2. Rebuild with `GK_PUSH=1`:

   ```bash
   GK_PUSH=1 GK_TEAM_ID=YOURTEAMID GK_BUNDLE_ID=com.yourname.notifiedemo ./generate.sh
   ```

3. Upload your APNs `.p8` under **Settings → Push** in the dashboard. It is
   checked against Apple on upload, and the environment it is scoped to is
   detected for you.

A debug build installed from Xcode registers a **Sandbox** token; TestFlight and
the App Store use **Production**. A key scoped to one is rejected by the other,
which is why the dashboard tells you which one yours is.

## Driving it from a script

Launch arguments configure and drive the app without any typing:

```bash
xcrun simctl launch booted dev.notifie.demo \
  -notifie.demo.apiKey "gk_live_…" \
  -notifie.demo.trackOnLaunch "purchase_completed,onboarding_completed" \
  -notifie.demo.enableNotificationsOnLaunch YES
```

These run through the same methods the buttons call, so a scripted run cannot
drift from what a person tapping would do.

There is also a URL scheme, useful while the app is already open:

```bash
xcrun simctl openurl booted "notifiedemo://track?event=purchase_completed&amount=9.99"
```

iOS 17 shows an "Open in…?" confirmation for these, which is fine by hand but
cannot be dismissed by a script — hence the launch arguments above.

## The automated check

```bash
node --experimental-strip-types scripts/ios-e2e.mjs <api-key>
```

Launches the app on a booted simulator, waits for its event to arrive over real
HTTP, and drives the resulting automation through the runtime to a delivery
attempt. It fails loudly if the app does not launch, rather than passing on an
event left behind by an earlier run.

## The integration code you have to write

Two APNs callbacks, forwarded in
[NotifieDemoApp.swift](NotifieDemo/NotifieDemoApp.swift):

```swift
func application(_ app: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
    PushTokenBridge.shared.didRegister(deviceToken: token)
}

func application(_ app: UIApplication,
                 didFailToRegisterForRemoteNotificationsWithError error: Error) {
    PushTokenBridge.shared.didFail(error: error)
}
```

That is the whole integration. Token upload, refresh, batching, retries,
offline queueing and session events are the SDK's problem, not yours.
