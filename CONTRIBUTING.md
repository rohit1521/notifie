# Contributing to Notifie

## Setup

```bash
corepack enable
pnpm install --frozen-lockfile
pnpm check
```

## Expectations

1. Work on a focused branch and open a pull request.
2. Add a regression test with the implementation, not after it.
3. Run the narrowest relevant check while iterating, then `pnpm check`.
4. Run the native toolchain when changing Swift, Android or Flutter sources.
5. Keep SDK public APIs small; a new public symbol is a long-term commitment.

## Boundaries

These SDKs must build and test without any Notifie Cloud service present. Do not
add a dependency on a hosted endpoint, and do not widen a contract to expose
server-only concepts.

## Security

Never commit provider credentials. Report vulnerabilities privately as described
in [SECURITY.md](SECURITY.md).

## License

Contributions are accepted under [Apache-2.0](LICENSE).
