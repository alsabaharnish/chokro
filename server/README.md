# Chokro trusted service

This Express service owns operations that a Flutter client must not be trusted
to perform: evidence verification, 3ZERO Admin decisions, policy changes, bin
registration, push decisions, and every wallet/ledger mutation, including
Champion point donations and explicitly simulated online-payment receipts.

## Run

Node 22 is required, as pinned by `package.json`.

```bash
npm install
npm run dev
```

Environment variables:

- `FIREBASE_SERVICE_ACCOUNT` — raw JSON or base64-encoded service-account JSON
- `CLOUDINARY_CLOUD_NAME`, `CLOUDINARY_API_KEY`, `CLOUDINARY_API_SECRET`
- `GROQ_API_KEY` — optional; missing/unavailable screening fails toward review
- `ALLOWED_ORIGINS` — comma-separated web origins
- `PORT` — defaults to `8787`

The service-account credential uses the Admin SDK and bypasses Firestore rules.
Keep it out of source control and logs.

## API

Except for health/upload limits, endpoints require a Firebase ID token in
`Authorization: Bearer <token>`. Protected routes read the live stored role from
`users/{uid}`. The user-facing names are 3ZERO Admin, 3ZERO Greenpreneur, and
3ZERO Champion; the stable authorization values remain `admin`, `seller`, and
`buyer`. A client-selected profile is never accepted as authorization.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/health` | Liveness and service version |
| GET | `/whoami` | Verify token, stored account record, and active-account state |
| GET | `/admin/ping` | Verify the caller's live 3ZERO Admin authority |
| GET | `/photos/limits` | Public upload constraints used by the client |
| POST | `/photos/disposal` | Store disposal evidence under the caller's folder |
| POST | `/photos/claim` | Store claim evidence under the caller's folder |
| POST | `/photos/product` | Store product media for a Greenpreneur |
| POST | `/disposals/:id/verify` | Recompute and run the two-lane verification decision |
| POST | `/disposals/:id/review` | 3ZERO Admin approve/reject |
| GET | `/claims/quota` | Current Champion's approved weekly-claim allowance |
| POST | `/claims/:id/review` | 3ZERO Admin approve/reject a claim |
| POST | `/checkout` | Atomically redeem points, decrement stock, consume cart, and create orders |
| POST | `/donations` | Atomically donate Champion points to a fixed green initiative |
| POST | `/donations/prototype-payments` | Record an idempotent bKash, Nagad, or card simulation; no real payment |
| POST | `/orders/:id/status` | Greenpreneur advances an owned order |
| POST | `/orders/:id/confirm` | Purchasing Champion confirms receipt and releases points |
| POST | `/sellers/:uid/listings` | Admin updates listing visibility after account action; path keeps the wire-role name |
| GET/POST | `/config/points` | Read or validate/update reward policy |
| POST | `/bins` | Register a bin |
| POST | `/bins/:id/active` | Close or reopen a bin |

See `src/index.js` for exact request bodies and response shapes.

## Donation guarantees

`POST /donations` accepts a client-generated `donationId`, one of
`wasteRecovery`, `treePlanting`, or `greenEntrepreneurship`, and a whole-point
amount from 10 through 1,000,000. `donations.js` scopes the idempotency key to the
authenticated UID and uses one Firestore transaction to:

1. validate the existing receipt, account wallet, and available balance;
2. debit the wallet;
3. append a `transactions` entry with `source=donation`;
4. write a server-only donation receipt; and
5. increment `stats.pointsDonated` and `stats.donationsReceived`.

Retrying the same request returns the original result without another debit.
Reusing its ID with different content is rejected. A failure before commit takes
no points, and Firestore rules deny all client reads and writes on receipts.

`POST /donations/prototype-payments` accepts the same UID-scoped idempotency key
and initiative, a whole-taka amount from 10 through 1,000,000, and one of
`prototypeBkash`, `prototypeNagad`, or `prototypeCard`. It never accepts an
account number, card number, PIN, OTP, password, token, or processor payload. It
writes a `kind=prototypeOnline`, `paymentPrototype=true` receipt plus a `SIM-...`
reference and increments separately named prototype counters. It does not touch
the wallet or ledger and is not proof that money moved.

## Verification flow

`verify.js` loads the pending disposal and trusted bin, then:

1. validates coordinates, declaration, and uploaded-photo ownership;
2. recomputes distance server-side;
3. fingerprints the hosted image and checks recent user history;
4. requests AI screening when configured;
5. checks the daily cap and calls the pure `decide()` function;
6. either credits through `award.js` or records review flags.

Any unavailable or malformed check produces a review flag. It never becomes a
default approval.

## Test

```bash
npm test -- --runInBand
```

The suite is offline: it exercises decision, hashing, photo-reference, policy,
push, bin, suspension, checkout, orders, listings, and donation logic without
real Firebase, Cloudinary, or Groq calls.
