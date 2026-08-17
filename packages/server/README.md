# Notifie Server SDK

> **Not published yet.** `@notifie-dev/server` is not on npm, so importing it
> from a package manager will fail today. It builds and tests in this
> repository; use it by reading the source or pinning a git checkout. Until it
> ships, call the [HTTP API](../../docs-public/api) directly.

One server client owns four operations: `identify`, `track`, `trigger`, and `notify`.

```ts
import { Notifie } from '@notifie-dev/server';

const growth = new Notifie({
  ingestKey: process.env.NOTIFIE_INGEST_KEY,
  sendKey: process.env.NOTIFIE_SEND_KEY,
});

await growth.identify('user-123', { first_name: 'Rohit', plan: 'pro' });

await growth.track('post_liked', {
  userId: 'user-123',
  properties: { actor_name: 'Maya', post_id: 'post-7' },
});

// Preferred for recipient-targeted messaging. The Flow owns the payload.
await growth.trigger('post_liked', {
  to: 'user-123',
  data: { actor_name: 'Maya', post_id: 'post-7' },
  idempotencyKey: 'like-42',
});

// Escape hatch when notification content genuinely belongs in backend code.
await growth.notify({
  to: 'user-123',
  type: 'social',
  notification: {
    title: '{{actor_name}} liked your post',
    body: 'Open {{post_id}}',
    collapseId: 'post-{{post_id}}',
  },
  parameters: { actor_name: 'Maya', post_id: 'post-7' },
});
```

Use `deliverAt` for an absolute ISO timestamp or `delaySeconds` for a relative
schedule. Pass up to 100 external user IDs in `to`.

`trigger` and `notify` require a server-only send key. `track` uses an ingest
key and remains appropriate when the event itself is the product signal.

The SDK creates idempotency IDs before retrying transient failures. Supplying an
explicit `idempotencyKey` lets separate processes safely retry the same command.
Never ship the send key in a mobile or web application.