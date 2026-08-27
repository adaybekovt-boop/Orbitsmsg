// Shared raw-byte caps for chat attachments and Orbits Drop.
// Chat UI, `saveFileBlob`, and the Drop engine must advertise the same
// number — a 13 MiB file that the engine accepts would ACK and then fail
// the DB write (R6-04).

/// Hard cap on a single file payload (12 MiB).
const int kMaxFileRawBytes = 12 * 1024 * 1024;
