import React, { useRef, useState } from 'react';
import {
  ActivityIndicator,
  Pressable,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import {
  Notifie,
  type NotifieNotification,
  type NotifieProperties,
} from '@notifie/react-native';

export interface DemoSdk {
  initialize(options: {
    apiKey: string;
    baseUrl: string;
    onNotificationReceived(notification: NotifieNotification): void;
    onNotificationOpened(notification: NotifieNotification): void;
  }): Promise<void>;
  identify(userId: string, properties?: NotifieProperties): Promise<void>;
  track(eventName: string, properties?: NotifieProperties): Promise<void>;
  enableNotifications(): Promise<void>;
  flush(): Promise<void>;
  reset(): Promise<void>;
}

export const productionSdk: DemoSdk = {
  async initialize(options) {
    await Notifie.initialize(options);
  },
  async identify(userId, properties) {
    await Notifie.identify(userId, properties);
  },
  async track(eventName, properties) {
    await Notifie.track(eventName, properties);
  },
  async enableNotifications() {
    await Notifie.enableNotifications();
  },
  async flush() {
    await Notifie.flush();
  },
  async reset() {
    await Notifie.reset();
  },
};

export default function App({ sdk = productionSdk }: { sdk?: DemoSdk }) {
  return (
    <SafeAreaProvider>
      <StatusBar barStyle="dark-content" backgroundColor="#ffffff" />
      <SafeAreaView style={styles.safeArea} edges={['top', 'bottom']}>
        <Harness sdk={sdk} />
      </SafeAreaView>
    </SafeAreaProvider>
  );
}

export function Harness({ sdk }: { sdk: DemoSdk }) {
  const [apiKey, setApiKey] = useState('');
  const [baseUrl, setBaseUrl] = useState('http://127.0.0.1:3000');
  const [userId, setUserId] = useState('react-native-example-user');
  const [eventName, setEventName] = useState('post_liked');
  const [status, setStatus] = useState('Not initialized');
  const [notification, setNotification] = useState('No notification received');
  const [initialized, setInitialized] = useState(false);
  const [busy, setBusy] = useState(false);
  const busyRef = useRef(false);

  async function run(success: string, operation: () => Promise<void>) {
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    try {
      await operation();
      setStatus(success);
    } catch (error) {
      setStatus(error instanceof Error ? error.message : String(error));
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  }

  function recordNotification(state: string, value: NotifieNotification) {
    setNotification(
      [state, value.title, value.deepLink, value.invocationId]
        .filter((item): item is string => Boolean(item))
        .join(' · '),
    );
  }

  return (
    <View style={styles.screen}>
      <View style={styles.header}>
        <Text style={styles.title}>Notifie React Native</Text>
        <Text style={styles.subtitle}>iOS and Android integration harness</Text>
      </View>
      <ScrollView
        contentContainerStyle={styles.content}
        keyboardShouldPersistTaps="handled"
      >
        <View style={styles.statusCard}>
          <View
            style={[
              styles.statusDot,
              initialized ? styles.statusDotReady : styles.statusDotIdle,
            ]}
          />
          <View style={styles.statusCopy}>
            <Text testID="status" style={styles.statusTitle}>
              {busy ? 'Working…' : status}
            </Text>
            <Text style={styles.statusMeta}>{baseUrl}</Text>
          </View>
          {busy ? <ActivityIndicator /> : null}
        </View>

        <Section title="Connection">
          <Field
            testID="api-key"
            label="SDK ingest key"
            value={apiKey}
            onChangeText={setApiKey}
            secureTextEntry
            placeholder="gk_test_…"
          />
          <Field
            testID="base-url"
            label="Notifie base URL"
            value={baseUrl}
            onChangeText={setBaseUrl}
            autoCapitalize="none"
          />
          <ActionButton
            testID="initialize"
            label="Initialize SDK"
            primary
            disabled={busy}
            onPress={() =>
              run('SDK initialized', async () => {
                await sdk.initialize({
                  apiKey,
                  baseUrl,
                  onNotificationReceived: value =>
                    recordNotification('Received', value),
                  onNotificationOpened: value =>
                    recordNotification('Opened', value),
                });
                setInitialized(true);
              })
            }
          />
        </Section>

        <Section title="Identity">
          <Field
            testID="user-id"
            label="External user ID"
            value={userId}
            onChangeText={setUserId}
            autoCapitalize="none"
          />
          <ActionButton
            testID="identify"
            label="Identify user"
            disabled={!initialized || busy}
            onPress={() =>
              run('User identified', () =>
                sdk.identify(userId.trim(), {
                  sdk: 'react-native',
                  example: true,
                }),
              )
            }
          />
        </Section>

        <Section title="Event pipeline">
          <Field
            testID="event-name"
            label="Event name"
            value={eventName}
            onChangeText={setEventName}
            autoCapitalize="none"
          />
          <ActionButton
            testID="track"
            label="Track event"
            disabled={!initialized || busy}
            onPress={() =>
              run('Event queued', () =>
                sdk.track(eventName.trim(), { source: 'react_native_example' }),
              )
            }
          />
          <ActionButton
            testID="flush"
            label="Flush queue"
            disabled={!initialized || busy}
            onPress={() => run('Queue flushed', () => sdk.flush())}
          />
        </Section>

        <Section title="Push notifications">
          <ActionButton
            testID="notifications"
            label="Enable notifications"
            disabled={!initialized || busy}
            onPress={() =>
              run(
                'Notification permission and token registered',
                () => sdk.enableNotifications(),
              )
            }
          />
          <Text testID="last-notification" style={styles.notificationText}>
            {notification}
          </Text>
        </Section>

        <Pressable
          testID="reset"
          accessibilityRole="button"
          accessibilityLabel="Reset SDK identity"
          disabled={!initialized || busy}
          onPress={() => run('Identity and token reset', () => sdk.reset())}
          style={({ pressed }) => [
            styles.resetButton,
            (!initialized || busy) && styles.disabled,
            pressed && styles.pressed,
          ]}
        >
          <Text style={styles.resetLabel}>Reset SDK identity</Text>
        </Pressable>
      </ScrollView>
    </View>
  );
}

function Section({ title, children }: React.PropsWithChildren<{ title: string }>) {
  return (
    <View style={styles.section}>
      <Text style={styles.sectionTitle}>{title}</Text>
      <View style={styles.sectionContent}>{children}</View>
    </View>
  );
}

function Field({
  label,
  ...props
}: React.ComponentProps<typeof TextInput> & { label: string }) {
  return (
    <View style={styles.field}>
      <Text style={styles.label}>{label}</Text>
      <TextInput
        {...props}
        style={styles.input}
        placeholderTextColor="#8A94A3"
      />
    </View>
  );
}

function ActionButton({
  label,
  primary = false,
  disabled,
  onPress,
  testID,
}: {
  label: string;
  primary?: boolean;
  disabled?: boolean;
  onPress(): void;
  testID: string;
}) {
  return (
    <Pressable
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={label}
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => [
        styles.action,
        primary ? styles.actionPrimary : styles.actionSecondary,
        disabled && styles.disabled,
        pressed && styles.pressed,
      ]}
    >
      <Text style={primary ? styles.actionPrimaryLabel : styles.actionLabel}>
        {label}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  safeArea: { flex: 1, backgroundColor: '#FFFFFF' },
  screen: { flex: 1, backgroundColor: '#F5F7FA' },
  header: {
    backgroundColor: '#FFFFFF',
    borderBottomColor: '#DCE2EA',
    borderBottomWidth: StyleSheet.hairlineWidth,
    paddingHorizontal: 20,
    paddingVertical: 14,
  },
  title: { color: '#172033', fontSize: 20, fontWeight: '700' },
  subtitle: { color: '#687386', fontSize: 13, marginTop: 2 },
  content: { gap: 12, padding: 16, paddingBottom: 32 },
  statusCard: {
    alignItems: 'center',
    backgroundColor: '#FFFFFF',
    borderColor: '#DCE2EA',
    borderRadius: 8,
    borderWidth: 1,
    flexDirection: 'row',
    padding: 14,
  },
  statusDot: { borderRadius: 5, height: 10, marginRight: 10, width: 10 },
  statusDotReady: { backgroundColor: '#16835D' },
  statusDotIdle: { backgroundColor: '#94A0B1' },
  statusCopy: { flex: 1 },
  statusTitle: { color: '#172033', fontSize: 14, fontWeight: '600' },
  statusMeta: { color: '#687386', fontSize: 12, marginTop: 2 },
  section: {
    backgroundColor: '#FFFFFF',
    borderColor: '#DCE2EA',
    borderRadius: 8,
    borderWidth: 1,
    padding: 16,
  },
  sectionTitle: { color: '#172033', fontSize: 16, fontWeight: '700' },
  sectionContent: { gap: 10, marginTop: 12 },
  field: { gap: 5 },
  label: { color: '#4F5B6E', fontSize: 12, fontWeight: '600' },
  input: {
    backgroundColor: '#FFFFFF',
    borderColor: '#C9D1DC',
    borderRadius: 6,
    borderWidth: 1,
    color: '#172033',
    fontSize: 14,
    minHeight: 44,
    paddingHorizontal: 12,
  },
  action: {
    alignItems: 'center',
    borderRadius: 6,
    justifyContent: 'center',
    minHeight: 44,
    paddingHorizontal: 14,
  },
  actionPrimary: { backgroundColor: '#2563EB' },
  actionSecondary: {
    backgroundColor: '#FFFFFF',
    borderColor: '#C9D1DC',
    borderWidth: 1,
  },
  actionPrimaryLabel: { color: '#FFFFFF', fontSize: 14, fontWeight: '700' },
  actionLabel: { color: '#1F4EB7', fontSize: 14, fontWeight: '700' },
  notificationText: { color: '#687386', fontSize: 12, lineHeight: 18 },
  resetButton: { alignItems: 'center', minHeight: 44, justifyContent: 'center' },
  resetLabel: { color: '#B42318', fontSize: 14, fontWeight: '600' },
  disabled: { opacity: 0.45 },
  pressed: { opacity: 0.72 },
});
