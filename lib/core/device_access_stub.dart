// Native/default stub for the device-access gate.
//
// The mobile-phone block only applies to the *web* build (the requirement is
// "phone via the web version"). Native desktop/mobile apps are a separate,
// legitimate distribution, so access is always allowed here.

/// Whether this device is barred from running the app. Always false on native.
bool isAccessDenied() => false;
