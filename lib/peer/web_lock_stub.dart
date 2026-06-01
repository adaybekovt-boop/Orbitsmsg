// Native/default stub for the Web Locks helper used by `multi_tab_lock.dart`.
//
// The browser Web Locks API gives race-free, cold-start-safe cross-tab
// exclusion that SharedPreferences polling can't. There's no equivalent (or
// need) on native — a second copy of the app generally can't launch — so this
// is a no-op that always "grants".

/// Try to take the exclusive web lock [name]. Returns true (granted) on
/// native; on web returns false when another tab already holds it.
Future<bool> acquireWebLock(String name) async => true;

/// Release a previously-held web lock. No-op on native.
void releaseWebLock(String name) {}
