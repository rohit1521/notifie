# Security Policy

## Reporting

Do not open a public issue for suspected credential exposure, authentication bypass, RLS failure,
cross-tenant access, push credential disclosure, or remote code execution. Contact the repository owner
privately with the affected path, reproduction, and impact. Avoid including real customer/provider secrets.

## Secret Handling

- Rotate any credential that enters Git history, logs, screenshots, fixtures, or chat transcripts.
- Supabase service-role and push encryption keys are server-only.
- APNs `.p8` and Firebase service-account keys must never ship in SDKs or mobile apps.
- Notifie API plaintext is displayed once and should be treated as a bearer credential.
- Redact Team IDs, bundle identifiers, device names/tokens, account emails, and key IDs from public media
  unless they are intentionally synthetic examples.

## Security-Sensitive Changes

Changes to authentication, API key verification, RLS, service-role queries, credential encryption,
provider adapters, or SQL `SECURITY DEFINER` functions require explicit tests for unauthorized access and
secret non-disclosure. Follow [docs/ai/data-security.md](docs/ai/data-security.md).