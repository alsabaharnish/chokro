# Chokro trusted service

This Express service owns operations that a Flutter client must not be trusted
to perform: evidence verification, administrator decisions, policy changes, bin
registration, push decisions, and every wallet/ledger mutation.

## Run

Node 20 or newer is required.

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
`Authorization: Bearer <token>`. Administrator routes additionally read the live
role from `users/{uid}`.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/health` | Liveness and service version |
| GET | `/whoami` | Verify token, profile, and active-account state |
| POST | `/photos/disposal` | Store disposal evidence under the caller's folder |
| POST | `/photos/claim` | Store claim evidence under the caller's folder |
| POST | `/disposals/:id/verify` | Recompute and run the two-lane verification decision |
| POST | `/disposals/:id/review` | Administrator approve/reject |
| GET/POST | `/config/points` | Read or validate/update reward policy |
| POST | `/bins` | Register a bin |
| POST | `/bins/:id/active` | Close or reopen a bin |
| GET | `/claims/quota` | Current user's approved weekly-claim allowance |
| POST | `/claims/:id/review` | Administrator approve/reject a claim |
See `src/index.js` for exact request bodies and response shapes.

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
push, bin, and suspension logic without real Firebase, Cloudinary, or Groq calls.
