# Technical brief for KZ counsel (not an offer)

This file is **facts the product actually does today**, plus a checklist of
legal questions. It is **not** an оферта, privacy policy, or disclaimer.
Do not paste it into the app. Counsel writes those texts; engineering
slots them into the placeholder screens.

Related ticket (still not a legal document): [`lawyer-kz.md`](lawyer-kz.md).

Placeholder in the UI: `[TEXT PENDING LEGAL REVIEW]`
(`lib/legal/legal_placeholders.dart`).

---

## Product

- Name in this repository: **Orbits** (Flutter client).
- Repository: `https://github.com/adaybekovt-boop/tkmessenger`
- `LICENSE` in this repo is proprietary ("All rights reserved"). Public
  "open source" tags on the marketing site are **not** true until counsel
  and the owner change `LICENSE`.
- There is **no Orbits-operated chat backend** that stores message bodies.
  1:1 content is E2E (X3DH + Double Ratchet). Rooms are **host-plaintext**
  (the room organizer can read text/files/stickers). See
  [`rooms.md`](rooms.md), [`privacy.md`](privacy.md),
  [`security.md`](security.md).

---

## What is stored, and where

### On the user's device (local)

| Item | Where | Notes |
|------|--------|--------|
| Peer ID (`ORBIT-…`) and display name | SharedPreferences `orbits_identity_v1` | Created locally. Not an account on an Orbits server. |
| Vault password | Not stored. scrypt-derived KEK held in RAM while unlocked | Password cannot be recovered. |
| Optional biometric / remembered-session blob | OS secure storage / desktop keychain | Unlocks the local vault only. |
| 1:1 and room message bodies, attachments | Local SQLite (`orbits`) | Payloads wrapped under the vault KEK (`OB1` / `wrapSecret`). **File-level SQLCipher is off** — table names, peer IDs, timestamps, file names remain readable on a stolen DB file. |
| Contacts, room membership, channel names | Same SQLite | Treat as metadata. |
| App preferences (`orbits_*` keys) | SharedPreferences | Local flags, not credentials. |

There is **no** Orbits-owned database of conversations
(**нет серверов Владельца** that store chat content).

### What third parties can see (default build)

These are **not** "серверы Владельца". The default client uses public
infrastructure. The current in-app draft terms (`lib/ui/auth/terms_text.dart`)
incorrectly say technical data is stored "на серверах Владельца" — that
sentence is a **fact error** for counsel to replace, not to keep.

| Service | Endpoint / operator | What they can see |
|---------|---------------------|-------------------|
| PeerJS signalling | `0.peerjs.com`, `1.peerjs.com`, `2.peerjs.com` | Peer ID, online presence, SDP/ICE needed to introduce two peers. Not 1:1 message bodies. |
| Google STUN | `stun.l.google.com` … `stun4.l.google.com:19302` | Public IP and that the device is using WebRTC. |
| Mozilla STUN | `stun.services.mozilla.com` | Same class of IP / WebRTC metadata. |
| Twilio STUN | `global.stun.twilio.com:3478` | Same. |
| Optional TURN | User-configured at runtime (`TURN_URL` + prefs). **Not** baked into CI as secrets | Relayed media/data volumes if the user configured TURN. |
| GitHub Releases API | `https://api.github.com/repos/adaybekovt-boop/tkmessenger/releases/latest` | Update check: IP, user-agent, which installer asset is downloaded. |
| Flutter web build | `https://adaybekovt-boop.github.io/tkmessenger/` (GitHub Pages) | Ordinary web-host logs for people who open the PWA. |
| Marketing landing | `https://orbits-eeo.pages.dev/` (**Cloudflare Pages**, **not this git repo**) | Ordinary web-host logs for visitors. Copy on that site is marketing, not counsel text. |
| Embedded LAN signalling | `ws://` on the host LAN when someone creates a self-hosted room | Only machines that can reach that host. WAN/UPnP punch is off until WSS exists. |

Default ICE list: `lib/peer/signaling.dart` (`defaultIceServers`,
`buildSignalingHosts`).

### What the "Owner" does **not** operate

- No Orbits message store.
- No Orbits account server (registration is local password + local peer id).
- No Orbits-operated STUN/TURN in the stock build.
- No analytics / crash / ads SDK in this client.

---

## Lawyer checklist (6 open items)

Do **not** treat any box as done because UI stubs exist. Stubs show
`[TEXT PENDING LEGAL REVIEW]`.

- [ ] Субъект оферты — who is the operator (ИП / ТОО / физлицо) and which
      name + identifier must appear.
- [ ] 18+ — whether 18 is the correct age gate under RK law, and the
      required wording. UI has a checkbox stub only.
- [ ] Канал жалобы — required complaint path (email, form, state channel).
      UI has a form + interim GitHub Issues button; that is **not** a
      legal contact.
- [ ] Честное описание данных — replace "серверы Владельца" with an
      accurate description of local storage + named third parties above.
- [ ] Ограничение ответственности — what can legally be limited for a
      P2P client with host-plaintext rooms.
- [ ] Контакт для юридических запросов — address / email counsel wants
      published. Do not invent one.

---

## UI slots waiting for counsel text

| Slot | File | Current body |
|------|------|----------------|
| Offer / terms screen | `lib/pages/settings/legal_offer_page.dart` | `[TEXT PENDING LEGAL REVIEW]` |
| Complaint screen | `lib/pages/settings/complaint_page.dart` | Placeholder + optional note field + GitHub Issues button |
| Registration 18+ | `lib/ui/auth/onboarding_agreement_step.dart` | Checkbox label includes the same placeholder |
| Existing draft terms | `lib/ui/auth/terms_text.dart` | Unreviewed owner draft; still shown with a pending banner. **Not** counsel-approved. |

When counsel delivers text: replace only the placeholder constants / the
`kTermsRu` blocks they explicitly approve. Do not keep "серверы Владельца"
unless counsel confirms an Owner-operated server exists.
