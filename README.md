# Chokro

Chokro is a Flutter recycling and eco-rewards app backed by Firebase. Users can
scan a registered bin, photograph a disposal, prove their location, and submit
evidence for verification. A trusted Node service performs screening and all
wallet writes; Firestore clients can never award points directly.

The user-facing profiles are **3ZERO Admin**, **3ZERO Greenpreneur**, and
**3ZERO Champion**. The stable Firestore/API role values remain `admin`, `seller`,
and `buyer`; profile selection changes the workspace, never authorization. See
the [v3 project brief](Chokro_Mobile_Project_Brief%20v3.md) for the complete
requirements and role hierarchy.

## Main flows

- Email/password registration and inclusive profiles: Admin holds all three,
  Greenpreneur also holds Champion, and Champion is the base profile
- Fast switching between held profiles, with correct defaults and
  profile-specific home/navigation content
- Champion education and application to become a 3ZERO Greenpreneur
- Four-step disposal flow: scan → photo → location → confirmation
- Server-side distance, photo-provenance, duplicate-hash, AI-screen, and cap checks
- Human review queues for flagged disposals and self-reported eco-actions
- Immutable points ledger, configurable policy, suspension, and push decisions
- Bin registration with printable high-error-correction QR labels
- Marketplace: Greenpreneur listings, catalogue search and category filter,
  cart, and checkout that splits into one order per Greenpreneur
- Points spent at checkout and credited back when the Champion confirms receipt,
  which is what makes earning and spending a cycle rather than a pipeline
- Champion point donations to waste recovery, tree planting, or green
  entrepreneurship, committed by the trusted service with idempotent retries
- Appeals against a rejection, and a 3ZERO Admin dashboard over server-held
  counters, including donated points and donation count

## Architecture

| Area | Location | Responsibility |
| --- | --- | --- |
| Flutter client | `lib/` | UI, Riverpod state, camera/location capture, Firebase reads and pending creates |
| Trusted service | `server/src/` | Live-role enforcement, verification, reviews, policy, checkout, donations, and every wallet mutation |
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

The trusted service uses Node 22 LTS (the version pinned by `server/package.json`):

```bash
cd server
npm install
npm run dev
```

Create `server/.env` with:

- `FIREBASE_SERVICE_ACCOUNT` — raw or base64 service-account JSON
- `CLOUDINARY_CLOUD_NAME`, `CLOUDINARY_API_KEY`, `CLOUDINARY_API_SECRET`
- `GROQ_API_KEY` — optional; without it disposals safely route to human review
- `ALLOWED_ORIGINS` — comma-separated Flutter web origins, for deployment
- `PORT` — optional, defaults to `8787`

### CORS in local development

Use `npm run dev`, not `npm start`. It sets `ALLOW_LOOPBACK_ORIGINS=true`, which
accepts **any** `localhost` or `127.0.0.1` port on top of `ALLOWED_ORIGINS`.

This matters more than it sounds. `flutter run -d chrome` picks a fresh port on
every launch, so an exact origin pinned in `ALLOWED_ORIGINS` cannot keep up — and
when it does not match, the failure is lopsided and confusing: **Firestore reads
keep working** because they do not pass through this service, so the app looks
mostly healthy while precisely the screens that call the server break. Checkout,
donations, bin registration, and the points policy editor are the ones to watch,
because they are the screens that talk to the server.

The flag is opt-in rather than inferred from `NODE_ENV`, so a missing variable on
a deploy cannot silently open the allowlist. Never set it in production.

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

## Demonstration data

Never demo from an empty database. The seed writes accounts, bins, listings,
disposals in every state, claims, orders and an appeal:

```bash
SEED_PASSWORD='choose-one' node server/scripts/seed.js --yes
```

`SEED_PASSWORD` has no default and the script refuses without `--yes`, because it
writes with the Admin SDK and bypasses every security rule. Wallet balances are
accumulated from the ledger entries it writes rather than asserted alongside
them, so the seeded data satisfies NFR-4 the same way the running app does.

## Security invariants

1. No Flutter client—including a 3ZERO Admin—can update a wallet balance,
   transaction, disposal decision, claim decision, bin geofence, or points policy.
2. A disposal auto-approves only after every required check runs and passes;
   unavailable or malformed evidence routes to review.
3. Photo URLs and Cloudinary public IDs must identify the same original asset in
   the authenticated user's purpose-specific folder.
4. Wallet credits and their ledger entries are committed together by the trusted
   service, with idempotent decision checks preventing duplicate payouts.
5. Checkout is one transaction: stock decremented, points debited with a matching
   ledger entry, one order written per Greenpreneur, and the cart consumed — or
   none of it happens.
6. Only the purchasing Champion can confirm an order, and only confirmation
   credits purchase points. No client writes an order at all, a 3ZERO Admin
   included.
7. Selecting a profile never grants a role. Rules and trusted-service middleware
   authorize against the live stored `users.role` value.
8. A point donation commits its wallet debit, `donation` ledger entry, receipt,
   and counters together. Its UID-scoped request ID makes retries idempotent.
