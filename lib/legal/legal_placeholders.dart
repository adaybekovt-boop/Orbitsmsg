import 'package:flutter/foundation.dart';

/// Neutral stand-in for counsel-authored copy. Do not replace this with
/// model-generated "legal" prose.
const String kLegalPendingPlaceholder = '[TEXT PENDING LEGAL REVIEW]';

/// Interim technical channel until counsel names a legal contact.
const String kComplaintChannelUrl =
    'https://github.com/adaybekovt-boop/tkmessenger/issues/new';

const String kAgeConfirmLabelRu = 'Мне исполнилось 18 лет';

const Key kLegalOfferBodyKey = Key('legal-offer-pending-body');
const Key kComplaintOpenChannelKey = Key('legal-complaint-open-channel');
const Key kAgeConfirmCheckboxKey = Key('onboarding-age-confirm');

/// Registration may finish only after terms **and** the age checkbox.
bool canCompleteOnboarding({
  required bool termsAccepted,
  required bool ageConfirmed,
}) => termsAccepted && ageConfirmed;
