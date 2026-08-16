import AsyncStorage from '@react-native-async-storage/async-storage';
import messaging, {
  AuthorizationStatus,
  type FirebaseMessagingTypes,
} from '@react-native-firebase/messaging';
import {
  AppState,
  PermissionsAndroid,
  Platform,
} from 'react-native';
import {
  createUuid,
  NotifieClient,
  notificationFromData,
  type NotifieNotification,
  type NotifieProperties,
  type NotifieProperty,
  type PushRegistration,
  type PushTokenProvider,
} from './client.ts';

export type {
  NotifieNotification,
  NotifieProperties,
  NotifieProperty,
  PushRegistration,
} from './client.ts';

const anonymousIdKey = 'notifie.anonymous_id';
const installedKey = 'notifie.installed';
const pendingBackgroundNotificationPrefix =
  'notifie.pending_background_notification.';
let client: NotifieClient | null = null;
let appStateSubscription: { remove(): void } | null = null;
let appWasBackgrounded = false;
let initializationChain: Promise<void> = Promise.resolve();
let backgroundPersistence: Promise<void> = Promise.resolve();
let backgroundReplay: Promise<void> = Promise.resolve();
let backgroundNotificationHandler:
  | ((notification: NotifieNotification) => Promise<void> | void)
  | undefined;

function registerBackgroundMessageHandler(): void {
  let firebaseMessaging: ReturnType<typeof messaging>;
  try {
    firebaseMessaging = messaging();
  } catch {
    return;
  }

  firebaseMessaging.setBackgroundMessageHandler(async message => {
    const notification = notificationFromMessage(message);
    const persistence = backgroundPersistence
      .catch(() => undefined)
      .then(() => persistBackgroundNotification(notification, message.messageId));
    backgroundPersistence = persistence.catch(() => undefined);
    try {
      await persistence;
    } catch {
      console.warn('[Notifie] Could not persist a background notification.');
    }
    try {
      await backgroundNotificationHandler?.(notification);
    } catch {
      console.warn('[Notifie] Background notification callback failed.');
    }
  });
}

function requireFirebaseMessaging(): ReturnType<typeof messaging> {
  try {
    return messaging();
  } catch {
    throw new Error(
      'Firebase Messaging is not configured. Add your Firebase app configuration before enabling notifications.',
    );
  }
}

registerBackgroundMessageHandler();

export interface NotifieInitializeOptions {
  apiKey: string;
  baseUrl?: string;
  batchSize?: number;
  maxQueueSize?: number;
  flushIntervalMs?: number;
  requestTimeoutMs?: number;
  onNotificationReceived?: (notification: NotifieNotification) => void;
  onNotificationOpened?: (notification: NotifieNotification) => void;
  onError?: (error: unknown) => void;
}

export const Notifie = {
  initialize(options: NotifieInitializeOptions): Promise<void> {
    const operation = initializationChain
      .catch(() => undefined)
      .then(() => initializeNotifie(options));
    initializationChain = operation;
    return operation;
  },

  identify(userId: string, properties: NotifieProperties = {}): Promise<void> {
    return requireClient().identify(userId, properties);
  },

  enableNotifications(): Promise<void> {
    return requireClient().enableNotifications();
  },

  registerPushToken(registration: PushRegistration): Promise<void> {
    return requireClient().registerPushToken(registration);
  },

  track(eventName: string, properties: NotifieProperties = {}): Promise<void> {
    return requireClient().track(eventName, properties);
  },

  flush(): Promise<void> {
    return requireClient().flush();
  },

  reset(): Promise<void> {
    return requireClient().reset();
  },

  setBackgroundMessageHandler(
    handler: (notification: NotifieNotification) => Promise<void> | void,
  ): void {
    backgroundNotificationHandler = handler;
  },
};

async function initializeNotifie({
    apiKey,
    baseUrl = 'https://notifie.dev',
    batchSize = 20,
    maxQueueSize = 1000,
    flushIntervalMs = 30_000,
    requestTimeoutMs = 15_000,
    onNotificationReceived,
    onNotificationOpened,
    onError,
  }: NotifieInitializeOptions): Promise<void> {
    if (!apiKey.trim()) throw new Error('API key cannot be empty.');

    await disposeCurrentClient();
    const anonymousId = await loadAnonymousId();
    const nextClient = new NotifieClient(
      apiKey,
      baseUrl,
      anonymousId,
      firebasePushTokenProvider,
      fetch,
      {
        storage: AsyncStorage,
        batchSize,
        maxQueueSize,
        flushIntervalMs,
        requestTimeoutMs,
        onNotificationReceived,
        onNotificationOpened,
        onError,
      },
    );
    client = nextClient;
    await nextClient.start();
    await replayPendingBackgroundNotifications(nextClient);
    registerLifecycleListener();
    if (AppState.currentState === 'active') {
      await trackForegroundLifecycle(nextClient);
    }
}

const firebasePushTokenProvider: PushTokenProvider = {
  async enableNotifications() {
    if (Platform.OS !== 'ios' && Platform.OS !== 'android') return null;

    if (Platform.OS === 'android' && Number(Platform.Version) >= 33) {
      const permission = PermissionsAndroid.PERMISSIONS.POST_NOTIFICATIONS;
      if (!permission) {
        throw new Error('POST_NOTIFICATIONS is unavailable in this React Native build.');
      }
      const granted = await PermissionsAndroid.request(
        permission,
      );
      if (granted !== PermissionsAndroid.RESULTS.GRANTED) return null;
    }

    const firebaseMessaging = requireFirebaseMessaging();
    if (Platform.OS === 'ios') {
      await firebaseMessaging.registerDeviceForRemoteMessages();
    }
    const status = await firebaseMessaging.requestPermission();
    const authorized =
      status === AuthorizationStatus.AUTHORIZED ||
      status === AuthorizationStatus.PROVISIONAL;
    if (!authorized) return null;

    const token = await firebaseMessaging.getToken();
    if (!token) return null;
    return { token, platform: Platform.OS, provider: 'fcm' };
  },

  subscribeToTokenRefresh(listener) {
    return requireFirebaseMessaging().onTokenRefresh((token) => {
      if (Platform.OS === 'ios' || Platform.OS === 'android') {
        listener({ token, platform: Platform.OS, provider: 'fcm' });
      }
    });
  },

  subscribeToForegroundNotifications(listener) {
    return requireFirebaseMessaging().onMessage((message) => {
      listener(notificationFromMessage(message));
    });
  },

  subscribeToOpenedNotifications(listener) {
    return requireFirebaseMessaging().onNotificationOpenedApp((message) => {
      listener(notificationFromMessage(message));
    });
  },

  async getInitialNotification() {
    const message = await requireFirebaseMessaging().getInitialNotification();
    return message ? notificationFromMessage(message) : null;
  },
};

function notificationFromMessage(
  message: FirebaseMessagingTypes.RemoteMessage,
): NotifieNotification {
  const data = Object.fromEntries(
    Object.entries(message.data ?? {}).map(([key, value]) => [
      key,
      typeof value === 'string' ? value : JSON.stringify(value),
    ]),
  );
  return notificationFromData(
    data,
    message.notification?.title,
    message.notification?.body,
  );
}

async function persistBackgroundNotification(
  notification: NotifieNotification,
  messageId?: string,
): Promise<void> {
  await AsyncStorage.setItem(
    `${pendingBackgroundNotificationPrefix}${messageId ?? createUuid()}`,
    JSON.stringify(notification),
  );
}

async function awaitBackgroundPersistence(): Promise<void> {
  while (true) {
    const current = backgroundPersistence;
    await current;
    if (current === backgroundPersistence) return;
  }
}

async function pendingBackgroundNotifications(): Promise<
  Array<{ key: string; notification: NotifieNotification | null }>
> {
  const keys = (await AsyncStorage.getAllKeys())
    .filter(key => key.startsWith(pendingBackgroundNotificationPrefix))
    .sort();
  const pending: Array<{
    key: string;
    notification: NotifieNotification | null;
  }> = [];
  for (const key of keys) {
    const notification = parsePendingNotification(await AsyncStorage.getItem(key));
    pending.push({ key, notification });
  }
  return pending;
}

function parsePendingNotification(raw: string | null): NotifieNotification | null {
  if (!raw) return null;
  try {
    const value: unknown = JSON.parse(raw);
    if (!value || typeof value !== 'object') return null;
    const data = (value as { data?: unknown }).data;
    return data && typeof data === 'object' && !Array.isArray(data)
      ? (value as NotifieNotification)
      : null;
  } catch {
    return null;
  }
}

function registerLifecycleListener(): void {
  appStateSubscription?.remove();
  appWasBackgrounded = AppState.currentState === 'background';
  appStateSubscription = AppState.addEventListener('change', (nextState) => {
    const returningToForeground = appWasBackgrounded && nextState === 'active';
    const movingToBackground = nextState === 'background';
    if (movingToBackground) appWasBackgrounded = true;
    if (returningToForeground) appWasBackgrounded = false;

    const activeClient = client;
    if (!activeClient) return;
    if (returningToForeground) {
      runDetached((async () => {
        await replayPendingBackgroundNotifications(activeClient);
        await trackForegroundLifecycle(activeClient);
      })());
    }
    if (movingToBackground) runDetached(activeClient.flush());
  });
}

async function trackForegroundLifecycle(activeClient: NotifieClient): Promise<void> {
  const lifecycleProperties: NotifieProperties = {
    sdk: 'react-native',
    platform: Platform.OS,
  };
  const installed = await AsyncStorage.getItem(installedKey);
  if (!installed) {
    await AsyncStorage.setItem(installedKey, 'true');
    await activeClient.track('install', lifecycleProperties);
    await activeClient.track('first_open');
  }

  await activeClient.track('app_open', lifecycleProperties);
  await activeClient.track('session_start');
}

function replayPendingBackgroundNotifications(
  activeClient: NotifieClient,
): Promise<void> {
  const replay = backgroundReplay
    .catch(() => undefined)
    .then(async () => {
      await awaitBackgroundPersistence();
      for (const pending of await pendingBackgroundNotifications()) {
        if (!pending.notification) {
          await AsyncStorage.removeItem(pending.key);
          continue;
        }
        await activeClient.recordNotificationReceived(pending.notification);
        await AsyncStorage.removeItem(pending.key);
      }
    });
  backgroundReplay = replay.catch(() => undefined);
  return replay;
}

async function disposeCurrentClient(): Promise<void> {
  appStateSubscription?.remove();
  appStateSubscription = null;
  const current = client;
  client = null;
  if (current) await current.close();
}

function requireClient(): NotifieClient {
  if (!client) throw new Error('Call Notifie.initialize() before using the SDK.');
  return client;
}

async function loadAnonymousId(): Promise<string> {
  const existing = await AsyncStorage.getItem(anonymousIdKey);
  if (existing) return existing;

  const generated = createUuid();
  await AsyncStorage.setItem(anonymousIdKey, generated);
  return generated;
}

function runDetached(operation: Promise<void>): void {
  void operation.catch(() => undefined);
}
