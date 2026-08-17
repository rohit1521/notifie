# Notifie for Web

> **Not published yet.** `@notifie-dev/web` is not on npm, so importing it from
> a package manager will fail today. It builds and tests in this repository; use
> it by reading the source or pinning a git checkout.

The Web SDK owns anonymous browser identity and event delivery.

```ts
import { Notifie } from '@notifie-dev/web';

Notifie.initialize({ apiKey: '<SDK_INGEST_KEY>' });
await Notifie.track('notification_requested');
```

Web push is not part of the current mobile push-token contract. The Web SDK is
event-only and does not expose transport or identity details to application
code.