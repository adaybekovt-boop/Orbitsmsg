/// Local, privacy-preserving pre-send check for unambiguously dangerous text.
///
/// Orbits cannot server-scan end-to-end encrypted conversations. This narrow
/// filter runs on the sender's device and blocks explicit threats and sexual
/// abuse material before encryption. It intentionally avoids broad profanity
/// matching, which would create unacceptable false positives.
class ContentSafetyFilter {
  const ContentSafetyFilter._();

  static final List<({RegExp pattern, String reason})> _rules = [
    (
      pattern: RegExp(
        r'\b(kill|murder|shoot|stab)\s+(you|u|him|her|them)\b',
        caseSensitive: false,
        unicode: true,
      ),
      reason: 'явная угроза насилия',
    ),
    (
      pattern: RegExp(
        r'(убью|убить|зарежу|застрелю)\s+(тебя|его|её|их)',
        caseSensitive: false,
        unicode: true,
      ),
      reason: 'явная угроза насилия',
    ),
    (
      pattern: RegExp(
        r'\b(child\s*(porn|abuse\s*material)|csam)\b',
        caseSensitive: false,
        unicode: true,
      ),
      reason: 'материал о сексуальном насилии над детьми',
    ),
    (
      pattern: RegExp(
        r'детск(ая|ое|ую)\s+порнограф',
        caseSensitive: false,
        unicode: true,
      ),
      reason: 'материал о сексуальном насилии над детьми',
    ),
  ];

  static String? blockedReason(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    for (final rule in _rules) {
      if (rule.pattern.hasMatch(normalized)) return rule.reason;
    }
    return null;
  }
}
