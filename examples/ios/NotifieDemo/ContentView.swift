import SwiftUI
import Notifie

struct ContentView: View {
    @ObservedObject var state: DemoState

    var body: some View {
        NavigationStack {
            Form {
                localNotificationsSection
                connectionSection
                if state.isInitialised {
                    eventsSection
                    userSection
                    notificationsSection
                }
                logSection
            }
            .navigationTitle("Notifie Demo")
        }
    }

    // MARK: - Local notifications

    /// Deliberately the first section, and outside the `isInitialised` check.
    ///
    /// Local notifications need no API key, no network and no account. Putting
    /// them above the connection form is the clearest way to show that.
    private var localNotificationsSection: some View {
        Section {
            Button("Remind me in 10 seconds") {
                state.scheduleInTenSeconds()
            }
            Button("Remind me daily at 09:00") {
                state.scheduleDailyReminder()
            }
            Button("Move daily reminder to 18:00") {
                state.rescheduleDailyReminder(hour: 18)
            }

            if state.pendingLocal.isEmpty {
                Text("Nothing scheduled")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.pendingLocal, id: \.self) { id in
                    HStack {
                        Text(id).font(.system(.footnote, design: .monospaced))
                        Spacer()
                        Button("Cancel") { state.cancelLocal(id: id) }
                            .font(.footnote)
                    }
                }
            }
        } header: {
            Text("Local notifications — no account needed")
        } footer: {
            Text(
                "These work with no API key and no network. Turn on airplane mode, "
                    + "schedule the 10-second reminder, then background the app."
            )
        }
        .task { await state.refreshPendingLocal() }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            TextField("gk_live_…", text: $state.apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.footnote, design: .monospaced))

            TextField("http://127.0.0.1:3000", text: $state.baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.system(.footnote, design: .monospaced))

            Button(state.isInitialised ? "Re-initialize" : "Initialize") {
                state.initializeNow()
            }
            .disabled(state.apiKey.isEmpty)

            if state.isInitialised {
                LabeledContent("Identified as", value: state.identifiedAs ?? "—")
                    .font(.footnote)
            }
        } header: {
            Text("Connection")
        } footer: {
            Text(
                state.isInitialised
                    ? "Connected. Events are flushed every 5 seconds."
                    : "Paste the API key from your app's settings page, then Initialize."
            )
        }
    }

    // MARK: - Events

    private var eventsSection: some View {
        Section {
            Button("purchase_completed") {
                state.track(
                    "purchase_completed",
                    properties: ["amount": .double(9.99), "plan": .string("monthly")]
                )
            }
            Button("onboarding_completed") { state.track("onboarding_completed") }
            Button("subscription_cancelled") {
                state.track("subscription_cancelled", properties: ["reason": .string("too_expensive")])
            }
            Button("achievement_unlocked") {
                state.track("achievement_unlocked", properties: ["level": .int(7)])
            }
            Button("Flush now") { state.flush() }
                .foregroundStyle(.secondary)
        } header: {
            Text("Track an event")
        } footer: {
            Text("These are the events the built-in templates key off, so firing them makes recommendations appear.")
        }
    }

    // MARK: - User

    private var userSection: some View {
        Section {
            Button("Set premium = true") { state.setPremium(true) }
            Button("Set premium = false") { state.setPremium(false) }
            Button("Reset SDK", role: .destructive) { state.reset() }
        } header: {
            Text("User properties")
        } footer: {
            Text("Property filters in the notification builder target these.")
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section {
            Button("Enable notifications") { state.enableNotifications() }

            if let enrolment = state.enrolment {
                LabeledContent("Result", value: enrolment).font(.footnote)
            }

            if let token = state.deviceToken {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Device token").font(.caption).foregroundStyle(.secondary)
                    Text(token)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Push")
        } footer: {
            Text(
                "A simulator can register and receive push, but only from a real "
                + "APNs key. Without one, delivery stops at the provider — the rest "
                + "of the pipeline still runs."
            )
        }
    }

    // MARK: - Log

    private var logSection: some View {
        Section("Activity") {
            if state.entries.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary).font(.footnote)
            } else {
                ForEach(state.entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.message).font(.footnote)
                        Text(entry.time, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
