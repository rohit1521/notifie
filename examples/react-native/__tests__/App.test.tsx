import React from 'react';
import ReactTestRenderer, { act } from 'react-test-renderer';
import type {
  NotifieNotification,
  NotifieProperties,
} from '@notifie-dev/react-native';
import { Harness, type DemoSdk } from '../App';

jest.mock('@notifie-dev/react-native', () => ({ Notifie: {} }));

it('drives the complete Notifie host workflow', async () => {
  const sdk = new FakeDemoSdk();
  let renderer: ReactTestRenderer.ReactTestRenderer | undefined;
  await act(async () => {
    renderer = ReactTestRenderer.create(<Harness sdk={sdk} />);
  });
  const root = renderer!.root;

  await act(async () => {
    await root.findByProps({ testID: 'initialize' }).props.onPress();
  });
  expect(sdk.calls[0]).toMatchObject({ kind: 'initialize' });
  expect(root.findByProps({ testID: 'status' }).props.children).toBe(
    'SDK initialized',
  );

  for (const testID of [
    'identify',
    'track',
    'notifications',
    'flush',
    'reset',
  ]) {
    await act(async () => {
      const target = root.findByProps({ testID });
      target.props.onPress();
      await new Promise<void>(resolve => setTimeout(() => resolve(), 0));
    });
  }

  expect(sdk.calls.map(call => call.kind)).toEqual([
    'initialize',
    'identify',
    'track',
    'notifications',
    'flush',
    'reset',
  ]);
  expect(sdk.calls[1]).toMatchObject({ userId: 'react-native-example-user' });
  expect(sdk.calls[2]).toMatchObject({ eventName: 'post_liked' });
  expect(
    String(root.findByProps({ testID: 'last-notification' }).props.children),
  ).toContain('myapp://posts/post-7');
});

type Call = {
  kind: string;
  userId?: string;
  eventName?: string;
};

class FakeDemoSdk implements DemoSdk {
  readonly calls: Call[] = [];
  private onOpened: ((notification: NotifieNotification) => void) | undefined;

  async initialize(options: {
    apiKey: string;
    baseUrl: string;
    onNotificationReceived(notification: NotifieNotification): void;
    onNotificationOpened(notification: NotifieNotification): void;
  }): Promise<void> {
    this.calls.push({ kind: 'initialize' });
    this.onOpened = options.onNotificationOpened;
  }

  async identify(
    userId: string,
    _properties?: NotifieProperties,
  ): Promise<void> {
    this.calls.push({ kind: 'identify', userId });
  }

  async track(
    eventName: string,
    _properties?: NotifieProperties,
  ): Promise<void> {
    this.calls.push({ kind: 'track', eventName });
  }

  async enableNotifications(): Promise<void> {
    this.calls.push({ kind: 'notifications' });
    this.onOpened?.({
      data: {
        gk_invocation_id: 'inv-example',
        gk_deep_link: 'myapp://posts/post-7',
      },
      invocationId: 'inv-example',
      deepLink: 'myapp://posts/post-7',
    });
  }

  async flush(): Promise<void> {
    this.calls.push({ kind: 'flush' });
  }

  async reset(): Promise<void> {
    this.calls.push({ kind: 'reset' });
  }
}
