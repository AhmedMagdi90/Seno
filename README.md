# Seno

Seno is an Android-first Flutter MVP for online sellers who receive customer orders through chat, reserve products from supplier offices, hand off delivery details, and track income.

## MVP Features

- In-app Seno logo and branded theme.
- Dashboard with order, reservation, delivery, and profit summary.
- Orders screen with customer/phone search and status filtering.
- New order form with customer details, pickup/shipment mode, address, notes, product photo, office, origin price, customer price, and paid amount.
- Product photo capture from camera or gallery through `image_picker`.
- Offices screen with office contacts and one-click reservation for all pending products assigned to that office.
- Reservation and delivery WhatsApp handoff using prepared messages through `url_launcher`; messages are also copied to clipboard.
- Order details screen with product status updates, payment updates, delivery handoff, customer received, and close order actions.
- Finance screen with sales, cost, paid, remaining, and profit totals.
- Local persistence through `shared_preferences`.

## Run

```bash
flutter pub get
flutter run
```

## Verify

```bash
flutter analyze
flutter test
```

## Download APK From GitHub

After this project is pushed to GitHub:

1. Open the repository on GitHub.
2. Go to `Actions`.
3. Open the latest `Build Android Debug APK` run.
4. Download the `seno-debug-apk` artifact.
5. Extract it and install `app-debug.apk` on your Android phone.

## Current Environment Note

The code analyzes and tests cleanly in this workspace. Building an Android APK is currently blocked on this machine because no Android SDK is configured. Configure Android Studio or set `ANDROID_HOME`, then run:

```bash
flutter build apk --debug
```
