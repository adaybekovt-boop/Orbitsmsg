# Security Policy

## Supported versions

Security fixes are produced for the latest released `9.x` line only.

| Version | Supported |
|---------|-----------|
| 9.x     | Yes       |
| < 9.0   | No        |

Builds produced from `main` between tagged releases are preview snapshots and
are not a supported security surface.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for a security vulnerability.

Use GitHub's private vulnerability reporting on this repository:

https://github.com/adaybekovt-boop/tkmessenger/security/advisories/new

Include:

- a description of the issue and the impact
- affected version / commit SHA
- steps to reproduce, or a proof of concept
- any suggested fix, if you have one

Do not attach production keystores, user databases, or real message dumps.

## Response SLA

| Step | Target |
|------|--------|
| Acknowledgement | within **3 business days** |
| Initial severity assessment and next-step update | within **7 days** of acknowledgement |
| Fix or documented mitigation for Critical / High in a supported version | as soon as a verified patch exists; we aim to ship it in the next patch release |

If we cannot meet a target we will say so in the advisory thread with a
revised date. We will credit reporters who want to be named, unless they
ask to stay anonymous.

## Scope notes

Orbits is a P2P client. Reports against third-party infrastructure that the
client talks to by default (public STUN, the default PeerJS signalling host,
GitHub Releases used for updates) are in scope **only** insofar as the client
trusts them unsafely. Compromising those services themselves should be
reported to their operators.

## Windows auto-update

The in-app updater must not launch an installer unless Authenticode is valid
and the publisher matches the Orbits pin. See `docs/windows-signing.md`.

Please see future `docs/security.md` for the encryption map (what is E2E,
what is not, and which metadata remains visible).