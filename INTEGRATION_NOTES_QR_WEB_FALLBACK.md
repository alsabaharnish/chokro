# QR App Link and Website Submission Integration Notes

**Status:** implemented and verified in source; production Hosting deployment,
server CORS configuration, release signing association, device smoke tests, and
physical label replacement remain rollout steps.

This revision gives every newly generated or reprinted physical-bin label one
HTTPS QR entry. If Chokro is installed and the platform has verified the domain
association, the operating system opens the app. Otherwise Firebase Hosting
opens the same Flutter disposal flow in the browser. An anonymous visitor
registers with name, email, and password, and the existing auth gate restores the
exact bin URL after account creation.

## Security and data boundary

- Firestore still stores `bins.qrPayload` as an opaque lookup token. New server
  allocations use `chokro:bin:{12 lowercase hex}`; the parser also retains the
  bounded alphanumeric, underscore, and hyphen suffixes used by legacy/demo
  labels. There is no bin-document migration.
- Labels printed by this revision and on-screen QR codes wrap that token as
  `https://chokro-30887.web.app/b/{payload}`. Coordinates, radius, creator, and
  user information are not encoded.
- Possessing or photographing a QR proves nothing. Web and native submissions
  still require a current device location inside the server-owned bin radius.
- Both targets use the same authenticated pending-disposal schema, trusted photo
  upload, perceptual hash, AI screen, lockout, daily cap, manual-review fallback,
  and server-only wallet mutation. Native builds require a new camera capture;
  browsers use a file chooser and cannot prove that a selected image was freshly
  captured. That capture-assurance difference does not bypass any server check.
- Old token-only QR labels remain readable inside the Chokro scanner. They do not
  gain browser fallback until reprinted.

## Routing and UX

- `BinLink` is the single formatter/parser for QR URLs. It accepts this
  deployment's HTTPS host and legacy opaque tokens, and rejects lookalike hosts
  or malformed token shapes.
- `/b/:payload` is protected by the normal active-account route guard. The
  existing pending-destination mechanism retains the full URL while an anonymous
  visitor signs in or creates an account, then returns to the bin. A cold native
  HTTPS app link is normalized to its internal path before that handoff, so the
  same registration-first behavior applies on Android, iOS, and web.
- `BinEntryView` resolves active/closed/unknown/locked-out states before starting
  a draft. A valid entry explains the evidence requirements and continues
  directly to photo selection; users do not scan the same label twice.
- On web, `image_picker` chooses a local photo and `geolocator` requests browser
  location. The user-initiated file chooser does not require camera permission;
  geolocation requires a secure production origin and explicit site permission.
- Browser users receive the immediate result in the flow and can revisit
  submission history. System push notifications are supported by mobile builds,
  not by the current Flutter web client.

## Domain association

| Platform | App configuration | Hosted proof |
|---|---|---|
| Android | Auto-verified HTTPS intent filter for `chokro-30887.web.app/b/*` | Hosted `/.well-known/assetlinks.json`, sourced from `web/assetlinks.json` |
| iOS | `applinks:chokro-30887.web.app` associated-domain entitlement | Hosted `/.well-known/apple-app-site-association`, sourced from `web/apple-app-site-association` |
| Browser | Firebase Hosting SPA rewrite | Flutter route `/b/:payload` |

The web app explicitly enables Flutter's path URL strategy. This is required:
the default hash strategy reads `/#/...`, so it would not see the clean
`/b/{payload}` address supplied by the QR even if Hosting returned `index.html`.
Before Flutter starts, `web/index.html` converts an older `/#/...` bookmark to
its clean-path equivalent so previously shared web links are not stranded.

The checked-in Android association contains the local debug certificate SHA-256
for device testing, and `android/app/build.gradle.kts` currently signs its
`release` build with that debug key for local demos. This is not production
signing. For Play distribution, add the Play App Signing certificate SHA-256
shown under **App integrity → App signing**; the upload-key fingerprint is not
the certificate installed on users' devices. For direct APK distribution,
configure a production signing key and add that certificate's SHA-256. A build
signed by an unlisted certificate still opens the website, but the OS cannot
open it directly as a verified app link.

The iOS association uses Team ID `UDBARM7GH7` and bundle ID
`com.arnish.chokro`. If either signing value changes, update the AASA `appID` and
rebuild the app. The Apple Developer App ID and the distribution provisioning
profile must also include the Associated Domains capability; verify the signed
build after AASA is public.

`CHOKRO_WEB_URL` must be a clean root HTTPS origin with no credentials, custom
port, path, query, or fragment. A custom origin is one coordinated contract:
bind it to Firebase Hosting, update the Android and iOS host declarations,
publish both matching association files, add the exact origin to server CORS,
then rebuild every app and every QR-producing client. Changing only the Dart
define can print working website links, but it cannot establish native app-link
ownership.

## Main implementation files

- `lib/core/bin_link.dart` — URL generation and strict scanned-value parsing
- `lib/views/disposal/bin_entry_view.dart` — resolved-bin website/app entry
- `lib/routing/router.dart` — protected `/b/:payload` route
- `lib/services/bin_service.dart` — URL and legacy-token resolution
- `lib/core/bin_label_pdf.dart`, `lib/views/admin/admin_bins_view.dart` — HTTPS
  QR rendering, copy, print, and explanatory text
- `android/app/src/main/AndroidManifest.xml`, `ios/Runner/Runner.entitlements`,
  `ios/Runner/Info.plist`, `ios/Runner.xcodeproj/project.pbxproj` — native
  deep-link declarations and associated-domain capability
- `web/assetlinks.json`, `web/apple-app-site-association`, `firebase.json` —
  deployable association payloads, required `/.well-known` rewrites, and content
  types. The rewrites avoid the existing dot-directory ignore rule.

## Release verification

1. Confirm the final clean HTTPS origin, its Firebase Hosting binding, and every
   synchronized native/hosted association entry before generating labels.
2. Configure production signing. For Play, use the Play App Signing certificate
   in `assetlinks.json`; for a direct APK, configure a production key and use its
   fingerprint. Confirm the Apple App ID and provisioning profile include
   Associated Domains.
3. Build and deploy the Flutter web client with Firebase Hosting.
4. Set the trusted service's production `ALLOWED_ORIGINS` to include the exact
   origin `https://chokro-30887.web.app`, confirm production Cloudinary
   credentials, restart the service, check `GET /health`, and complete one
   authenticated disposal-photo upload smoke test from the hosted origin.
5. Fetch both `/.well-known` files from the public domain and confirm HTTP 200
   with `Content-Type: application/json`.
6. On an Android build signed with a listed fingerprint and an iOS build signed
   by the listed team, scan a newly printed label and confirm Chokro opens at the
   named bin.
7. Remove the app or use a second phone, scan the same label, register a new
   account, and confirm the named bin reappears before photo/location capture.
8. Confirm a browser submission shows its immediate result and remains visible
   in history; do not expect a web system-push notification.
9. Reprint and replace each deployed token-only label that should gain browser
   fallback; retain the old label only where app-only scanning is acceptable.
10. Confirm an outside-radius submission, reused photo, lockout, and closed bin
   behave identically on web and native.
