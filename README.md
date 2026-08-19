# Chokro

Chokro is a Flutter recycling and eco-rewards app backed by Firebase. Users can
scan a registered bin, photograph a disposal, prove their location, and submit
evidence for verification. A trusted Node service performs screening and all
wallet writes; Firestore clients can never award points directly.

## Main flows

- Email/password registration, profile management, and seller applications
- Four-step disposal flow: scan → photo → location → confirmation
- Server-side distance, photo-provenance, duplicate-hash, AI-screen, and cap checks
- Human review queues for flagged disposals and self-reported eco-actions
- Immutable points ledger, configurable policy, suspension, and push decisions
- Bin registration with printable high-error-correction QR labels

## Architecture

| Area | Location | Responsibility |
| --- | --- | --- |
| Flutter client | `lib/` | UI, Riverpod state, camera/location capture, Firebase reads and pending creates |
| Trusted service | `server/src/` | Auth/role enforcement, verification, reviews, policy, and every wallet mutation |
| Security boundary | `firestore.rules` | Exact client schemas, ownership, active-account checks, and server-only payout fields |
| Rules tests | `rules_test/` | Emulator tests for ownership, privilege, schema, timestamps, and immutable balances |
| App/server tests | `test/`, `server/test/` | Dart models/widgets and pure backend decision logic |

## Run locally

```bash
flutter pub get
flutter run --dart-define=CHOKRO_API=http://10.0.2.2:8787
```

Use `localhost` for Flutter web/iOS simulator, `10.0.2.2` for the Android
emulator, or the development computer's LAN address for a physical device.

The trusted service uses Node 20+:

```bash
cd server
npm install
npm run dev
```

Create `server/.env` with:

- `FIREBASE_SERVICE_ACCOUNT` — raw or base64 service-account JSON
- `CLOUDINARY_CLOUD_NAME`, `CLOUDINARY_API_KEY`, `CLOUDINARY_API_SECRET`
- `GROQ_API_KEY` — optional; without it disposals safely route to human review
- `ALLOWED_ORIGINS` — comma-separated Flutter web origins
- `PORT` — optional, defaults to `8787`

Never commit `server/.env` or a service-account file.

## Quality checks

```bash
flutter analyze lib test
flutter test
npm test --prefix server -- --runInBand
npx -y firebase-tools@latest emulators:exec --only firestore \
  "npm test --prefix rules_test"
npx -y firebase-tools@latest deploy --only firestore:rules --dry-run
```

The last command compiles the rules but does not deploy them.

## Security invariants

1. No Flutter client—including an administrator—can update a wallet balance,
   transaction, disposal decision, claim decision, bin geofence, or points policy.
2. A disposal auto-approves only after every required check runs and passes;
   unavailable or malformed evidence routes to review.
3. Photo URLs and Cloudinary public IDs must identify the same original asset in
   the authenticated user's purpose-specific folder.
4. Wallet credits and their ledger entries are committed together by the trusted
   service, with idempotent decision checks preventing duplicate payouts.
