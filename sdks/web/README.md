# Notifie for Web

The Web SDK owns anonymous browser identity and event delivery.

```ts
import { Notifie } from '@notifie/web';

Notifie.initialize({ apiKey: '<SDK_INGEST_KEY>' });
await Notifie.track('notification_requested');
```

Web push is not part of the current mobile push-token contract. The Web SDK is
event-only and does not expose transport or identity details to application
code.