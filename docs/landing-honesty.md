# Landing page honesty (B.2 / B.3 / B.4)

The marketing site `https://orbits-eeo.pages.dev/` is **not in this
repository**. This file is the brief for whoever owns that Cloudflare Pages
project.

Round 2 **cannot** patch HTML that is not here. Do not treat B.2 as done
until that project is updated. This is not a passed security test.

## Confirmed on 2026-08-23 (live fetch)

- Title / brand: **Orbits Titan** (product name in this repo is **Orbits**)
- Tags: `P2P · без серверов · open source` — all three are false or misleading
- Demo bubble: «Шифрование подтверждено» with no verification step
- Four themes (Obsidian / Paper / Matrix / Sakura); the app catalog is two
  (`orbits-dark`, `orbits-light` in `lib/themes/registry.dart`)
- Debug counter `000 / 100` in the production page
- Download cards pinned to **v8.0.2** instead of
  `…/releases/latest/download/…`
- Web button has no desktop-host caveat
- Footer: «Бесплатно · open source» while `LICENSE` is proprietary
  ("All rights reserved")

## Required decisions and copy

| Current | Required |
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

GitHub About is currently `das`. A maintainer must set a real description;
this automation cannot write repository metadata.

The Flutter web app in **this** repo is **not** blocked on phones
(`test/web/web_device_access_test.dart`). Do not reintroduce a pre-Flutter
phone gate.
