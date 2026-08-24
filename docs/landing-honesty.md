# Landing page honesty (Round 3 D)

The marketing site `https://orbits-eeo.pages.dev/` is **not in this repository**.
There is no landing repo under `adaybekovt-boop` that this
agent can open a PR against. Cloudflare Pages (`orbits-eeo`) is a separate
deploy. Do not treat this item as done on the **live** site until that
project is updated.

An honest replacement page lives at
[`landing-replacement/index.html`](landing-replacement/index.html). Upload
that file (or its copy) to the Cloudflare project. It is **not** wired into
Flutter `web/` on purpose — that folder is the PWA shell.

## Confirmed on 2026-08-24 (live fetch + GitHub)

Live `https://orbits-eeo.pages.dev/` still:

- Title / brand: **Orbits Titan** (product name in this repo is **Orbits**)
- Tags: `P2P · без серверов · open source` — all three are false or misleading
- Demo bubble: «Шифрование подтверждено» with no verification step
- Four themes (Obsidian / Paper / Matrix / Sakura); the app catalog is two
  (`orbits-dark`, `orbits-light` in `lib/themes/registry.dart`)
- Debug counter `000 / 100` in the production page
- Download cards pinned to **v8.0.2**:
  - `…/releases/download/v8.0.2/orbits-windows-x64.exe`
  - `…/releases/download/v8.0.2/orbits-android-*.apk`
- Web button has no desktop-host caveat
- Footer: «Бесплатно · open source» while `LICENSE` is proprietary

### Download check (same day)

| URL | Resolves to |
|-----|-------------|
| `…/releases/latest/download/orbits-windows-x64.exe` | **v9.0.6** (`releases/download/v9.0.6/orbits-windows-x64.exe`) |
| Landing Windows button | **v8.0.2** |

Latest GitHub release tag on 2026-08-24: **v9.0.6** (published 2026-06-05).
The live landing ships a stale installer.

In-repo README already uses `/releases/latest/download/`
(`test/docs_consistency/latest_download_links_test.dart`).

## GitHub About (blocked here)

`gh repo view adaybekovt-boop/tkmessenger` → description is still `das`.
`homepageUrl` is empty. Topics are empty.

This automation is **read-only** on GitHub metadata (no `gh repo edit`,
GitHub MCP discovery failed). A maintainer must run, in the GitHub UI or
with a write token:

```
gh repo edit adaybekovt-boop/tkmessenger \
  --description "Orbits — P2P messenger. 1:1 chats are E2E; rooms are host-plaintext." \
  --homepage "https://orbits-eeo.pages.dev/"
```

Until that happens, D.1 is **not done**.

## Required decisions and copy

| Current (live) | Required |
| --- | --- |
| Orbits Titan | Orbits |
| без серверов | без хранения переписки на наших серверах. Соединение идёт через сигналинг PeerJS и STUN третьих сторон — это не «без серверов» |
| open source | **убрать везде** (включая GitHub topics), **или** сменить LICENSE. Смешивать proprietary LICENSE с «open source» нельзя |
| Шифрование подтверждено | убрать / «демо, не настоящий чат» |
| 4 themes | 2 themes matching `lib/themes/registry.dart` |
| 000 / 100 | delete from the production build |
| `…/download/v8.0.2/…` | `https://github.com/adaybekovt-boop/tkmessenger/releases/latest/download/orbits-windows-x64.exe` (and the Android assets) |
| Web CTA | «Веб открывается и на телефоне. Создать сервер можно только с компьютера» |

## Open-source decision (record it once)

This repository's `LICENSE` is proprietary. Until a lawyer/owner changes
that file, every public "open source" tag is a false statement.

The Flutter web app in **this** repo is **not** blocked on phones
(`test/web/web_device_access_test.dart`). Do not reintroduce a pre-Flutter
phone gate.

## Earlier fetch

2026-08-23: same live defects (Titan, open source, v8.0.2). Unchanged on
2026-08-24.
