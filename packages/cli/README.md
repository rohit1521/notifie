# Notifie CLI

Project setup and diagnostics for Notifie integrations.

## Run without installing

```bash
npx @notifie-dev/cli@beta doctor
```

## Commands

```text
notifie init YOUR_SDK_INGEST_KEY
notifie doctor
notifie templates
notifie install <template-id>
notifie test-push
```

- `init` saves the SDK ingest key and configures the detected project.
- `doctor` checks the integration end to end.
- `templates` lists the available notification templates.
- `install` explains what a template does before you apply it.
- `test-push` sends the setup event used by the dashboard test flow.

The CLI never handles APNs or FCM credentials itself. Those are uploaded in the
dashboard, encrypted at rest, and never written to disk by these commands.
