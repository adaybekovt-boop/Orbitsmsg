# Landing page honesty (B.2)

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
| Web CTA | «Веб открывается и на телефоне. Создать сервер можно только с компьютера» |

## Open-source decision (record it once)

This repository's `LICENSE` is proprietary. Until a lawyer/owner changes
that file, every public "open source" tag is a false statement.

GitHub About is currently `das`. A maintainer must set a real description;
this automation cannot write repository metadata.
