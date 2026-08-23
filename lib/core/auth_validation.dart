// Port of src/core/authValidation.js — username / password validation.
//
// Error codes must stay identical to the React build so shared UI copy
// (translations, error messages) keeps working across both clients.

class ValidationResult {
  final bool ok;
  final String? code;
  final String? value;
  const ValidationResult._(this.ok, this.code, this.value);

  const ValidationResult.fail(String code) : this._(false, code, null);
  const ValidationResult.pass([String? value]) : this._(true, null, value);
}

// Letters / digits / underscore, Unicode-aware. Matches the JS `\p{L}\p{N}_`
// character class. Dart regex supports \p{L} via `unicode: true`.
final RegExp _usernameRe = RegExp(r'^[\p{L}\p{N}_]+$', unicode: true);
final RegExp _hasLower = RegExp(r'[a-z]');
final RegExp _hasUpper = RegExp(r'[A-Z]');
final RegExp _hasDigit = RegExp(r'[0-9]');
final RegExp _hasSpecial = RegExp(r'[^a-zA-Z0-9]');
final RegExp _tripleRun = RegExp(r'(.)\1\1');

ValidationResult validateUsername(String? username) {
  final v = (username ?? '').trim();
  if (v.isEmpty) return const ValidationResult.fail('required');
  if (v.length < 3) return const ValidationResult.fail('min_len');
  if (v.length > 30) return const ValidationResult.fail('max_len');
  if (!_usernameRe.hasMatch(v)) return const ValidationResult.fail('pattern');
  return ValidationResult.pass(v);
}

int passwordStrength(String? password) {
  final p = password ?? '';
  var score = 0;
  if (p.length >= 8) score++;
  if (p.length >= 12) score++;
  if (_hasLower.hasMatch(p)) score++;
  if (_hasUpper.hasMatch(p)) score++;
  if (_hasDigit.hasMatch(p)) score++;
  if (_hasSpecial.hasMatch(p)) score++;
  if (_tripleRun.hasMatch(p)) score = score - 1;
  if (score < 0) score = 0;
  if (score > 5) score = 5;
  return score;
}

/// New-account password policy: 12+ characters and at least two of
/// lower / upper / digit / special. Unlock of existing profiles does not
/// go through this — only onboarding / change-password.
ValidationResult validatePassword(String? password) {
  final p = password ?? '';
  if (p.isEmpty) return const ValidationResult.fail('required');
  if (p.length < 12) return const ValidationResult.fail('min_len');
  var classes = 0;
  if (_hasLower.hasMatch(p)) classes++;
  if (_hasUpper.hasMatch(p)) classes++;
  if (_hasDigit.hasMatch(p)) classes++;
  if (_hasSpecial.hasMatch(p)) classes++;
  if (classes < 2) return const ValidationResult.fail('weak');
  return ValidationResult.pass(p);
}

String passwordPolicyHint() =>
    'Пароль: минимум 12 символов и два типа знаков (буквы, цифры, символы)';

ValidationResult validatePasswordConfirm(String? password, String? confirm) {
  if ((password ?? '') != (confirm ?? '')) {
    return const ValidationResult.fail('mismatch');
  }
  return const ValidationResult.pass();
}
