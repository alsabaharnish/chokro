# Response to the external audit of commit `6947fbe`

The audit reported 33 findings across the whole project — 5 High, 16 Medium,
12 Low. Every claim acted on below was **re-verified against the source before
anything was changed**; an audit is a set of claims to check, not a work order.

Two findings did not survive that check and are recorded at the bottom.

**Verification after the changes**

| Check | Before | After |
|---|---|---|
| `flutter analyze lib test` | clean | clean |
| `flutter test` | 425 | 425 |
| `npm test --prefix server` | 212 | **236** |
| `rules_test` on the emulator | 209 | **214** |
| `firestore.rules` dry-run | compiles | compiles |
| `flutter build web --release` | succeeds | succeeds, and now without the font warning |

---

## The five High findings

### H1 — the daily cap counted the wrong day, and could mint points

**Confirmed.** `award.js` and `verify.js` both counted disposals matching
`createdAt >= today's UTC midnight` and then filtered for approved ones. That
counts submissions *created* today, not approvals *performed* today — and the
client chooses when to call `/verify`. Nothing opens the per-bin lockout until an
approval, so a user could bank ten pending submissions on Monday and verify all
ten on Tuesday: every call looked at Tuesday's window, found nothing in it, and
credited. **The cap was defeated by waiting.**

**Fixed** by re-anchoring to a server-written counter at
`dailyCaps/{uid}_{yyyy-mm-dd}`, incremented inside the approval transaction —
the shape `claimQuotas` has always used, and the reason that route was never
vulnerable. `createdAt` is no longer an input to the decision.

Also added: a `dailyCaps` rules block (read your own, written by nobody), and
`server/test/award.test.js`, which pins the regression directly — an
approval of a submission created in 2025 still trips today's counter.

### H2 — an unguarded `await` in `/config/points` could exit the process

**Confirmed.** Both handlers were `async` with no try/catch. Express 4 does not
await a handler's return value, so the error handler at the bottom of `index.js`
is dead code for async routes; Node then turns the unhandled rejection into an
uncaught exception and terminates. The Flutter client calls
`GET /config/points` routinely, because every award figure it displays depends on
the live policy — so one transient Firestore error on a launch-path read would
take the whole service down.

**Fixed**: both handlers wrapped and returning 503, plus `unhandledRejection`
and `uncaughtException` backstops so the *next* route added without a try/catch
degrades to a log line instead of an outage.

`uncaughtException` deliberately does not exit. The usual advice assumes a
supervisor that restarts in milliseconds and siblings that absorb the traffic;
here there is one instance with a 30–60 second cold start, and every wallet write
is inside a Firestore transaction, so staying up in a suspect state serves users
better than a guaranteed outage.

### H3 — a suspended administrator kept every privilege

**Confirmed, and it was the sharpest finding in the report.** `isAdmin()` read
`.data.role` and never consulted `status` or `suspendedUntil`, and the admin
branch of the `users` update rule had no self-edit guard. The exploit was one
document write: a suspended admin sets `status: 'active'` on their own record.
No server in the path. They could also change roles, promote a confederate,
resolve appeals and read every wallet in the meantime.

The audit was also right that the existing test named *"a suspended admin cannot
act as an admin"* proved nothing — it asserted a disposal create, which a
suspended *buyer* fails identically.

**Fixed** with two independent guards: `isAdmin()` now resolves the suspension
from the same single `userData()` read (so it costs no more than the role-only
version), and the admin branch requires `uid != request.auth.uid`. Five new rules
tests cover self-reinstatement, an active admin editing their own role, a
suspended admin acting on somebody else, admin *read* access, and — the other
half of the rule — an admin whose timed suspension has lapsed getting their
privileges back.

### H4 — no rate limiting, and `/verify` was repeatable on a pending document

**Confirmed.** `verifyDisposal` short-circuited only on an already-*decided*
submission. Anything flagged for review stays `pending` until an administrator
acts, and every repeat call in that window re-ran the whole pipeline — a
Cloudinary fetch, a fifty-document history query, and a **billed Groq vision
call**. No limiter existed on any route.

**Fixed** on both halves:

- `verifyDisposal` now returns the stored evidence when
  `hasCompletedVerification(disposal)` is true, rather than recomputing it.
- `server/src/rateLimit.js` — a per-uid fixed-window limiter applied to
  `/disposals/:id/verify` (20/hour), `/photos/*` (40/hour) and the write routes
  (30/minute).

Written rather than installed: this is one free instance with no shared store, so
a package would give the same in-memory behaviour behind a dependency and a
configuration surface. The limitation is stated in the file — **the counters are
per-process** — which is why nothing that decides a payout relies on them.

Keyed on uid rather than IP because mobile users share carrier NAT addresses, and
an IP limit would punish a neighbourhood for one person's behaviour. Eight tests.

### H5 — NFR-7 is not met: an offline submission fails rather than queues

**Confirmed, and only partly fixed — deliberately.**

Two blockers, both real. The photo upload is an HTTP POST that runs *before* the
Firestore write, so offline it throws and no document is ever created for the
offline queue to hold. And persistence was never configured anywhere, which
matters because mobile defaults it on and **web defaults it off**.

**Fixed**: persistence is now set explicitly in `main.dart`, so the two targets
behave the same and web gets read caching and queued writes.

**Not fixed**: the submission ordering. Writing the pending document first would
mean creating a disposal with no photograph — and `validDisposalCreate` requires
a trusted photo reference at creation, which is load-bearing (it is what keeps a
client from authoring a submission the server then has to trust). Reordering
means weakening that rule, which is a worse trade than the limitation.

So NFR-7's roadside-bin scenario stands as a **known limitation**, recorded in
the brief and in `main.dart` where somebody will actually read it. The audit's
advice applies: try it in airplane mode before the viva, so it can be described
accurately rather than discovered live.

---

## Medium and Low findings acted on

| Finding | Resolution |
|---|---|
| A relisted product escaped the suspension sweep permanently | **Own M3 bug.** The hide branch skipped anything already flagged, treating the flag as proof it was hidden — but the rules let a seller set `active` back to true while flagged. Now hiding selects on `active` alone |
| `verifyIdToken` without `checkRevoked` | Enabled. A deleted or disabled account previously kept working for up to an hour |
| 12 MB JSON parser ran before auth on every route | The token is now verified before the body is buffered, the 12 MB limit is mounted only on `/photos`, and everything else gets 64 KB. `req.method !== 'POST'` skips the gate so an OPTIONS preflight is not 401'd — which would have broken every web upload |
| Eight unbounded collection streams | All limited through a new `QueryLimits` class, which documents each cap and why it exists |
| `pageSize` implied a pagination mechanism that does not exist | Retired. The caps are named as caps |
| Raw `error.toString()` on three screens | Routed through the existing `friendlyErrorMessage()` — including the bin scanner, step one of the demo |
| Cart mutations failed silently | They threw nothing and changed nothing, so the button appeared to work. Now a typed `CartUnavailableException` with a sentence fit to show a buyer |
| A wallet error showed a confident zero balance at checkout | `asData?.value` collapses error and loading into the same null. New `spendableBalanceProvider` keeps them distinct, and checkout says which |
| Draft providers had no `keepAlive` under Riverpod 3 | Added to both. Their survival depended on frame timing, and losing one drops the photograph three screens in |
| Catalogue search re-queried on every keystroke | 300 ms debounce; the clear button still applies immediately |
| Seller photos skipped compression on a false premise | **Own M3 bug.** `flutter_image_compress_web` does resolve. Now on the same path as disposals — which matters most for EXIF: a seller photographing stock at home was publishing their coordinates |
| `settlementMethod` was write-only from the user's perspective | Now rendered on the order card, closing F4.8 |
| `suspendedAt` / `reinstatedAt` written but not parsed | Added to `UserModel`, so the audit trail can be displayed |
| Catalogue cap applied before multi-token narrowing | Not changed — correct at this catalogue size — but now documented in `watchCatalog` rather than left to be discovered |
| Stale `package-lock.json` (0.3.0 vs 0.4.0) | Regenerated. `npm ci` is the right install for Render and can refuse on the mismatch |
| `riverpod_annotation` declared with zero imports | Removed |
| Brief said "35 features"; the tables list 36 | Corrected |
| Brief said "no widget tests"; there are 25 | Convention restated to describe what is actually there |

---

## Where the audit was wrong

**`cupertino_icons` is not unused.** The audit inferred it from the absence of
any `CupertinoIcons` reference, which is true as far as it goes. But
`core/theme.dart` imports `package:flutter/cupertino.dart` for
`CupertinoPageTransitionsBuilder`, and that brings the `CupertinoIcons` IconData
class with it — Flutter's asset resolution then expects the font family. Removing
the package builds, and prints `Expected to find fonts for (MaterialIcons,
packages/cupertino_icons/CupertinoIcons)` on every build. It was removed, the
warning appeared, and it was put back with a comment explaining why it looks
unused and is not.

**`.DS_Store` is not committed.** `git ls-files` returns nothing for it. It
exists in the working directory and is correctly ignored.

---

## Findings not acted on, and why

- **`PATCHES 2.md` and the three one-shot `patch_*.py` scripts.** Real, and worth
  a tidy-up commit before the final push — but these are the author's files, not
  something to delete unasked.
- **The discount allocator diverges from its Dart mirror above 2^53.** Verified
  as reachable within the schema's own limits (20 lines × qty 20 × ৳1,000,000)
  and unreachable at any realistic price. No money is created or lost; the
  per-seller split would differ by ±1 taka. Left alone, and worth knowing the
  answer if asked.
- **The daily cap resets at 06:00 Dhaka time.** Kept UTC, and now documented as a
  decision rather than an accident: the weekly claim quota is UTC-anchored too,
  and having the two rate limits on different boundaries is a worse thing to
  explain than a stated 06:00 reset. It is a one-line offset if that call changes.
- **The router's guards have no tests.** Fair, and still true.
- **No localisation scaffolding (NFR-8).** Correctly assessed as not worth doing
  now. It belongs in the term paper's limitations section as a shortfall rather
  than being described as "structured for localisation".
- **No `startAfter` pagination (NFR-2).** The caps are the mitigation, and they
  are now named and documented as caps rather than page sizes.
- **Graceful shutdown, `helmet`, a readiness probe.** Worth doing; not done here.
