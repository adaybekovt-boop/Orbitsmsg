// Honest room-crypto disclaimer (Phase 2.2).
//
// Room packets are plaintext maps on the reliable DataChannel. DTLS protects
// the hop to the host; the host can read every text/file/sticker and relays
// them to guests. There is no per-sender group ratchet, epoch, or
// rekey-on-kick. Do not add `room_crypto.dart` until a real group protocol
// exists — a half protocol is worse than an honest banner.

/// Short in-app banner (Russian UI).
const String kRoomNotE2eBannerRu =
    'Организатор видит все сообщения и файлы. Комнаты без сквозного '
    'шифрования — только DTLS до хоста.';
