## Summary

Describe the storage behavior changed and the failure it addresses.

## Verification

- [ ] No blocking disk I/O was added to the main UI isolate.
- [ ] The `flashguard-chaos` fixtures cover relevant disconnect, truncation, duplicate, and bit-flip cases.
- [ ] A trusted pre-copy digest is supplied when claiming detection of pre-existing silent corruption.
- [ ] Resume behavior validates saved blocks and never overwrites an existing destination.
- [ ] New controllers and subscriptions are disposed.
- [ ] I reviewed every AI-generated diff line and ran `flutter analyze --fatal-infos`, `flutter test`, and Python unit tests.

Paste test output or link the CI run. Mark any untested mobile hardware path explicitly.
