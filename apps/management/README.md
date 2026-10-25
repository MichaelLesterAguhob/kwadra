# Kwadra Flutter app

Version 0.6.0+7: a native Flutter marketplace opens first. Browsing is public; saving rentals, landlord conversations and viewings require sign-in. Landlord, tenant and moderator workspaces are available from Account. Backend source stays in `../../kwadra-backend-api`. See [mobile marketplace](../../docs/MOBILE_MARKETPLACE.md).

See [root setup](../../README.md) and [Phase 1–3 status](../../docs/PHASES_1_TO_3.md) for accounts, workflows and limits.

```powershell
flutter pub get
flutter run -d chrome --web-port 8080
flutter analyze
flutter test
flutter build apk --debug
```

The backend is required. Set the API address from Account → Server connection while signed out, or with `--dart-define=API_BASE_URL=https://YOUR_API/api/v1`. Android emulator defaults to `10.0.2.2:3000`; a physical phone needs the PC's Wi-Fi IP. Only debug builds allow local HTTP. Native credentials now persist in platform secure storage and refresh automatically; the API URL remains in preferences. Restart the backend and fully restart Flutter after upgrading.

The previous standalone demo is available with `--dart-define=LOCAL_DEMO=true` and does not upload saved data. Payments remain a fictional UI preview with no backend operation.


Secure remembered native sessions and live in-app notifications are implemented. Google sign-in needs real OAuth client IDs; phone push and external email delivery remain deferred. See [account setup and device acceptance](../../docs/ACCOUNTS_AND_IN_APP_NOTIFICATIONS.md).
