# Commit log

A running record of every change to this repository: the date, the time, and a
short message describing what changed and why.

Newest first. Entries dated before 2026-08-24 12:52 are backfilled from
`git log`; everything from that point on is written when the change is made.

**Format**

```
## YYYY-MM-DD HH:MM (+06) — <short title>
<one or two sentence maximum: what changed, and what it fixes or adds>
Files: <the areas touched>
Checks: <analyze / test results, when the change is verifiable>
```

---

## 2026-09-18 16:30 (+06) — The rollup kept one item's mass and dropped the rest

Last of the MEDIUM findings. Five already closed — storage rules exist and are
declared, `/passports/verify/` is App Check-exempt, both indexes are declared,
`resolveMembership` derives `orgWritable` from the organisation, and QA-2's five
named rules tests exist across four suites.

**Three were live, and the first is the most serious thing this triage found.**

**The period rollup dropped mass.** `update` is a plain object, and each figure
was written into it inside the loop over matches:

    update[`massMgByDistrict.${key}`] = increment(match.massMg);

A second match sharing that key does not add to the first — it REPLACES it,
because `increment()` is a sentinel rather than a running total and assigning
twice to one property keeps the last value. District is the worst case: every
match in a disposal comes from one bin, so they ALWAYS share the key. A bag
holding three of a producer's items contributed one item's mass to the district
breakdown, and looked entirely consistent doing it. Category and polymer
collide whenever two items share either, which is ordinary for a crate of the
same product. `uncertainMassMg` had it too.

These figures are printed on the Plastic Passport, so the loss was certified.

**No live data is affected.** Confirmed read-only against production: 0
attributions, 0 period rollups, 0 passports — 39 disposals, none attributed.
Nothing needs recomputing. The bug was reachable and never reached.

Four tests now cover multi-match disposals, including the cross-check an
auditor would actually make: the district total must equal the sum of the
attribution rows behind it. That is the assertion that would have caught this,
and it did not exist.

**The route-guard test silently dropped four routes.** Its parser ended each
chain at the first literal `(req, res)`, and the four `/photos/*` routes end in
`photoUploadHandler('claims')` — a factory. So they vanished from the table,
and the route before each of them swallowed their middleware into its own
chain, appearing to carry guards it does not have. Both directions wrong at
once, and the canary's `> 30` bound could never notice four going missing.
Replaced with a balanced-paren scan and an exact parsed-equals-declared
assertion. 89 became 93, and every existing guard assertion still passes — so
nothing had been passing on a borrowed guard.

**A catalogue test that could not fail.** `names no report Chokro cannot
produce` wrapped an `async` call in `expect(() => …).not.toThrow()`.
`buildReport` is async, so its `default: throw` — the exact case the test is
named for — arrives as a rejection and never throws synchronously. Now asserted
on the rejection, with a companion test proving the string it looks for is the
one a missing builder actually produces.

**MEDIUM is closed.** Of 45: 31 already fixed by earlier passes, 13 fixed
across these five triage sessions, 1 recorded with its reasoning (durable report
cursors, an EPR-34 determinism question rather than a pagination one).

Files: server/src/attribute.js, server/test/attribute.test.js,
server/test/eprRouteGuards.test.js, server/test/reportJobs.test.js,
docs/RECOVERED_AUDIT_FINDINGS.md
Checks: 1269 server tests (44 suites), 353 rules tests (10 suites) against the
emulator, 1176 Flutter tests. The rollup fix verified by mutation.
Remaining untriaged: 22 LOW.

## 2026-09-18 15:05 (+06) — Leaving a screen mid-save threw, in five places

MEDIUM triage, client side. Most were already closed — `_hydratedFor` replaced
the one-shot `_hydrated` latch, `compliancePositionProvider` guards
`detail.hasError`, the SDG view branches on all three `RateAbsence` values, the
carbon figure uses `CarbonEstimate.label` rather than a local `.round()`, the
uncertainty ceiling reads the server policy with the constant only as fallback,
`/auth/signout` revokes refresh tokens, and `_run` catches transport failures.

**Four were live.**

**`ref` after an `await`, with no `mounted` guard.** The finding named
`declaration_view.dart`. I checked the claim rather than taking it —
`WidgetRef` throws "This widget has been unmounted, so the State no longer has
a context", a real error and not a debug assert, confirmed on a minimal widget
in `test/ref_after_unmount_test.dart` before changing anything.

Then swept for the shape rather than fixing the one instance: **five call
sites**, four of them not in the finding — three admin oversight actions
(recompute, accuracy review, certificate revoke) and the sign-out in
`app_shell`. Leaving a screen while an action is in flight is ordinary, and the
work had already succeeded by the time it threw.

The sign-out one is the interesting one. Reading the error off `ref` after the
await threw on every SUCCESSFUL sign-out, because success is what unmounts the
shell. A failure leaves the user where they are, still mounted, which is
exactly when the message matters — so guarding costs nothing the method exists
to do. My first attempt captured the notifier and read `.state` instead; that
is `@protected` in Riverpod 3, and the analyzer said so.

**The dashboard could assert two gazette targets at once.**
`_ReportingPosition` read the target from `DateTime.now()` while
`CollectedMassCard`, directly below it, carries a period selector reaching back
twelve months. So "15% (obligation year 1)" could sit above a collected figure
from a month in year 2, whose target is a different number.
`obligationYearForPeriod` already existed for exactly this question and says so
in its doc comment — "which year does this reporting month belong to", as
distinct from "which year are we in at this instant".

**The target's disclaimer appeared only when there was no target.**
`targetIsNotAnAssessment` — "Chokro states the gazette target beside your
figure; whether it is met is the Department of Environment's finding, not ours"
— was rendered in the `missing` branch. It is written for the case where a
target IS on screen, and vanished at the moment the screen put the law's number
next to the producer's own. `_Fact` now takes a `note` shown with the value.

**A test that could not fail.** `carries no figures` asserted
`expect(passport.toString(), isNot(contains('0.95')))` and
`PlasticPassportModel` has no `toString()` override, so the compared value was
always `Instance of 'PlasticPassportModel'`. Now parsed with and without the
`figures` payload and compared field by field. A test that cannot fail is worse
than no test: it is a claim of coverage over the thing it does not check.

Files: lib/views/producer/declaration_view.dart,
lib/views/producer/producer_dashboard_view.dart,
lib/views/admin/admin_epr_oversight_view.dart, lib/views/shared/app_shell.dart,
test/ref_after_unmount_test.dart, test/compliance_position_test.dart
Checks: 1176 Flutter tests, 1262 server tests, analyze clean.
Remaining untriaged: 4 MEDIUM, 22 LOW.

## 2026-09-18 13:40 (+06) — Weighing a new product invalidated every certificate

MEDIUM triage across `index.js`, `producerAudit.js` and
`fontkitNullAnchorFix.js`. Most were already closed — the report download
re-checks the report's own `minRole`, `lastAttributionAt` is in
`projectForProducer`'s deliberately-absent list, `carried` is validated,
issuance pre-renders both editions, session age is capped, the digest covers
every displayed field, `listForOrg` orders by `sequence`, and `fontkit` is a
declared dependency.

**Three were live.**

**The chain head's digest was never checked.** Only `head.sequence` was
compared. The head stores a digest written in the same transaction as the entry
it points at, and a head contradicting the last surviving entry passed
verification silently. It is the cheap half of a partial cover-up: deleting the
tail and winding `sequence` back defeats the truncation check, but the attacker
also has to rewrite the digest, and a head still pointing at an entry that is
gone is exactly the trace this catches. Two fields to keep consistent is
strictly harder than one.

**A first verification superseded every certificate the organisation held.**
EPR-30 says a "RE-verified unit mass that changes a period already certified",
and `supersedeForMassChange` ran on every `setVerifiedMass` — so weighing a
BRAND-NEW product marked every currently-issued certificate for that
organisation `superseded`. Certificates in third parties' hands, invalidated
because a different product was measured for the first time. A first
verification replaces no earlier figure: there was none for an issued
certificate to have been computed from. `openRevisionInTransaction` now reports
`previousVerifiedUnitMassMg` and the route supersedes only on a real change —
re-setting the same mass is not one either, and spending every certificate's
status on a corrected note would teach everyone to ignore supersession.

**An outage told the holder of a valid invitation their link was dead.** The
catch block collapses every failure into `invalid_invitation` deliberately, so
a stolen link cannot enumerate organisations or invited addresses. That argument
does not cover a service outage, which is a fact about Chokro true of every
endpoint at that moment and learnable by calling any of them. The cost fell on
the genuine invitee: told to "ask for a new one", they invalidate the working
link they had, and the replacement fails the same way. `unavailable` now returns
503 and says the invitation is still valid.

**A new test file for the fontkit shim, and one thing it deliberately does not
claim.** The obvious discrimination test — count skips while shaping the
self-test string — cannot work: `পাসপোর্ট` reaches `applyAnchor` exactly once,
so a guard skipping EVERYTHING reports the same count as the correct one. I
measured that rather than assuming it, after writing the test and watching the
mutation survive. The test that does catch it shapes a nukta sequence and
asserts a real anchor was applied. The first test's comment now says what it
proves instead of what I had hoped it proved.

The shim still cannot detect marks placed in the WRONG position, only ones that
fail to shape. The module already states that and why — it needs a reference
rendering this project does not have — so it stays recorded rather than fixed.

Files: server/src/producerAudit.js, server/src/producerSkus.js,
server/src/index.js, server/test/producerAudit.test.js,
server/test/eprRouteGuards.test.js, server/test/fontkitNullAnchorFix.test.js,
docs/RECOVERED_AUDIT_FINDINGS.md
Checks: 1262 server tests (44 suites). All three fixes verified by mutation.
Remaining untriaged: 9 MEDIUM, 22 LOW.

## 2026-09-18 12:20 (+06) — The certificate stated a carbon figure and none of its caveats

MEDIUM triage, `passportPdf.js`: eleven findings, eight distinct. Six already
closed — the §6.7 boundary statements are on the page, `splitRuns`' neutral
branch asks both faces now, `absentRateSentence` tells a nil declaration from an
absent one, `heightOfFlow` measures across every face, the gazette target is
drawn in the no-rate branch, and `registerFonts`' recovery no longer breaks the
English edition.

**Two were live.**

**EPR-38's three caveats were on the screen and not on the artefact.** The spec
is unambiguous — "Three honest caveats must travel with it in the interface and
in every report" — and a certificate is the most report-like thing here.
`lib/core/carbon_math.dart` carried all three for the producer's own dashboard;
the document a regulator reads carried none of them. The boundary block's
"indicative ... not a verified carbon credit or offset" is EPR-39's no-offset
prohibition, a different point. All three now sit beside the figure in both
editions, because EPR-38 says "on the same screen, not behind a tooltip".

**The carbon figure was rounded unlike every other number on the page.**
`Math.round` prints whatever the arithmetic produced, so 51,234 kg printed in
full beside masses rounded to 51,200. `carbon_math.dart` states the rule for the
client — three significant figures, "because the factor is an estimate derived
from a different country's electricity mix, so a fourth digit would claim a
precision nothing in the chain supports" — and the certificate both overstated
the precision and disagreed with the producer's own screen over identical stored
inputs.

**A note on testing the caveats, because the obvious test does not work.**
PDFKit writes text as positioned glyph runs inside compressed streams, so "does
the page say UK-derived" is not a question the rendered PDF answers to a grep —
I tried, and inflating every stream finds no `Tj` operator to match against. A
regression would render perfectly, say nothing, and pass every render test. So
the decision is split into `carbonCaveatsFor` and asserted directly. Both
editions were also rendered to PDF and inspected by eye: the Bengali sets
correctly, no mojibake.

**The Bengali is mine and has not been reviewed by a native speaker.** It
renders — `splitRuns` refuses rather than emitting mojibake, and the coverage
sweep now names each sentence individually rather than the block — but
renderable is not the same as idiomatic, and this is a regulator-facing
document. Flagged rather than assumed.

**A correction to yesterday's entry.** I recorded that the certificate "says
nothing" about mass collected in undeclared categories. Rendering it showed
that is wrong: the By gazette category table lists every category's collected
mass against its declared mass and prints "not declared" where there is none —
880 kg of flexible packaging against "not declared", on the face of the
document. What is actually missing is only a summary line tying that to the
percentage. Much smaller than I recorded, and corrected in the findings doc.

Files: server/src/passportPdf.js, server/test/passportPdf.test.js,
docs/RECOVERED_AUDIT_FINDINGS.md
Checks: 1251 server tests (43 suites). Both fixes verified by mutation.
Remaining untriaged: 16 MEDIUM, 22 LOW.

## 2026-09-18 01:30 (+06) — A certificate for a company we had suspended

MEDIUM triage, `passports.js`: ten findings, seven distinct. Four already
closed — `supersedeForPeriod` has three production call sites now,
`canonicalPayload` carries producer identity, the collection rate was fixed in
the second pass, and the supersession query filters `status == 'issued'` so it
cannot strip a revocation.

**Three were live.**

**A suspended organisation could be issued a certificate.** EPR-47 makes a
suspended workspace read-only with "no new issuance", and
`requireActiveOrganization` enforces that on every producer route. Issuance is
an ADMIN route, so that middleware never ran, and `issuePassport` checked only
that the organisation document EXISTED — not its status. A suspended, closed or
never-approved company could be handed a Chokro-signed certificate that the
public endpoint reports as `issued`: the one artefact here that a third party
relies on without being able to ask us anything about it. Refused in the module
rather than as route middleware, so it holds for every caller rather than the
one route that exists today.

**A retry was a reissue.** Every call minted a fresh serial and superseded what
stood before it, so a lost response, a client retry or a double-click produced a
second certificate over byte-identical figures and marked the first
`superseded`. A third party holding the first then reads "superseded" from the
public endpoint — which says the evidence changed when nothing did, spending the
one signal this product asks outsiders to act on. `contentHash` is a pure
function of the figures, so identity was already decidable: an identical
standing certificate is now returned with `alreadyIssued: true` instead of being
replaced.

**A supersession could commit with nothing in the audit chain.** A
`batch.commit()` followed by a separate `audit.append()` — two commits, and the
second allowed to fail on its own, leaving a certificate marked `superseded`
with no record of who did it or why. Now one transaction: query, then the chain
head, then every write. `producerAudit.js` states the rule — an action that
could not be logged has not happened — and invalidating somebody's certificate
is not the operation to make an exception for.

**Two existing tests had to change, and that is worth stating.** Both reissued
with unchanged fixtures and expected supersession, which the idempotency guard
now makes a no-op. Their intent was to prove supersession works, so they now
move the figures between the two issuances — the realistic reissue. A test that
had been passing on the path it was not testing.

**One adjacent gap, recorded not fixed.** The certificate says nothing about
`collectedOutsideDeclarationMassMg` — mass collected in categories the producer
did not declare, excluded from the percentage. It is in `figures` and hashed,
just not printed, and disclosing it would tell a regulator the declaration is
incomplete. Left alone because it means new Bengali on a regulator-facing
certificate in the module with three prior font-handling bugs, which deserves a
deliberate change with reviewed wording rather than a line slipped into a
triage pass.

Files: server/src/passports.js, server/test/passports.test.js,
docs/RECOVERED_AUDIT_FINDINGS.md
Checks: 1238 server tests (43 suites). Both guards verified by mutation —
removing the active-organisation check fails 3, removing idempotency fails 2.
Remaining untriaged: 24 MEDIUM, 22 LOW.

## 2026-09-18 00:15 (+06) — Reports that did not say what they meant

Continued the MEDIUM triage into `reportJobs.js`: ten findings, two of them
duplicates. Four already closed — both index findings are covered by declared
indexes and by `firestoreIndexes.test.js`, and `localeCompare` survives only in
a comment explaining why it is not used.

**Four were live.**

**Chain-of-custody rows carried dates outside their own period.**
`attribute.js:205` derives the period from `decidedAt`, stored as
`disposalDecidedAt`; `createdAt` is merely when the document was written. A
disposal decided at 23:00 on the 30th and attributed minutes later exported
with October's date in September's report — and an auditor reconciling the
export against the period has to be able to tell that is not an error.

**SKU performance columns did not multiply out.** `units` and `massMg`
accumulated across every attribution while `unitMassMgUsed` and `skuRevision`
came from whichever was read first, so a mass re-verified mid-period (ordinary
under EPR-12) gave a row where units × unitMassMgUsed ≠ massMg. Now blanked,
with `unitMassVaried` / `revisionVaried` saying why — in the CSV columns too,
since the CSV is the edition a spreadsheet multiplies. A weighted average was
rejected: it reconciles, and it is a number that was never used to attribute
anything.

**The geographic CSV dropped its suppression notice.** With the k-anonymity
floor biting, `projectForProducer` returns an empty district map, so the CSV
was a column header with nothing under it — reading as "no geography
recorded", which `eprPeriods.js:485` says in as many words must never happen.
The JSON edition stated it; the CSV edition of the same report did not.
`serialise` now emits `payload.note` as `#` lines, read off the payload rather
than passed in, so a report that gains a qualification later cannot ship a CSV
without it. Inside the hashed body deliberately — a qualification excluded from
the hash can be stripped without invalidating it.

**The DoE annual return registered the wrong passports.** Fifty most recent
across all time, in a document reporting one registration year. Now filtered to
the twelve periods it covers.

**One recorded rather than fixed.** The job `cursor` is written `null` and
never advanced, so `resume` re-runs from the start. That is correct — the read
is idempotent and the output deterministic — but it does not help a period too
large for one instance lifetime, and durable cursors mean deciding what a
partially-read report means when rows changed between attempts (an EPR-34
question, not a pagination one). The header claimed the cursor worked; that
claim is corrected, because a comment describing a capability the code lacks
stops anyone looking for it.

**Two process notes, both mine.** I dropped `highConfidence`/`mediumConfidence`
from an object initialiser while editing it — `undefined += 1` is NaN, which
JSON renders as null — and an existing test caught it immediately. And two of
my first mutation checks survived: one because the fixture put both timestamps
on the same Dhaka date so the assertion could not tell the fields apart, one
because my mutation script silently failed to match. Both were my errors rather
than the code's; all four fixes now have tests verified to fail on reversal.

Files: server/src/reportJobs.js, server/test/reportJobs.test.js,
docs/RECOVERED_AUDIT_FINDINGS.md
Checks: 1229 server tests (43 suites).
Remaining untriaged: 31 MEDIUM, 22 LOW.

## 2026-09-17 23:20 (+06) — The producer could read its own audit log and not check it

Third triage pass over the recovered findings, starting with the four MEDIUM
ones in `firestore.rules` — the boundary that survives when the Node service is
bypassed.

**Three were already closed, by a stronger fix than any of them proposed.** All
three described the `producerSkus` client write path: a `hasOnly` allowlist that
could not match a server-created document, an authorisation chain with no notion
of a suspended tenant, and a `massStatus` lock the other two made unreachable.
The write path is now `allow create, update, delete: if false`. Nothing left to
get wrong — which closes the CRITICAL field-deletion finding at the same line too.

**One was live.** `producerAuditHeads` was `allow read: if isAdmin()`, and the
only verification endpoint was behind `requireAdmin`. So a producer could read
every entry of its own history and had no way to check any of it — and could
not detect a truncation at all, since truncation is only visible as a head whose
sequence runs past the surviving entries.

That contradicts the sentence the whole design rests on, in `producerAudit.js`:
tampering is "detectable, by anyone holding the log — including the producer
whose history it is". A tamper-evident log only the operator can check is a log
the subject is asked to trust, which is the arrangement the chain exists to
replace.

Both halves, because the producer needs both:

- **The head is readable by the organisation it belongs to.** Nothing new is
  disclosed — it holds `orgId`, `sequence`, `digest`, `updatedAt`, all of which
  the organisation already reads off its own entries. What it gains is the
  pointer to compare them against, which is the structural check it can make
  alone. Writes stay denied to everyone, administrators included.
- **`GET /epr/audit/verify`**, at `orgViewer`, scoped to the caller's own
  organisation from the membership and never from a parameter — there is no
  orgId in the path precisely so there is nothing to tamper with. Verifying a
  KEYED chain is impossible without the key by design, so this is the half the
  producer cannot do for itself.

`projectVerification` is an explicit allowlist, like every other client-facing
projection in the service, with a test asserting an added field does not reach a
producer by default. `keyed` travels with the verdict: the producer is the party
that would be disputing with the operator, so it is the reader it is least fair
to report "intact" to without saying what that proves.

Also corrected a misleading sentence in the findings doc, which said the
client-side Dart findings were unchecked. They were checked, and the two at
CRITICAL are closed — verified against the tree rather than taken on the doc's
word.

Files: firestore.rules, server/src/producerAudit.js, server/src/index.js,
server/test/producerAudit.test.js, rules_test/epr_tenancy.rules.test.js,
docs/RECOVERED_AUDIT_FINDINGS.md
Checks: 1221 server tests (43 suites), 44 tenancy rules tests, analyze clean.
Rule verified by mutation against the emulator: reverting the head read to
`isAdmin()` fails the member-read test and nothing else.
Remaining untriaged: 41 MEDIUM, 22 LOW.

## 2026-09-17 22:30 (+06) — App Check on the client, attesting before enforcement

The server has held `APP_CHECK_ENFORCED` since Phase A and the client had
nothing: `firebase_app_check` was not a dependency, no initialisation, no
`X-Firebase-AppCheck` header anywhere in `lib/`. Setting the flag today would
have 401'd every request from the app.

**The refactor I quoted was not needed.** I had reported 18 services each
building their own header and framed this as needing a shared API client
first. Re-checking: **zero** direct `http.get/post` calls exist — every network
call already goes through an injected `http.Client`, all 19 defaulting to
`http.Client()`. The injection point was already there. The duplicated
`Authorization` header is real but is not what blocks attestation.

So `AttestedClient extends http.BaseClient` adds the header in `send()`, and
the 19 defaults became `AttestedClient()`. Services keep their constructors and
their auth headers; every test that injects a fake keeps working untouched.

**Best effort here, authoritative there.** A request with no token is sent
WITHOUT the header rather than refused locally. The client is the wrong place
to decide whether attestation is required — the server holds the flag and is
fail-closed once set. Refusing here too would break the app against every
deployment that does not enforce, which is every local run, every emulator and
the whole of the rollout. Token failures are logged once per client, not per
request.

Activation never throws. Every failure mode is ordinary — no Play Services, a
simulator without App Attest, a reCAPTCHA key not yet provisioned — and none of
them should black-screen the app when the server will refuse the request with a
status that says so.

**Debug providers are gated on `kDebugMode`, and that is the property worth
pinning.** A release build attesting with a debug provider reports success,
satisfies an enforcing server and proves nothing — attestation any caller can
obtain is worse than none, because the console then says the control is on. Two
tests assert a release build gets `AndroidPlayIntegrityProvider` /
`AppleAppAttestWithDeviceCheckFallbackProvider` / `ReCaptchaV3Provider` and
never a debug one.

`test/attested_client_test.dart` scans `lib/` for a bare `http.Client()` and
for top-level `http.get/post`. That failure is invisible until the day
enforcement is switched on and then total for whatever service was missed —
and no service test can catch it, because the default is exactly what a fake
replaces. Verified by mutation.

Apple provider is App Attest WITH DeviceCheck fallback. Not for the version
floor (this app requires iOS 15; App Attest arrived in 14) but for a device
whose attestation Apple declines, an App ID without the capability, or Apple's
service being unreachable.

Files: pubspec.yaml, lib/core/attested_client.dart, lib/core/app_check_setup.dart,
lib/main.dart, 19 services/views, test/attested_client_test.dart,
test/app_check_setup_test.dart
Checks: 1173 Flutter tests, analyze clean.
Outstanding — console steps this code cannot perform, all required before
`APP_CHECK_ENFORCED=true`: register App Check per platform; a reCAPTCHA v3 site
key passed as `--dart-define=CHOKRO_RECAPTCHA_SITE_KEY=`; a registered debug
token for local runs; and for iOS, the App Attest capability on the App ID plus
`com.apple.developer.devicecheck.appattest-environment` in Runner.entitlements
— deliberately NOT added here, because adding it before the capability exists
breaks iOS signing with an unrelated-looking error.

## 2026-09-17 21:35 (+06) — A right whose only door was unmarked

Erasure requests are email-only by decision (16 September), and the app
contained no contact address anywhere. Four strings told people to "Contact a
3ZERO Admin" and named no way to do it.

**Two of the four are shown to somebody who cannot sign in.** A disabled
account never reaches a screen where an address could be found later, so an
unnamed contact there is not an inconvenience — it is the end of the road, and
the only one the product offered.

Address is `ceo@impact-sol.com`, held as `AppConstants.contactEmail` and
referenced everywhere: the sign-in error for a disabled account, the
`operation-not-allowed` error, the home suspension card, the profile
suspension notice, and a new *Privacy and contact* section on the profile
screen. Replaces `[DELETION_REQUEST_ADDRESS]` in the consent text, English and
Bengali.

**The Privacy section is not gated on `active`, unlike everything above it.**
Those are capabilities and are withdrawn on suspension. The right to ask what
is held about you, and to ask for it to be deleted, is not — and a screen that
hid the address exactly when somebody wanted to leave would be hiding it at
the worst possible moment.

Rendered as selectable text, not a `mailto:`. `url_launcher` is not a
dependency, and a tap that opens nothing — no mail client, a browser blocking
the handler — leaves someone exercising a right with no address and no way to
get one.

**The consent document said three places. There were four.** The fourth
(`home_view.dart:893`) lived in a widget no test touched, so counting by hand
missed it. `test/contact_address_test.dart` now scans `lib/` on every run for
the imperative phrasing, and separately asserts the address is never re-typed
as a literal — two literals is how the app and the consent text drift apart
about an address people have already been told to write to. Comments are
stripped first so the explanations at each call site do not read as uses.

Both assertions verified by mutation: reintroducing the phrase fails the first,
hard-coding the address fails the second.

Files: lib/core/constants.dart, lib/core/auth_errors.dart,
lib/views/home/home_view.dart, lib/views/profile/profile_view.dart,
docs/CHAMPION_CONSENT_LANGUAGE.md, test/contact_address_test.dart,
test/auth_errors_test.dart, test/profile_view_test.dart
Checks: 1155 Flutter tests, analyze clean.
Outstanding: `ceo@` is a role alias reaching one person. It is now the
data-protection contact of record and should become a monitored group inbox,
or an alias re-pointable without invalidating consents already given.

## 2026-09-17 20:40 (+06) — "The chain is BROKEN" on an organisation that never had a chain

With the index built, verification ran for the first time and reported the
wrong thing about both organisations in production.

`A. Munem` was created 2026-09-09, eight days before the log's earliest entry.
It has no entries and no head because it predates the audit log entirely.
`verifyChain` reported `intact: false`, and the card rendered that as **"The
chain is BROKEN — treat this organisation's history as unreliable and
escalate."** An auditor escalated twice over a non-event stops reading the
third one, which is the cost.

`intact` was a boolean carrying four situations, so everything that was not a
clean bill arrived on screen as tampering. A log longer than one 500-entry pass
did the same thing — latent today, wrong for the same reason.

**Four states now, because there are four situations:** `intact`, `broken`,
`noChain` (older than the log), `partial` (scan hit its limit). `intact` keeps
its exact former meaning, so every existing caller and test is untouched.

**The excuse is earned, not assumed.** `noChain` requires `AUDIT_LOG_EPOCH` —
an operator-asserted date, deliberately unset by default, with no fallback to
the log's own earliest entry. That fallback was the tempting one and it is the
trap: an insider who deleted an organisation's entries would move the apparent
start date later and manufacture the excuse for the deletion just performed.
Unset means empty chains stay `broken`, and the result names the missing
configuration rather than leaving it to be inferred from a result that looks
like an attack. Every branch that cannot PROVE the organisation is older —
no epoch, no organisation record, an unparseable `createdAt`, a creation date
at or after the epoch — answers false.

The client takes `chainState` as a raw string that only ever refines the
message when `verified` is false, so a state a future server adds falls through
to the strictest wording rather than a reassuring one. A test pins that, and
another pins that `chainState: 'intact'` alongside `verified: false` still
reads BROKEN — the boolean wins, not the string.

Verified by mutation: forcing the excuse to always apply fails 8 tests,
including the two pre-existing ones that guard the delete-everything attack.

Also confirmed read-only against production: the 11-entry chain is structurally
perfect (contiguous links, head matching) and its digests match neither plain
SHA-256 nor an empty-key HMAC — Render holds `AUDIT_CHAIN_KEY`, so the chain is
a genuine keyed HMAC and real evidence under SEC-12.

Files: server/src/producerAudit.js, server/src/viewAsOrganization.js,
lib/models/admin_oversight_model.dart,
lib/views/admin/admin_producer_detail_view.dart,
server/test/producerAudit.test.js, test/admin_producer_detail_view_test.dart
Checks: 1215 server tests (43 suites), 1146 Flutter tests, analyze clean.
Outstanding: set AUDIT_LOG_EPOCH in Render — unset, A. Munem still reads broken.

## 2026-09-17 19:20 (+06) — Four index directions pointing the wrong way, and a test that could not see direction

The History tab showed no chain card. Read-only query against production named
it in one line:

    FAILED_PRECONDITION: The query requires an index.

`listForOrg` runs `.where('orgId','==',x).orderBy('sequence','desc')`. The
declared index was `(orgId ASC, sequence ASC)`. Firestore composite indexes are
DIRECTION-SPECIFIC — an ascending index does not serve a descending order — so
the query failed, the provider errored, and the tab rendered its error state
rather than the card. I had guessed earlier that Firestore "usually" serves a
descending order from an ascending index. It does not, and the guess cost an
afternoon.

**Sweeping every query found four, not one.** Each declared in the exact
opposite direction from the query that needs it:

    putOnMarketVersions   version    query asc   declared DESC
    producerAuditLog      sequence   query desc  declared ASC
    skuRevisions          revision   query desc  declared ASC
    skuMassAudits         createdAt  query asc   declared DESC

Four for four is not coincidence — these were written from intuition about what
an index "should" sort by rather than from the queries. All four would fail in
production the first time anyone opened the screen behind them.

Added rather than corrected: both directions are genuinely in use for
`sequence` (verifyChain ascends, the timeline descends) and for `revision`
(one path descends, two ascend).

**`isCovered` matched field NAMES and ignored direction entirely.** It asked
whether an index mentioned the right fields, which every one of these did — so
all four read as covered while none of them worked. The parser now captures the
direction argument, defaulting to ascending exactly as Firestore does, and
coverage requires every ordered field to point the same way. Verified by
stashing the new indexes: the strengthened test fails on all four modules
without them.

**What the production read also showed:** two organisations exist, eleven audit
entries, and one head at sequence 11 — so `producerAuditHeads` was legitimately
recreated by organisation creation, as designed. The second organisation has no
head and no entries, which is worth a look but is not this bug.

Files: `firestore.indexes.json`, `server/test/firestoreIndexes.test.js`
Checks: 1206 server tests (43 suites), deploy dry run passes.

## 2026-09-17 17:10 (+06) — The "Their view" tab could never have worked

The producer detail screen showed three tabs and no content. The cause was a
method mismatch that had been there since Phase E shipped.

`admin_oversight_service.dart` called `GET
/epr/admin/organizations/{id}/view`. The server registers that route as
`app.post` — correctly, because opening a producer's workspace appends an audit
entry BEFORE it assembles anything (EPR-46), so it is side-effecting however
much it reads like a fetch. Express matched no GET route and answered 404 every
time.

**Both sides were tested and the seam between them was not.** The widget tests
override `organizationViewProvider` and never reach the service; the server
tests call the handler directly and never see the client's spelling of the
path. Each half was green while the feature had never once worked.

Found by curling the deployed routes unauthenticated and reading the status
codes: `/timeline` answered 401 — the route exists, you are not signed in —
while `/view` beside it answered 404. A 404 next to a 401 on two routes
registered in the same commit is the whole diagnosis.

**`clientServerRoutes.test.js` now checks the seam.** It extracts every
`app.<verb>('<path>')` from the server and every `_authed<Verb>('<path>')` from
`lib/services`, normalises `:orgId` and `$orgId` to the same token, and asserts
that each client call reaches a route that exists BY THE METHOD IT USES. Two
guards on the scanner itself: it asserts it found both sides, so a broken regex
cannot pass over an empty list; and it COUNTS the paths it cannot parse rather
than skipping them, because a scanner that silently ignores what it cannot read
claims coverage it does not have — which is how the original bug survived.

Swept the whole boundary while the scanner was written: 92 server routes, 43
client calls, exactly one mismatch. The one remaining unparseable path was a
ternary inside a string literal in `loadTimeline`; the query is now built on
the line above, because a path a scanner cannot read is a path nothing checks.

Files: `lib/services/admin_oversight_service.dart`,
`server/test/clientServerRoutes.test.js` (new)
Checks: 1206 server tests (43 suites), 1142 Flutter tests, analyze clean.

## 2026-09-17 15:30 (+06) — A root `Focus` that stopped the app booting, and undeployable indexes

Two failures found by actually running the things, not by reading them.

**The idle guard crashed the app on its first frame.** `IdleSessionGuard`
detected keystrokes with a `Focus` widget, and in `main.dart` that widget wraps
`MaterialApp.router` — above the Navigator, above the View. Flutter's focus
traversal then sorted descendants that had not been laid out:

    RenderBox was not laid out: RenderSemanticsAnnotations NEEDS-LAYOUT
    ... focus_traversal.dart sortDescendants → findFirstFocus

Nothing rendered. Seven widget tests passed throughout, because every one of
them mounts the guard INSIDE a MaterialApp — which is not how the application
uses it. A control written this morning to protect an unattended desktop
instead prevented anyone reaching a desktop at all.

Replaced with `HardwareKeyboard.instance.addHandler`, which is what this always
wanted: a signal that somebody is at the keyboard, taking no part in the focus
tree and claiming nothing about where input goes. The handler returns false —
observed, never consumed — or it would swallow every keystroke in the product.

Two tests now mount the guard in its PRODUCTION shape, wrapping MaterialApp
rather than living inside one. Verified against the stashed buggy version:
they fail there, so they catch the regression rather than passing vacuously.

**The index file was correct and undeployable.** `firebase deploy` refused it:

    HTTP Error: 400, this index is not necessary, configure using single field
    index controls

Firestore maintains a single-field index for every field automatically and
rejects a composite that declares only one. Four had accumulated
(`organizations.tradeNameKey`, `organizations.legalNameKey`,
`attributions.disposalId`, `producerSkus.orgId`), each backing a
single-equality query the automatic index already serves.

The deploy aborts on the first rejection, so those four were blocking the other
63 — none of which had ever reached production either. One stale line was
holding back every index in the project.

The suite already checked that every composite QUERY has an index. Nothing
checked the reverse — that every declared INDEX is legal. Four tests close it:
no index with fewer than two real fields, `__name__` last where present, a
collection group and fields on every entry, and no duplicates (a duplicate is
accepted and then ignored, so it reads as coverage that is not there). The
deploy dry run now passes.

**Also diagnosed, no code change:** `flutter run -d chrome` picks a random web
port, and the server's `ALLOWED_ORIGINS` names `localhost:5000` only — hence
"Failed to fetch" against a live and healthy API. `--web-port=5000`. Confirmed
by preflighting three ports against production: 5000 allowed, 5002 and 61234
refused.

Files: `lib/core/idle_session.dart`, `test/idle_session_test.dart`,
`firestore.indexes.json`, `server/test/firestoreIndexes.test.js`
Checks: 1142 Flutter tests, 1202 server tests, analyze clean, deploy dry run
passes.

## 2026-09-17 14:05 (+06) — Deferring Cloud Storage: make the absence explain itself

Firebase Storage needs the Blaze plan, which is deferred. So the question
became what breaks, and the answer is narrower than it sounded: **only
`reportJobs.js` touches Cloud Storage.** Plastic Passports are rendered and
streamed directly and never go near it, so the flagship deliverable is
unaffected. What is blocked is EPR-33's eight report types and the audit pack.

**The preflight was checking the wrong thing.** `assertStorageConfigured`
tested that `FIREBASE_STORAGE_BUCKET` was SET, and its comment promised it
"fails loudly and names the variable the operator has to set". The variable IS
set — `chokro-30887.firebasestorage.app` is a perfectly good name — and the
bucket behind it does not exist. So the preflight passed, the job enqueued,
reported `running`, and died inside a GCS call with a message naming a bucket
the operator had never heard of and no mention of the remedy.

`assertStorageExists` now asks whether the bucket is THERE, at enqueue time,
where the module already intended to refuse. Three states, three answers: the
variable unset names the variable; the bucket absent says Storage has not been
set up, that it needs the Blaze plan, and that everything else including
passports is unaffected; an unreachable bucket says so and says to try again,
because a network failure must not reach a producer as "your Chokro instance
is misconfigured".

Cached on success only. A bucket that exists does not stop existing, so one
round trip per process is enough — and a negative result is deliberately NOT
cached, because somebody is about to go and create it and should not have to
redeploy to be believed. `resetStorageCheck` is exported for tests: a
process-wide cache is invisible to a suite, and without it the first test to
confirm the bucket silently exempts every test after it.

**An unbounded-read audit, run before recommending billing.** 78 collection
reads in `server/src`; 71 carry an explicit `limit()` or `count()`. Six of the
remaining seven are bounded by data shape (`in` chunks of thirty, one user's
devices, one disposal's attributions). The seventh is the seller-suspension
sweep in `listings.js`, Admin-triggered and bounded by one seller's catalogue.
There is no runaway-read exposure in this codebase, which is the thing worth
knowing before switching on per-read billing.

Files: `server/src/reportJobs.js`,
`server/test/{reportJobs,zz_scratch_year}.test.js`
Checks: 1198 server tests (42 suites). `zz_scratch_year.test.js` is a leftover
scratch file that still runs in the suite — worth deleting or promoting.

## 2026-09-17 11:40 (+06) — Triaging the recovered findings: an overstated percentage on every certificate

Every CRITICAL and HIGH finding from the 127 recovered yesterday, checked
mechanically against the current tree. Most no longer describe the code. Four
were live, and one of those is the most serious defect found in this project.

**The collection percentage on the certificate was overstated.** The numerator
summed every gazette category Chokro collected; the denominator summed only the
categories the producer DECLARED. A producer who declared rigid and had
flexible collected too got those kilograms in the numerator with nothing in the
denominator to answer for them.

On this module's own fixture that is 27.8% against an honest 22.9%, and against
the year-3 target of 30% those are different stories — printed on a document a
regulator reads. EPR-24 makes the target a percentage of what was placed on
market, declared per gazette category; a ratio across two different category
sets is not that percentage.

Both sides now cover the same set. The excluded mass is reported as
`collectedOutsideDeclarationMassMg` rather than discarded: it is real material,
and the reason it cannot enter the ratio is an incomplete declaration, which is
a fact worth surfacing rather than hiding inside a flattering number. Both new
figures are in `canonicalPayload`, so a reissue with a different declared set
cannot hash the same; stored certificates are unaffected because the hash is
computed once at issue and never recomputed.

**An existing test had pinned the inflated value** — `expect(f.collectionRate)
.toBeCloseTo(5000000000 / 18000000000)`. Two agents raised this independently
and neither was believed, because nothing failed. Third time in this project a
test has pinned a bug.

**`carried` was unvalidated on a resumed recompute.** Those running totals
arrive in the request body and seed the figure that IS the independent check on
the incremented counters — so whoever ran the check chose what it started from.
Now an allowlist of keys with whole non-negative values, rejecting rather than
clamping, because a negative mass clamped to zero is a wrong figure that looks
deliberate. Malice was never required: a client resuming with stale state did
the same thing silently.

**`listJobs` leaked the private bucket path.** The single-job route stripped
`storagePath` with a spread; the list route never knew the rule existed. One
allowlist projection at the source, because a rule enforced per route is a rule
the next route will not know about.

**`localeCompare` made report row order runtime-dependent.** Every sort sat
under a comment promising "byte-identical across runs". Demonstrated rather
than argued: on real Bangladeshi district names the default locale sorts Latin
before Bengali and `bn` sorts Bengali before Latin — same rows, different
order, different `contentHash`, on a deploy where nothing but `LANG` changed.
Now code-point order, which is uglier for a reader and identical everywhere.

Also closed by checking: the §6.7 boundary statements ARE on the certificate
(the first grep missed their wording), the audit digest does cover
actorName/actorRole/ip/userAgent, `supersedeForPeriod` is called from
production, and transaction read-before-write ordering is correct.

Files: `server/src/{passports,eprPeriods,reportJobs,skuShortlist,index}.js`,
`server/test/{passports,eprPeriods,reportJobs}.test.js`,
`docs/RECOVERED_AUDIT_FINDINGS.md`
Checks: 1195 server tests (42 suites), analyze clean. MEDIUM/LOW and the
client-side Dart findings remain untriaged and are listed in the doc.

## 2026-09-17 08:15 (+06) — npm advisories, the SEC-9 session framework, and 127 recovered findings

**The npm advisory refresh, blocked since August, ran.** Its severity ranking
inverted the real picture: the one HIGH was `js-yaml` under `jest`, a
devDependency that never ships, while all 11 moderates were production.

`npm audit fix` then did something worth not accepting. It DOWNGRADED gaxios
6.7.1 → 6.3.0 to escape an advisory range — and that bought nothing: gaxios was
flagged transitively through `uuid`, and `uuid@9.0.1` stayed in the tree either
way. The downgrade removed gaxios from the REPORT while leaving the vulnerable
code installed, at the cost of four minor releases. Reverted; fixed `qs`
properly with an `overrides` pin to ^6.16.0, which reaches the copy inside
body-parser that express's own bump leaves behind — the one parsing request
bodies.

11 → 8, and the 8 are one advisory: uuid's missing buffer bounds check in
v3/v5/v6 when `buf` is provided. Chokro does not use uuid at all, and the only
call anywhere in the cloud libraries is `uuid.v4` — not an affected function.
Clearing it needs firebase-admin 14, a major bump, which is now a planned
upgrade rather than a security response.

**The audit backlog was not eight findings. It was 127.** Recovered from the
workflow journals, which persist every agent's structured return value —
`commits_m.md` had preserved only the sentence "eight lower-severity findings,
still unverified". Written to `docs/RECOVERED_AUDIT_FINDINGS.md` so they cannot
evaporate again. Mechanical triage says most are closed by later fix passes.
Two were not.

**`appCheck.js` — the verification endpoint was not App Check exempt.** The
urgent one, because `APP_CHECK_ENFORCED` is release-blocking and was about to
be turned on. The verification URL is printed into every certificate, read by
someone holding a piece of paper with no app to attest with, in a
content-hashed document that cannot be reissued with a corrected URL —
enforcement would have invalidated every certificate already issued. And worse
than reported: `EXEMPT_PATHS` is exact-match while every serial is a different
string, so adding the route to that list would have matched nothing while the
deploy log claimed the exemption was in place. Fixed with a prefix list.

**No `storage.rules`, and no `storage` target in `firebase.json`.** The bucket
holding every organisation's report artefacts — including the row-level
chain-of-custody export — had no declared posture at all. Added, denying every
client path. Also discovered while validating it: **Firebase Storage has never
been initialised on the project**, so the whole report suite would fail in
production. Console action, raised for the user.

**SEC-9, split by adversary rather than built as one thing.** The absolute
session limit bounds a STOLEN CREDENTIAL, where the client is the attacker, so
it is enforced on the server from `auth_time` — 8 hours for producer and admin
against 30 days for a Champion, which is what makes "shorter than the consumer
app's" mean anything, since the consumer app had no limit to be shorter than.
The idle timeout defends an UNATTENDED DESKTOP, where the client is not the
attacker and the device is what is at risk, so it runs on the client; enforcing
it server-side would mean a write on every request in the product to defend
against someone who is not making them.

Two bugs the tests caught rather than the code review. The guard armed its
timer only from `ref.listen`, which fires on CHANGES — so every cold start into
an existing session, the common case, armed nothing and the control did nothing
at all. And a rebuild must not count as activity: a screen with a stream would
otherwise hold an empty office signed in forever, so that is now its own test.

Files: `server/{package.json,package-lock.json}`,
`server/src/{appCheck,auth}.js`, `server/test/{appCheck,auth}.test.js`,
`storage.rules` (new), `firebase.json`,
`docs/RECOVERED_AUDIT_FINDINGS.md` (new), `lib/core/idle_session.dart` (new),
`lib/main.dart`, `test/idle_session_test.dart` (new)
Checks: 1171 server tests (42 suites), 1140 Flutter tests, analyze clean.

## 2026-09-17 04:20 (+06) — The SEC-1–SEC-14 review, and three real findings

Three jobs: widget tests for the disclosure screen, the SEC penetration
review, and the audit backlog.

**Disclosure widget tests (20).** The screen had model tests only — the same
gap I had criticised in Phase E. Writing them exposed a testability bug I had
introduced: `LocationService` was constructed inline, so the case the whole
record depends on — the Admin REFUSING to share their location — could not be
exercised. Made injectable.

**Audit backlog: both named findings tested by rendering, one confirmed.**

`heightOfFlow` under-measuring a mixed-script flow: NOT a defect. It measures
the whole string once per face and takes the max, which is a real mechanism for
under-counting if each face measures the other's scripts as zero-width. 432
combinations of locale, weight, size and width were rendered and compared
against the prediction. None under-measured; the worst case over-reserves by
77pt, which is the safe direction. Pinned as a property test.

A corrupt Bengali font breaking the English edition: **CONFIRMED, and worse
than reported.** BOTH of `registerFonts`' recovery paths were dead code. Each
catch returned a Latin-only body reading `latin`, `latinBold` and
`latinCoverage` — declared with `let` AFTER the Bengali block, so at the point
of the early return they are in the temporal dead zone. The recovery threw
`Cannot access 'latin' before initialization` instead of recovering, and both
comments described a degradation that had never once happened. Nothing caught
it because the tests covered DETECTION of a broken font and never RECOVERY.
Fixed by hoisting the Latin setup above every early return, and by making the
pdfkit shaping self-test degrade rather than throw — an English certificate
uses no Bengali face, so a Bengali face that cannot shape is not a fact about
it.

Two false starts worth recording. A standalone probe said the English edition
was fine, because a cold process fails `fontAvailable` and takes the early
path; the bug only appears warm, when fontkit's by-path cache holds a healthy
handle and pdfkit reads corrupt bytes from disk — a deploy swapping assets
under a running server. And my first test CORRUPTED THE REAL FONT ASSET, which
broke `passports.test.js`: Jest runs files in parallel workers and the font is
shared state on disk. Rewritten to exercise the recovery path directly, which
is the defect; the corruption was only its trigger.

**SEC review — two findings.**

SEC-14: `GET /epr/config/policy` is `requireAuth` only and returned the WHOLE
policy document to every authenticated account — a Champion, a producer's
viewer, anyone with a login. That document holds every detection threshold in
the system. Three of SEC-14's own controls are thresholds, and a control whose
threshold the adversary can read is one they can sail just under;
`anomalyTargetMargin` is the sharpest, being the margin by which clearing a
gazette target is treated as suspicious. The client reads exactly two fields
from this route. Now an explicit allowlist for non-Admins, built the way
`projectForProducer` is so a threshold added later cannot leak by default.
`massToleranceFraction` and `massAuditSampleSize` are deliberately included
despite being gameable: an audit result whose terms a producer cannot check is
one they cannot contest, which is the worse failure.

SEC-9: "sign-out revokes refresh tokens server-side, not just locally" was not
implemented — `revokeRefreshTokens` appeared nowhere but a comment. Firebase's
client `signOut()` left the refresh token, and any ID token minted from it,
valid for up to an hour. Now `POST /auth/signout`, and the fix is total rather
than partial because `requireAuth` already verifies with `checkRevoked: true`,
so revoking invalidates outstanding ID tokens too. Never allowed to block the
local sign-out: a user who taps sign out must end up signed out with no
network, so failures are swallowed and reported, not thrown.

**SEC-1 and SEC-2 verified and hold.** `requireOrgRole` reads live membership
on every request rather than trusting a claim, and `firestore.rules` never
reads `request.auth.token.orgId`. Membership revocation is immediate
server-side, which is the failure mode SEC-2 names.

**Still open from SEC-9:** no idle timeout and no absolute session lifetime.
Both are required and neither exists — and the spec wants them "shorter than
the consumer app's", which has none either. Raised rather than built: it is a
session framework, not a patch, and it should be designed rather than bolted
on at the end of a review.

Files: `server/src/{passportPdf,eprPolicy,index}.js`,
`server/test/{passportPdf,eprPolicy}.test.js`,
`lib/services/session_service.dart` (new),
`lib/controllers/{auth_controller,disclosure_controller}.dart`,
`lib/views/admin/admin_disclosure_view.dart`,
`test/{admin_disclosure_view,session_revocation}_test.dart` (new)
Checks: 1159 server tests (42 suites), 1132 Flutter tests, analyze clean. The
font asset was verified unmodified after the corruption experiments.

## 2026-09-17 01:30 (+06) — Disclosure as a guarded power: step-up auth, a written reason, and an open register

The disclosure endpoints existed and only curl could reach them. They are now a
tab in the EPR oversight console, with the controls asked for: a password gate,
a recorded declaration, and time, address, device and location on every access.

**Where the password goes: nowhere near Chokro.** The client re-authenticates
against Firebase, which refreshes `auth_time` in the ID token; the server reads
that claim and refuses anything older than five minutes. This service never
receives, forwards or stores a password and there is no code path that could.
Two details that would have made it fail silently: `reauthenticateWithCredential`
updates the session but NOT the cached ID token, so `getIdToken(true)` is
mandatory or the step-up succeeds on the client and is refused on the server;
and the client's unlock window is thirty seconds SHORTER than the server's, so
the screen asks again slightly before the server would refuse — an expired
unlock discovered after writing a declaration is a declaration written twice.

**A reference number says which request; it does not say why.** So a written
declaration is required — a sentence, not a keystroke — and it is read back on
the register by somebody who was not there. It goes into the tamper-evident
chain summary verbatim, not only into the readable row.

**Location is asked for, not taken, and a refusal is recorded AS a refusal.**
Never a blank: "would not say" and "could not say" are different things to read
six months later, and the model keeps `denied` and `unavailable` apart all the
way from `LocationOutcome` to the register row. A declined location does not
block the disclosure — that would make the control bypassable with a system
setting and would punish an Admin for a browser preference. A "granted"
location whose coordinates are out of range is downgraded rather than stored,
because a malformed pair renders as a pin in the Gulf of Guinea and reads as a
real place.

**Recorded twice, on purpose.** The audit chain is tamper-evident and is why
this is evidence; it is also a hash-linked list of summary strings and a poor
thing to read. `disclosureLog` is the readable half. A register write failure
does NOT fail the disclosure — the chain entry has already committed, so
refusing at that point would leave an audit entry for a resolution that never
ran. The screen says the register row is missing rather than hiding it.

**The register needs no unlock.** An Admin checking whether a colleague's
access was proper must not face the same barrier as the access itself.

**A latent trap found on the way.** `firestoreIndexes.test.js` mapped
`HEAD_COLLECTION` to 'auditChainHeads'; the real constant is
'producerAuditHeads'. Harmless today — heads are reached by `.doc(orgId)` only
— but the first `.where()` anyone added there would have been validated against
a collection that does not exist and passed without an index. Fixed, with the
reason recorded next to it.

Files: `server/src/disclosure.js`, `server/src/index.js`,
`server/test/disclosure.test.js`, `server/test/firestoreIndexes.test.js`,
`firestore.indexes.json`, `firestore.rules`,
`lib/models/disclosure_model.dart`, `lib/services/disclosure_service.dart`,
`lib/controllers/disclosure_controller.dart`,
`lib/views/admin/admin_disclosure_view.dart` (new),
`lib/views/admin/admin_epr_oversight_view.dart`,
`test/disclosure_model_test.dart` (new)
Checks: 1146 server tests (42 suites, +22), 1109 Flutter tests (+17), 346 rules
tests, 67 indexes validate, analyze clean.

## 2026-09-16 23:45 (+06) — Erasure requests stay by email, which exposed a missing door

**Decision: no self-service deletion request.** A Champion emails; an Admin
runs the flow. Recorded in `CHAMPION_CONSENT_LANGUAGE.md` §5.5 as a decision
rather than left sitting as an outstanding gap.

Defensible scope — a human reading each request catches the ones that are
really something else, and the volume does not justify a flow yet. But it makes
something release-blocking that was not before: **the app contains no contact
address anywhere.** Grepped for it: no support screen, no `mailto`, no
published email. The only "contact" string in the product tells a suspended
user to "Contact a 3ZERO Admin" without saying how.

So the consent draft now names the route explicitly in both languages, because
a right whose only door is unmarked is not a right anyone can exercise — and a
consent that says "you can ask us" without saying where reads as an assurance
rather than an instruction. `[DELETION_REQUEST_ADDRESS]` is a deliberate
placeholder: it must be a monitored inbox, not a personal one, because it
becomes the data-protection contact of record.

Added reviewer question 6: the PDPA may require the erasure request route to be
as accessible as the one used to collect the data — which here was two taps
inside the app. If it does, email alone will not hold and the self-service flow
becomes mandatory rather than optional. Worth knowing before the decision
hardens.

Files: `docs/CHAMPION_CONSENT_LANGUAGE.md`
Checks: no code changed. Bengali re-verified NFC-clean, both deletion
paragraphs read back and confirmed parallel.

## 2026-09-16 23:10 (+06) — The deletion flow an Admin can actually run

`accountDeletion.js` existed and nothing could reach it but curl. Same gap the
disclosure module has. This closes it for deletion.

**The retained list is shown BEFORE the button, and first.** An Admin deleting
an account is acting for somebody who is not in the room and will be asked
afterwards what happened to their data. A deletion flow that shows what it kept
only on the outcome screen delivers that knowledge after the one moment it was
useful. So the dialog opens on "What is kept", then "What is removed", then the
button.

**Contested retentions are marked as Chokro's position.** `RetainedCategory`
carries a `contested` flag from the server, and the dialog renders it as a
label plus a sentence telling the Admin to say these are retained and why —
not that they were deleted. An Admin answering "will my disposals go?" needs to
know which half of their answer is settled law and which is decision 9.

**A partial deletion never renders as a clean one.** The server's 207 reaches
the screen as "Partly deleted" with the failed steps named in error tone, and
`DeletionOutcome.complete` treats an ABSENT field as incomplete — a missing
field must never read as reassurance here. Tested both ways.

**Deletion sits behind an overflow menu, not beside Suspend.** Suspension is
reversible and routine; erasure is neither. A one-tap-away red button next to
one an Admin presses often is how the wrong one gets pressed. This also left
the existing Suspend interaction untouched, so nothing already depending on it
moved.

The dialog is not dismissible by tapping outside: at the confirm step a stray
tap should read as neither "cancel" nor "go ahead".

Files: `lib/models/account_deletion_model.dart`,
`lib/services/account_deletion_service.dart`,
`lib/views/admin/account_deletion_dialog.dart` (new),
`lib/controllers/admin_users_controller.dart`,
`lib/views/admin/admin_users_view.dart`,
`test/account_deletion_dialog_test.dart` (new, 10 tests),
`docs/CHAMPION_CONSENT_LANGUAGE.md`
Checks: 1092 Flutter tests pass (+10), analyze clean, 1124 server tests pass.

## 2026-09-16 21:30 (+06) — Account deletion: the half of an erasure request nobody disagrees about

The consent draft promises a Champion can ask to be deleted. There was no such
path anywhere in `lib/` or `server/src/` — the only `deleteUser` call in the
codebase is an invitation rollback.

**Why this could be built while decision 9 is still open, when `retention.js`
refuses to delete anything.** Four answers are on the table and they disagree
completely about disposals. They agree entirely about the account: every one of
them has `users: purge`. A name, an email, a profile photograph and a push
token have no compliance role under any reading — they are not evidence of
anything a certificate claims. So this module does the half they share and
touches nothing they dispute, and returns the retained list so nobody has to
infer it.

**The user document is tombstoned, not deleted.** Retained records reference
the uid — `disposals.userId`, orders, transactions. Deleting the document turns
every one into a dangling pointer, and a dangling pointer does not read as
"this person asked to be erased". It reads as corruption, which invites
somebody to go looking for the missing record and makes the erasure less final
rather than more. A tombstone answers the question instead.

**The order of operations is the load-bearing detail.** Identity first, then
the sign-in, then the incidentals. A run that dies after step one leaves a
nameless account with a working login, which re-running fixes. The reverse
order leaves a named account nobody can reach, which is the worst of both. A
test pins the order rather than trusting the code to keep it.

**Partial failure is never reported as success.** Cloudinary being down must
not leave the name in place, so each step is caught and named rather than
thrown; `complete` is false whenever anything failed and the route answers 207
rather than 200. A deletion reported as done with a silent partial failure is
how somebody is told they were forgotten when they were not. `auth/user-not-
found` is treated as success in disguise — the outcome asked for is that the
account is unreachable, and it already is.

Admin-triggered, matching every other destructive job here (§3.3 has no
scheduler). The self-service request flow is the remaining half of the
promise, and both docs now say so rather than claiming the right is honoured.

Files: `server/src/accountDeletion.js`, `server/test/accountDeletion.test.js`
(new, 17 tests), `server/src/index.js` (plan + execute routes),
`docs/CHAMPION_CONSENT_LANGUAGE.md`, `docs/RETENTION_SCHEDULE.md`
Checks: 1124 server tests pass (42 suites, +18).

## 2026-09-16 20:15 (+06) — The lawful-disclosure path, and Chokro's proposed answer to decision 9

The producer's chain-of-custody export replaces each disposal id with a
per-organisation HMAC, which is what makes the export releasable at all. But a
pseudonym Chokro could not reverse made the export **unauditable**: if the DoE
pointed at a row and asked for the evidence, nothing in the codebase could
answer. `server/src/disclosure.js` is that answer and is the only path that
undoes SEC-3's de-identification on purpose.

Shaped around three refusals. **A regulator reference has no default** — a
disclosure without a recorded reason is not a disclosure, it is a lookup tool
over pseudonymised data, which is the thing SEC-3 exists to stop somebody
building. **The audit entry is written before the resolution runs**, the way
`viewAs` records a view before assembling one; a test asserts that a resolution
which cannot be recorded reads nothing at all. **Naming the person is a second
endpoint with its own audit action**, because most regulator questions are
"did this collection happen" and answering one must not hand over a person as a
side effect.

**A bug I wrote and caught before it could matter.** The reverse lookup has to
try the unkeyed pseudonym too, for exports generated before `AUDIT_CHAIN_KEY`
was set. I implemented that as a plain SHA-256 — but `reportJobs.pseudonym`
falls back to an EMPTY STRING key, not to a different algorithm, so the unkeyed
form is still an HMAC keyed `':<orgId>'`. The two digests differ completely.
The symptom would have been Chokro telling a regulator that a genuine row is
unknown. Found by testing the two implementations against each other rather
than by reading them, and there are now three tests pinning them together
because drift here is silent and catastrophic.

**The index test caught the new composite query** (`attributions: orgId ==,
disposalId ==`) before it could become a production FAILED_PRECONDITION. Added.

**Decision 9 now has a proposed answer, recorded as proposed.** Chokro's
position: refuse erasure of a disposal record outright — it is the transparency
the scheme rests on — while account data stays erasable and the mapping is kept
solely for lawful disclosure. That is a fourth option none of the three in the
retention schedule covered, and it sharpens the question for counsel
considerably.

Two things stated alongside it rather than glossed. Retaining the mapping makes
the exported rows **pseudonymised, not anonymised**, so they remain personal
data in most readings — Q5 becomes more central under this position, not less.
And the right to erasure is not absolute but is also not Chokro's to disapply:
a company may rely on an exemption, not declare a right inapplicable. The
schedule's dispositions were deliberately NOT changed to match, because writing
the preferred answer in before counsel confirms it is the substitution the
module exists to prevent.

The consent draft's deletion paragraph promised severing, which was never
chosen. Rewritten in both languages to say plainly that disposal records stay —
a less comfortable thing to ask someone to agree to, and the honest description
of what the system does. Bengali re-verified NFC-clean.

Files: `server/src/disclosure.js`, `server/test/disclosure.test.js` (new, 21
tests), `server/src/producerAudit.js` (two audit actions),
`server/src/index.js` (two routes), `firestore.indexes.json`,
`docs/DATA_FLOW_MAP.md`, `docs/RETENTION_SCHEDULE.md`,
`docs/CHAMPION_CONSENT_LANGUAGE.md`
Checks: 1106 server tests pass (41 suites, +22), 66 indexes validate.

## 2026-09-16 18:40 (+06) — Three deployment answers, and the bin/date risk formally accepted

**EPR-33 bin/date floor: declined.** The recommendation in `DATA_FLOW_MAP.md`
§6.1 was to suppress `binId` on (bin, date) groups below the k-anonymity floor
in the chain-of-custody export. The answer was no, on the ground that it
changes the contents of a regulator-facing report.

So the promise came out instead of the gap being closed. The Champion consent
draft had said *"where very few people have used a bin, we hide the location
details"*, which was only ever true of the aggregate district breakdown and
never of the row-level export. **Removed in both English and Bengali**, and
replaced with a plain statement that bin and date are included. Bengali
re-verified NFC-normalised with no replacement characters after the edit — the
third time in this project that check has been worth running.

§6.1 now RECORDS a decision rather than repeating a recommendation, and says
what was traded: the remaining controls bound who receives the export and how
often, not what it discloses. Counsel gets a new Q6 — whether the PDPA accepts
disclosure where minimisation was available and declined is a different
question from the one a mitigated system would ask.

**PUBLIC_BASE_URL set to `https://chokro.onrender.com`** in `server/.env`, with
a comment saying why it cannot be wrong. It had been mistaken for a marketing
domain; it is the address of the service that answers
`GET /passports/verify/:serial`, printed into a PDF that leaves Chokro. Still
needs setting in Render's own environment — a local `.env` does not reach
production.

**AUDIT_CHAIN_KEY was set, and that has a consequence nobody had written
down.** `computeDigest` switches between plain SHA-256 and HMAC on whether the
key is present, so every entry written before the key was set now recomputes to
a different digest. Verified by running both paths against one entry: the
digests differ. Any chain with pre-key history will now verify as BROKEN — a
false alarm on the one control that must never cry wolf. Flagged to the user;
the fix depends on whether production holds real entries yet.

Files: `docs/DATA_FLOW_MAP.md`, `docs/CHAMPION_CONSENT_LANGUAGE.md`,
`server/.env`
Checks: no code changed, so no gate run. Bengali verified NFC with the removed
sentence absent from the whole file.

## 2026-09-16 17:05 (+06) — Widget tests for the Phase E Admin screens, and two bugs they found

The five-tab oversight console and the producer detail screen shipped with no
widget test at all. `admin_oversight_model_test.dart` covered the models only.

**The tests are all about absence, because that is what these screens are for.**
A model that faithfully holds `null` and a screen that draws it as `0%` is
still a screen telling an Admin an unverified year is clean. So: precision
below the sample floor renders the server's stated reason and never the
flattering 100%; a platform with no periods renders no percentage rather than
0%; coverage reports the TOTAL never-checked count rather than the length of a
bounded list; a mismatch shows both figures with neither presented as the
truth; an unwalked hash chain reads "not checked" rather than "broken".

**Two real bugs in the issuance register, both found by writing the tests
rather than by reading the code.**

First: the empty branch ran BEFORE the truncation check and discarded it. A
bounded read that came back empty told an Admin "Nothing has been issued yet"
— a positive false claim, on the one screen whose own comment says a silent
truncation "would be the worst possible answer to which certificates are
affected by this fault".

Second: the empty state ignored the active filter. With `revoked` selected and
nothing revoked, the screen said "Nothing has been issued yet", which is false
whenever anything has been issued, and is reassurance about a question nobody
asked. The anomaly queue already got this right; this tab did not.

**I checked the assertions rather than trusting them.** Dumping the rendered
text found that the truncation test had been passing against the non-empty
branch only — which is how the first bug surfaced. The read-only tint and the
unchecked-variance row were verified the same way (alpha 0.18 behind the whole
tab; the row renders "Never checked", not "0 kg").

Files: `test/admin_epr_oversight_view_test.dart` (new, 13 tests),
`test/admin_producer_detail_view_test.dart` (new, 9 tests),
`lib/views/admin/admin_epr_oversight_view.dart`
Checks: 1082 Flutter tests pass (+22), analyze clean, 1084 server tests pass.

## 2026-09-16 15:20 (+06) — SEC-13: the three deliverables that do not need counsel

SEC-13 names four things required before launch. I had been calling the whole
requirement blocked on legal counsel. Re-reading it, three of the four are
engineering work and only the durations and the erasure-versus-compliance
tension are a lawyer's.

**EXIF (deliverable 3) was already done** — `keepExif: false` at every capture
path, Cloudinary stripping again on transform. And the stronger clause, "EXIF
is stripped on the served derivative", holds vacuously on the producer path:
verified by inspection that `passportPdf.js`, `passports.js` and `reportJobs.js`
contain **no image handling at all**. No photograph reaches a producer by any
route.

**The data-flow map** (`docs/DATA_FLOW_MAP.md`) enumerates every producer-facing
route, what crosses, what is withheld, and the public verification surface.
Writing it turned up one thing worth acting on: the k-anonymity floor is applied
to the aggregate district breakdown but **not to the chain-of-custody export**,
which hands a producer one row per attribution carrying `binId` and `date` with
no floor — the exact "single bin, single day" shape SEC-3 names as isolating an
individual. Flagged for the spec author as a change to EPR-33 rather than made
unilaterally: it alters a report's contents, and an auditor who expects a bin
column would read a silently absent one as an error.

**The retention module inverts this codebase's usual rule about absence.**
`eprPolicy.js` falls back to documented defaults because a verification that
fails when nobody has opened the policy screen is the worse failure. Retention
cannot work that way — a wrong duration either destroys evidence behind an
issued certificate or keeps personal data past its basis, and both are the harm
the schedule exists to prevent. So there are **no default durations**, an
unconfigured collection **throws**, a malformed stored value reads as unset
rather than being clamped into range, and `planExpiry` reports `unconfigured`
and a null count rather than a count of zero — an unset schedule and an empty
collection must never render alike.

**No executor, deliberately.** Nothing in Chokro deletes on a retention basis,
and a test asserts the module exports no such function. Until open decision 9
is answered, `sever` and `purge` are indistinguishable guesses about the same
record; `disposals` is the case in point.

**What makes the legal question tractable:** an attribution holds no Champion
identifier. It holds `disposalId`, a foreign key into `disposals`, which holds
the uid. So the retained compliance record is about packaging and is personal
only by way of a link that can be cut — which is a third option SEC-13's
framing does not consider. `erasureImpact(uid)` measures that collision per
Champion, so counsel answers a question with numbers on it rather than in the
abstract.

**My own completeness test caught four collections I had missed** — `orders`,
`carts`, `products`, `donations`. Reading the spec had not found them; scanning
the source for `.collection('x')` did. The scan strips comments first, which is
the third time in this project that has been necessary.

**The consent draft** (`docs/CHAMPION_CONSENT_LANGUAGE.md`) turned up two
things before the wording: there is no consent surface in `lib/` to update at
all, and the app is English-only while its users are not — so a Bengali version
is a precondition of the text meaning anything, not a follow-up. Three sentences
in the draft are ahead of the code and each is marked: the location-hiding
promise depends on closing the gap above, the retention wording depends on Q3,
and "nothing left that points to you" is true only if severing is what erasure
turns out to mean.

Files: `docs/DATA_FLOW_MAP.md`, `docs/RETENTION_SCHEDULE.md`,
`docs/CHAMPION_CONSENT_LANGUAGE.md` (all new), `server/src/retention.js`,
`server/test/retention.test.js`
Checks: 1084 server tests pass (40 suites, +36 new). Bengali verified NFC-
normalised with no replacement characters. No Dart changed.

## 2026-09-16 09:45 (+06) — The Admin console for Phase E

Seven server surfaces that existed only as API endpoints now have screens.

**The information architecture came from one surviving agent.** I ran a
workflow to map the existing Admin UI and propose an IA; it hit the session
limit and six of seven agents died. The one that completed was the navigation
mapper, and it settled the question on its own:

  Home is the real admin hub — a grid of EXACTLY TEN ActionCards, and the only
  place all ten admin screens are reachable. Six of them have no navigation
  chrome at all, just a "back to home" button.

  Admin detail is a DIALOG, not a route. Across all ten screens there are two
  `context.push` calls. There is no `/admin/:orgId` precedent anywhere.

  `badgeFor` is a hardcoded switch over Firestore STREAM counts. Every Phase E
  count is REST, so a badge needs a new provider shape rather than a new case.

So: **one new card, not five.** Seventeen cards would be unusable, and five more
chrome-less screens would make every move between two oversight surfaces
home → card → screen. The five cross-producer surfaces are one activity — is
what Chokro publishes defensible — and an investigation moves between them
constantly, so they became tabs on `/admin/epr` with ONE period selector shared
across them. An Admin investigating September who switches from anomalies to
accuracy is still investigating September.

**One new precedent, set deliberately: `/admin/producers/:orgId`.** View-as is a
whole read-only dashboard and a timeline is a long scroll; neither fits the
dialog convention, and both are inherently about one organisation. Reached from
the producer list, which already exists — and available whatever the
organisation's status, because the moment an Admin most needs a producer's
record is usually the moment it has just been suspended.

**Every model here is about ABSENCE.** The server refuses to invent a figure it
has no basis for, and a client that parsed null into zero would undo all of it
in one line. The damage is asymmetric and worth spelling out:

  A blank on a reconciliation screen reads as "checked and fine". So a
  never-checked period reports a NULL variance, and the screen has three states
  rather than two — agrees, disagrees, never checked.

  A zero on an accuracy panel reads as "recognition is never right". So
  precision below the sample floor renders the server's stated reason, not a
  figure and not a dash.

  A dash in a variance column reads as "no change". So a first filing says
  "nothing to compare against" in words.

**`isSafeReadOnlyView` is checked in the service, before the screen renders.**
EPR-46 requires the view to be read-only and visually distinct. The payload
asserts `readOnly`, `impersonation: false` and a capabilities block; if a future
server change ever sent a writable payload down that route, the view refuses
rather than quietly offering an Admin a write affordance under a producer's
identity. A payload with the field MISSING is treated as unsafe — the assertion
has to be present to count.

The read-only tint runs behind the whole tab rather than sitting in a banner,
because a banner scrolls away and the moment an Admin has most likely forgotten
whose screen they are on is after a scroll.

**Four surfaces require a reason, and all four reuse
`showRejectionReasonDialog`** — which already enforces a minimum length and
returns trimmed-or-null. The anomaly queue offers two buttons rather than one:
"innocent — dismiss" and "real — actioned", with a line under them saying why
both exist. Collapsing them would make the queue's own history useless for the
question an auditor asks.

**A partial recompute is reported as partial.** The server's recompute is
resumable, so a large period needs more than one pass — and a partial pass's
"variance" compares a full counter against a fraction of the rows. A console
that ignored the cursor would report that as a result.

Files: lib/models/admin_oversight_model.dart,
lib/services/admin_oversight_service.dart,
lib/controllers/admin_oversight_controller.dart,
lib/views/admin/{admin_epr_oversight_view,admin_producer_detail_view}.dart,
lib/views/admin/admin_producers_view.dart, lib/views/home/home_view.dart,
lib/routing/router.dart, test/admin_oversight_model_test.dart
Checks: 1060 Flutter tests (up from 1035), 1047 server, analyze clean.

---

## 2026-09-16 08:20 (+06) — Phase E server-side complete: view-as, timeline, audit pack

EPR-44, EPR-46 and EPR-33's audit pack. Everything in Phase E except retention,
which needs counsel.

**EPR-46's whole content is a prohibition.** "There is no impersonation — no
Admin action is ever taken under a producer's identity, because an audit trail
that cannot distinguish the two is not an audit trail."

The tempting implementation is a flag on `requireOrgRole` letting an
administrator through. A dozen lines, and it would destroy the property the
audit chain exists for: every subsequent write would be indistinguishable from
the producer's own, and Chokro could no longer answer "did the producer file
this, or did we?" — the first question anyone asks about a disputed figure.
`requireOrgRole` refuses administrators on purpose; `viewAsOrganization` is a
separate path that reads and never writes.

**It shows the producer's view, suppressions included.** Every figure comes
from `eprPeriods.projectForProducer` — the same projection the producer's own
route uses, k-anonymity floor and all. An Admin is usually looking because the
producer phoned about a figure, and a second Admin-flavoured code path would
drift exactly when it mattered, with the Admin insisting the screen says one
thing while the producer reads another. An Admin needing the unsuppressed
districts has the reconciliation console; this view answers a different
question.

**The audit entry is written before the data is assembled**, and a failure to
write it refuses the request. Logging on success would mean a failed read of a
customer's compliance position leaves no trace — which is exactly the read
somebody would want to leave no trace.

**One real bug, found by its own test.** `verifiedTimeline` checked
`verification.ok`, and `verifyChain` returns `intact`. So the chain always read
as broken. Fixed, and the fix carries `producerAudit`'s own point through: an
unkeyed chain is tamper-evident against anyone WITHOUT write access and is not
evidence against the insider SEC-12 names, so the export says which it is rather
than printing "intact" and overstating the control.

**A ZIP writer rather than a dependency.** The audit pack is one artefact
containing several documents and EPR-33 asks for a ZIP. Stored (uncompressed)
entries need no deflate, which removes the part of the format that is genuinely
easy to get wrong; what remains is a CRC-32, three fixed-layout records and
offset arithmetic.

The argument only holds because it is verified: `zip.test.js` extracts every
fixture with the real `unzip` binary rather than asserting byte patterns, and
has a canary that fails if `unzip` is unavailable — a silently skipped
verification reads as one that happened. It round-trips Bengali and binary
content, and refuses beyond ZIP64's bounds rather than emitting a file that
looks fine and is silently truncated.

One bug found immediately: `0o100644 << 16` for the Unix permission bits
overflows to a NEGATIVE number, because JavaScript's `<<` is a signed 32-bit
shift. `writeUInt32LE` refused it outright, which is the good outcome — a
writer that had silently accepted it would have produced files an extractor
creates unreadable.

**Every entry in the pack carries its own SHA-256, in the manifest.** A pack is
the artefact most likely to be forwarded, split up and re-sent, so a recipient
holding three of its files needs a way to confirm they are the three Chokro
produced. The job's content hash covers the manifest, and the manifest covers
everything else — hashing the ZIP bytes directly would be equivalent today and
would break the moment the container changed.

The boundary statements are their own file for the same reason: a pack gets
split up, and the statements have to survive being separated from the reports
they qualify.

**Phase E's remaining item is retention (SEC-13), which needs legal counsel.**
The spec says so and names the question: what does a Champion's deletion request
mean for a producer's already-issued certificate. Everything else in Phase E is
built server-side; none of it has a screen yet.

Files: server/src/{viewAsOrganization,zip,reportJobs,index}.js,
server/test/{viewAsOrganization,zip,reportJobs}.test.js,
firestore.indexes.json
Checks: 1047 server tests (up from 1002), 346 rules, 65 indexes validate,
analyze clean. Every ZIP fixture extracted with the system `unzip`.

---

## 2026-09-16 06:50 (+06) — The reconciliation console and the issuance register

EPR-48 and EPR-47. Both turned out to be mostly assembly over engines that
already existed — with one real gap underneath.

**The accuracy audit has been filling since Phase C and nothing ever resolved
one.** `attribute.js` has been sampling high-confidence matches into
`attributionConfirmations` for EPR-17's standing audit since Phase C. There has
never been a path to review one, so the precision figure EPR-17 says to publish
in report methodology has never been measurable — and the methodology section
said only that recognition is imperfect, which is true and is not a figure.

`resolveConfirmation` closes that. Three decisions inside it:

  A VERDICT IS NOT A CORRECTION. Marking a high-confidence match incorrect does
  not reverse the attribution. Reversing on one reviewer's read would make the
  accuracy audit a second, unaccountable attribution path — removing mass with
  no reason recorded against it. Reversal stays its own act, with its own
  reason and its own audit entry.

  `unclear` IS A VERDICT, NOT A SKIP. A photograph too dark to judge is a real
  outcome, and folding it into either bucket would bias precision in whichever
  direction the reviewer felt generous. It is excluded from the ratio and its
  share is reported — a high figure there says the photographs are the problem,
  not the model, and that is a different fix.

  THE LOW-CONFIDENCE QUEUE IS NOT THE SAMPLE. Those matches were never
  attributed; a reviewer confirming one is describing a near-miss, not the
  precision of what Chokro reported. Mixing them would measure a different
  thing and call it the same name.

**Precision is published; recall is refused.** EPR-17 names "precision/recall",
and only one is observable. The sample is drawn from what the model CLAIMED, so
the denominator is known and precision is measurable. Nothing in this system
knows what was in a photograph the model did not report, so recall is not —
measuring it would need every sampled disposal exhaustively labelled.

`accuracySnapshot` therefore returns precision, the size of the sample it rests
on, and an explicit `recallAbsenceReason`. It returns NULL precision below a
30-sample floor: "100% over three reviewed matches" is not a measurement, and a
methodology section is precisely where an unsupported number does the most
damage — it is the section a reader turns to in order to decide how much to
trust everything else.

**The reconciliation console reads flags nothing had ever read.** QA-3 requires
a recompute mismatch surfaced rather than silently corrected, and
`storeRecomputeResult` has been recording them faithfully. A recorded mismatch
nobody looks at is the same as no check at all.

The overview separates matched, mismatched and NEVER-CHECKED, and the third is
the one that matters: "how much of this has anyone verified?" is the question an
auditor asks, and it cannot be read off a list sorted by variance. The count and
the total mass are reported even though the list itself is bounded. A
never-checked period reports a null variance rather than a zero — zero means
"checked and agreed", and conflating them is how an unverified year looks clean.

**The issuance register answers Chokro's question rather than a producer's.**
`listPassports` says what one producer holds. This says what is STANDING, across
every producer — which is the question the day a systemic fault is found, and
one that cannot be answered by querying each producer in turn without something
being missed. It carries the headline figure and the content hash so a fault can
be scoped without opening every PDF, shows the trade name the certificate
CARRIES rather than a live read, and says when it has truncated.

The Admin supersede handle is scoped to one organisation and period, requires a
reason, and supersedes rather than revokes — the distinction is not cosmetic:
superseding says the figures have moved on, revoking says the certificate should
never have been relied on, and a model fault is the first.

Files: server/src/{reconciliation,passports,reportJobs,producerAudit,index}.js,
server/test/{reconciliation,passports}.test.js, firestore.indexes.json
Checks: 1002 server tests (up from 968), 346 rules, 64 indexes validate, analyze
clean.

---

## 2026-09-16 05:40 (+06) — Phase E begins: the anomaly queue

EPR-45's six detectors, as an Admin queue. Nothing here blocks anything — the
requirement says "an Admin queue rather than an automatic block", and a scan
writes findings that a person reads.

**The queue's failure mode is noise, not error.** A queue that fills with
findings that have an ordinary explanation is one the reader clears without
looking, and at that point Chokro believes it is watching and is not. So most of
the design — and most of the test file — is about what does NOT fire:

  A SKU needs three periods of history. With one prior period the "trailing
  average" is that period, so any growth reads as a multiple of it, and a
  product whose first month was a pilot and second was a launch would fire every
  time. That is the most ordinary event in the dataset.

  A brand needs four bins before a bin's share means anything. With two, the
  leading bin has half the mass by arithmetic.

  Confidence drift is measured against a SKU's OWN baseline. Recognition is
  genuinely harder for a transparent wrapper than a printed bottle, so a SKU
  that has always been 60% medium-confidence is not drifting — it is a hard
  SKU, and flagging it every period would be noise forever. The detector is also
  one-sided: recognition improving is not an anomaly.

  The target-edge detector needs BOTH a narrow clearance and a late filing. A
  producer that meets its target comfortably is doing the thing the scheme
  exists to encourage, and flagging success would be perverse. The signal is the
  coincidence: the denominator is the producer's own figure, and filing it once
  the numerator is nearly known is the one moment a small change to it decides
  whether the target is met.

**Median and IQR, not mean and standard deviation.** The unit-mass comparison
set is a whole gazette category, which contains genuine extremes — a 20-litre
water jar sits beside a 250 ml bottle. A mean and a standard deviation are both
dragged by exactly those outliers, so the test would weaken the more skewed the
category is. A test asserts the two disagree on real data.

**The thresholds start loose, deliberately.** All seven are in `config/eprPolicy`
per the requirement, and every one is a guess until there is a year of
Bangladeshi data. A queue that starts quiet and is tightened is usable from day
one; a queue that starts noisy has taught its reader to ignore it by the time
anyone tunes it.

**Two behaviours the queue lives or dies on.** A finding's id is a digest of
what it IS — organisation, period, detector, subject — so a re-scan updates it
in place rather than duplicating it, and a dismissal survives. An Admin who
decided a concentration was a bottling plant should not have to decide it again
every time somebody triggers a scan. The threshold is deliberately excluded from
the digest, so tuning policy does not resurrect every dismissal.

**One detector names a person, and that shapes the access rules.**
`accountConcentration` reports a Champion's uid, because a single account
farming one brand is a real pattern and catching it requires looking at
accounts. So `eprAnomalies` is Admin-only in `firestore.rules`, with the READ
denial mattering more than the write denial — and for two reasons. SEC-3,
because the finding names an individual. And because telling the subject of an
investigation what triggered it is how the next attempt avoids it: a producer
who learns Chokro flags a filing within three days of close simply files on the
fourth.

Writes are denied to administrators too. A finding is written by the scan in the
same breath as the audit entry recording that the scan ran; one a client could
author is one an insider could author to manufacture a pretext.

**A closed finding is dismissed or actioned, never just closed.** Collapsing
them would make the queue's own history useless for the question an auditor
actually asks — how many of these turned out to be real. A reason is required
either way (SEC-12).

**The comparison set crosses a tenancy boundary, deliberately.** Unit masses are
compared against the whole gazette category across producers, because one
producer's catalogue is not a distribution. It is read Admin-side, never
projected, and only a median and two quartiles reach a finding — no producer
learns another's unit masses.

Files: server/src/{anomalyMath,anomalies,eprPolicy,producerAudit,index}.js,
server/test/{anomalyMath,anomalies,firestoreIndexes}.test.js, firestore.rules,
firestore.indexes.json, rules_test/epr_passports.rules.test.js
Checks: 968 server tests (up from 903), 346 rules tests (up from 337), 58
indexes validate, analyze clean.

---

## 2026-09-16 04:15 (+06) — The audit backlog, verified by testing rather than reading

The six findings the third pass raised and never verified, checked empirically.
Four were real. Two of them were availability bugs that would have taken down
certificate generation entirely.

**A status banner drawn shorter than its own text.** `heightOfFlow` measured
mixed-script text in whichever face carried the most characters and described
the result as an estimate "generous by a line rather than short by one". That
was wrong and measurably so: a mostly-Bengali status line whose single longest
run happened to be a Latin serial measured 41.7pt where the Bengali face gives
57.2pt — short by more than a line.

The consequence is not a page break in the wrong place. `drawStatusBanner`
draws a coloured rectangle of exactly that height and writes into it, so the
border came up short and a revocation reason spilled past it — on the one
element of the certificate whose job is to be impossible to miss. It now takes
the maximum over the faces the string actually uses, which cannot be short. A
single-face string still measures exactly, which is the common case.

**A truncated font file broke every certificate, including Latin-only ones.**
`fontAvailable` compared file size against a floor. Truncating
`NotoSansBengali-Regular.ttf` to 60,000 bytes — comfortably over the 50,000
floor — made BOTH editions fail with
`Cannot read properties of undefined (reading 'offsets')`, which names nothing
an operator can act on. A partial upload or a truncated deploy is exactly how a
font file goes wrong.

Worth recording why a bare `openSync` would not have caught it either: fontkit's
open is lazy and succeeds on the truncated file. The failure arrives when
something reads a table, which was mid-render. `loadFont` now reads `numGlyphs`
— which comes from `maxp`, so reaching it proves the table directory parsed —
and caches the handle, so each face is parsed once per process rather than once
per certificate.

A face that fails this is treated as ABSENT, which puts it on the path that
already has a correct answer: the English edition renders, the Bangla edition
refuses by name, and an English edition whose producer data contains Bengali
refuses with the message that already existed for that case.

**A shim failure took down English certificates that needed no Bengali.**
`fontkitNullAnchorFix.install` throwing meant Bengali shaping was broken, which
is not a reason to refuse a Latin-only certificate. Caught, logged, and treated
as "no Bengali face".

**A revocation reason with its sentences run together.** Newline and tab were
stripped outright, so `"…the September batch.\nSee case 4417."` printed as
`"batch.See case"`. They are still not drawn — this renderer lays text out
itself — but a word boundary is information where a zero-width space is not, so
they become spaces, and runs collapse so a paragraph break does not print a gap.

**Two findings did not survive.** The claim that `install()` verifies only
structure was already addressed by the functional self-test added in the
previous pass. The claim about fontkit's `applyLookup` returning true and
skipping remaining subtables is true of the code but unreachable with the
bundled faces, whose `abvm` lookup has a single subtable — worth revisiting only
if a face with more is ever bundled.

Files: server/src/passportPdf.js, server/test/passportPdf.test.js
Checks: 903 server tests (up from 894), 1035 Flutter, analyze clean. The banner
under-measurement, the truncated-font failure and the run-together sentences
were each reproduced before the fix and verified after it.

---

## 2026-09-16 03:25 (+06) — Two omissions closed, and a wider font

Clearing my own gaps before Phase E.

**EPR-43's threshold was never in config.** I had reported the variance and
left the highlighting to a console that does not exist yet, which is not what
the requirement asks for: "a declaration that moves 60% against the previous
period **without a note** is either a business change or a manipulation and
either way an Admin should see it." 60% is the spec's own number, not an
engineering default — I had simply not added it.

`listForReview` now returns `flagged` and `flagReasons` alongside the raw
variance. Three details that follow from reading EPR-43 rather than skimming it:

  The threshold is in policy, not in code. The right figure is a judgement
  about Bangladeshi seasonality that will be revised once there is a year of
  filings — Ramadan and the monsoon move beverage volumes a long way, and a
  threshold that flags every producer every year is one an Admin learns to
  ignore.

  "Without a note" is part of the test. A producer that explained a real
  business change has already answered the question the flag exists to ask.

  A note suppresses the FLAG, not the FIGURE. The variance and its reasons are
  still reported, so a reviewer can see the move and disagree.

**A wider Latin face, which turns refusals into certificates.** Bundled Noto
Sans (569 KB) in place of pdfkit's built-in Helvetica.

Helvetica is an AFM font encoded through WinAnsi — about 220 characters — and a
character outside that set is not substituted or flagged, it is reinterpreted.
That was the root of the mojibake found three times in this module. Noto Sans
covers 3,748 glyphs, and pdfkit subsets an embedded face, so a Latin-only
certificate carries only the glyphs it uses.

What now renders that previously REFUSED OUTRIGHT — the producer could not be
issued a certificate at all:

  Cyrillic and Greek legal names.
  Latin Extended: `Łódź`, `Šumava`, `Çelik`.
  U+2010, the hyphen a word processor substitutes for `-`. `Coca‐Cola
  Bangladesh Ltd.` pasted out of Word was affected, which is not an exotic case.
  U+20B9, the rupee sign. U+02BC, common in transliterated names.

Coverage is now answered by asking the font rather than by a hardcoded WinAnsi
table — a property of the file on disk rather than of a list somebody has to
remember to update. Helvetica remains the fallback if the file is missing, with
the table for that path, because refusing would mean no certificates for anybody
where the Bengali case refuses only one edition.

`CO₂e` is written with the real subscript again. It had been an ASCII 2 because
neither face had U+2082; Noto Sans does, and `splitRuns` routes the character to
it even mid-Bengali-run. The test that banned `₂` outright was pinning a
limitation that no longer exists, and now checks every fixed string through the
real routing rule instead.

Also bundled `NotoSansBengali-Bold.ttf`, which the renderer had always looked
for and never found — Bengali headings were set in the regular face.

**Still refused, and now a smaller list:** CJK, Arabic, Devanagari and Thai.
Each needs its own multi-megabyte face and none is worth it until a real
producer needs one.

**One assertion corrected to the measured truth.** I wrote a test asserting the
Bengali-only coverage gap was now empty. It is not: 14 Vedic accent marks
remain, which Noto Sans Bengali carries because Bengali script is sometimes used
to write Sanskrit. The three that mattered — U+2010, U+20B9, U+02BC — are gone.
The test now asserts that, and that every survivor is a Vedic mark, which keeps
the routing rule honestly load-bearing rather than decorative.

Files: server/src/{eprPolicy,declarations,passportPdf}.js,
server/assets/fonts/{NotoSans-Regular,NotoSans-Bold,NotoSansBengali-Bold}.ttf,
server/test/{declarations,passportPdf}.test.js
Checks: 894 server tests (up from 882), 1035 Flutter, analyze clean. Both
editions rendered and inspected: a U+2010 legal name, a Cyrillic trade name, a
U+02BC attester and a subscript CO₂e all print correctly.

---

## 2026-09-10 07:20 (+06) — Third audit pass: nine more findings, two of them in the fix

The third pass hit the session limit hard — 13 of 16 agents errored and NO
verifier ran, so the workflow reported `confirmed: 0` while having raised 17
findings. I verified the serious ones by hand, empirically, which for this
module is the stronger method anyway.

**Two of them were in the fix I had just written.**

**A hole in the new coverage check.** `splitRuns` asked only the Bengali face:
if it had a glyph, the character joined whichever run was in progress — usually
Helvetica. Measured: 17 code points the bundled Bengali face covers and WinAnsi
does not, printing as mojibake with no error. The worst is **U+2010 HYPHEN**,
which word processors substitute for `-`, so `Coca‑Cola Bangladesh Ltd.` pasted
out of Word was affected; also U+20B9 RUPEE SIGN and U+02BC, common in
transliterated names. It now asks both faces and routes to whichever can draw
the character. Verified: zero remaining holes across the whole BMP range, both
editions.

**An operational trap the refusal created.** The renderer now refuses
unrenderable text — but issuance never checked, and issuing SUPERSEDES every
earlier certificate for the period. So an Admin could destroy a producer's
working certificate to mint one whose PDF answers 422 forever. Issuance now
renders both editions as a preflight and refuses before writing anything.
Verified against the unpatched code: both tests fail without it.

**The content hash did not bind the certificate's own subject.** Two figure sets
naming different companies — different DoE registration numbers, different
attesters, different size classes, different obligation years — hashed
IDENTICALLY. The hash is printed on the page and returned by the public
verification endpoint so a third party can answer "is this the document Chokro
issued"; a hash covering the masses but not the name answers a narrower question
than the one it is printed to answer. Take a genuine certificate, change the
legal name and the DoE number, and the printed hash still matched.

`orgId` alone was not enough: it is neither printed nor returned, so a reader
has nothing to compare it against. The fields a reader can SEE are the ones that
had to be bound, and now are.

**A latent crash the probe exposed.** `canonicalPayload` guarded on `=== null`,
which misses `undefined` — so a figure set from an older stored certificate, or
one built by hand, crashed hash computation instead of reading the field as
absent.

**A certificate that contradicted itself.** A nil put-on-market declaration —
which `declarations.js` explicitly permits — produces a null rate, so the page
said "no put-on-market declaration has been filed for this period" beside the
declared figure and the attester's name. The false half was the half about the
producer's paperwork. There is now a distinct sentence, in both languages.

**A target that vanished when it was most relevant.** The gazette threshold was
drawn only alongside a rate, so a certificate for an unfiled period omitted the
target the producer is held to — while the figure was populated and hashed. It
is a fact about the obligation, not about whether they filed.

**Smaller, all real:** the Bangla edition printed the English unit `kg` beside
Bengali numerals on the carbon row; `fontkit` was required directly but not
declared in `package.json`, resolving only because pdfkit hoists it; the shim's
docblock cited a tripwire test file that does not exist; and its measurement
said "seven NULL-anchor calls" where the actual count for those strings is two.
The zero that carries the argument — no non-NULL anchors at all — is correct,
and is now stated as the thing that matters.

**The shim now self-tests functionally.** It verified only that a method named
`applyAnchor` existed, never that the guard worked. It now shapes `পাসপোর্ট` —
the certificate's own title, and a string that crashes unpatched — and refuses
to report success if it fails. `registerFonts` repeats the probe THROUGH PDFKIT,
because the shim patches the fontkit copy it resolved and pdfkit could in
principle hold another.

Two gaps are documented rather than closed, because a check trusted for more
than it does is worse than no check: the probe counts missing glyphs, not
misplaced ones, so a guard that started skipping EVERY anchor would shape the
right glyphs in the wrong positions with no signal — catching that needs a
reference rendering this project does not have.

**Layout was tested and held.** A 150-character legal name, a 200-character
unbroken token and a 300-character Bangla revocation reason all wrap inside
their boxes and push the following sections down. The layout reviewer never ran,
so this is my testing rather than a review.

**Still unverified:** eight lower-severity findings, including whether
`heightOfFlow` under-measures a mixed-script status banner by a line, and
whether a corrupt Bengali font file breaks the pure-Latin English edition. Both
are plausible from the code and neither is a false statement about a producer.

Files: server/src/{passports,passportPdf,fontkitNullAnchorFix}.js,
server/package.json, server/test/{passports,passportPdf}.test.js
Checks: 882 server tests (up from 865), 1035 Flutter, 337 rules, analyze clean.
The splitRuns holes were measured to zero across the BMP; the preflight tests
were verified to fail against the unpatched code.

---

## 2026-09-10 05:55 (+06) — The passport renderer: the same bug a third time

A third audit pass, focused on `passportPdf.js` — the module no prior run
reached, because the rendering reviewer hit a session limit twice.

Rather than wait for it, I fuzzed the renderer directly. Both earlier defects in
this module were found by rendering a page and looking at it, not by reading, so
that is what I did.

**Found the same bug a third time, and it was mojibake again.** `splitRuns` had
a two-way decision — Bengali face, or Helvetica — with Helvetica as the fallback
for anything the Bengali font lacked. But "the Bengali font lacks it" is not
"Helvetica has it", and for most of Unicode neither face has it.

A legal name of `中国可乐有限公司` rendered on the certificate as
`N-VýSiNPg –PQlSø`. Arabic, Devanagari, Cyrillic, Thai and emoji all behaved the
same way. A Bangladeshi producer with a Chinese or Middle Eastern parent is not
hypothetical, and `declarationAttestedByName` is a person's name in whatever
script that person writes it in.

`splitRuns` now has a third outcome, and each character is, in order:

  **normalised** — NFC first, so `e` + U+0301 becomes `é`, which Helvetica does
  have. Refusing a decomposed accent would block a legitimate name over an
  encoding detail invisible to whoever typed it. Verified: the composed and
  decomposed forms now render byte-identically.

  **stripped if invisible** — controls, zero-width spaces, bidi marks, the BOM,
  soft hyphens. These draw nothing, they arrive by accident from a paste out of
  Word, and refusing a certificate over one would block real work for no gain.

  **refused if visible and undrawable** — a legal name is the one field on this
  document that must be reproduced exactly. A certificate that silently prints a
  different name than the company's is not a lesser correct certificate; it is a
  false one. The route answers 422, not 503: the request is well formed and the
  service is healthy, and retrying will not help.

Coverage is decided against the **WinAnsi repertoire** rather than by asking
pdfkit, because pdfkit encodes anything without complaint — which is what
produces the mojibake in the first place.

**The check immediately caught a bug in my own module text.** The superseded
banner used `→` (U+2192), which is outside WinAnsi, so the arrow itself printed
as mojibake. The string-table coverage test could not see it: it walks
`STRINGS` and `BOUNDARIES`, and this lived in a template literal. There is now a
test that scans the module's own string literals through `splitRuns` — with
comments stripped, since the module now explains at length why the arrow was
removed and a naive scan matches the explanation.

**Layout held up under stress**, tested rather than assumed: a 150-character
legal name, a 200-character unbroken token, and a 300-character Bangla
revocation reason all wrap inside their boxes and push the following sections
down correctly. The status banner measures and grows; `labelled` takes the max
of both columns.

**A limitation worth stating plainly.** A producer whose legal name is in CJK,
Arabic, Devanagari, Cyrillic or Thai now cannot be issued a certificate at all.
That is strictly better than a certificate that misspells its own subject, and
it is not good enough. The fix is a font with wider coverage — Noto Sans
covers Latin, Greek and Cyrillic; CJK and Arabic need their own faces and would
add megabytes. Worth deciding before onboarding a producer with a foreign
parent.

Files: server/src/{passportPdf,index}.js, server/test/passportPdf.test.js
Checks: 865 server tests (up from 839), 61 in passportPdf alone (up from 35),
analyze clean. The CJK case was verified to render as mojibake before the fix
and to refuse after it.

---

## 2026-09-10 04:40 (+06) — EPR Phase D, second audit pass: 12 findings fixed

A second adversarial pass over the dimensions the first run could not verify,
plus the report-job and SDG code the first run predated. 36 findings, 12
confirmed. Every one of them produced a FALSE STATEMENT on a
producer-facing or auditor-facing artefact rather than an error — which is why
none was caught by the suites that already covered the same code.

**A `reversed` field that nothing writes.** `reportJobs.js` tested
`row.reversed === true` in two places. Attributions carry `reversedAt`;
`attribute.js` initialises it null and `eprPeriods.reverseAttribution` sets it,
and `accumulate` and the Dart model's `isReversed` both key off it. My report
code was the sole outlier, so the guard never fired.

The consequence is the worst kind for an auditor-facing artefact: the period
rollup and the certificate correctly exclude reversed mass and these reports did
not, so an auditor summing the chain-of-custody export got a figure ABOVE the
passport's — with the `reversed` column that would have explained the gap
reading false on every row. One predicate now, because the same mistake was
made twice and a third reader would have made it again.

**An authorisation enforced only at the point of request.** `chainOfCustody`,
the annual return and the surplus statement are owner-only, checked at enqueue.
Delivery is a separate request and `listJobs` returns every job for the
organisation — so a viewer could list the row-level export an owner requested
yesterday and download it. That is SEC-11's "org member exfiltrates data" row,
reached by the one route that hands over the bytes. The role is now re-checked
in `signedUrlFor`.

**Four missing indexes, and a test that can catch the next one.**
`reportJobs` had no index at all: the collection was written after the index
pass, so `GET /epr/reports` would have failed FAILED_PRECONDITION on its first
production call and the route's own catch would have reported it as a 503.

58 tests covered that module and none could have caught it — the in-memory fake
filters and sorts in JavaScript, so a query real Firestore refuses passes
happily. `firestoreIndexes.test.js` now reads the query chains out of the source
and checks each against `firestore.indexes.json`. Verified by deleting the
`reportJobs` index and watching it fail.

**A network fault that told producers their filing was missing.**
`ComplianceService.loadDeclaration` returns a failure as data so the declaration
screen can explain it. `compliancePositionProvider` ignored that, so a timeout
arrived as `declaration: null` and rendered as "No percentage without a
declaration" on the dashboard and "no put-on-market declaration has been filed
for this period" on the SDG page. Both are false statements about the producer's
paperwork, produced by a 503. The provider now throws `ComplianceUnavailable`,
which makes the error branch I had already written — and which was unreachable —
actually render.

**A form that attested to the wrong month.** `_hydrated` was a one-shot bool, so
changing the period dropdown left the previous month's figures in the fields
while the form became editable for the new one. Pressing "Attest and file" wrote
them against the new period under the EPR-41 attestation: a producer would have
signed, by name and under stated penalty, for figures belonging to a month it
never entered them for. Hydration is now keyed on the period and clears every
field first.

**Transport failures vanishing.** `_run` caught only `DeclarationRejected` and
`OrgActionException`. A `TimeoutException`, `SocketException` or web
`ClientException` escaped into a Future the button's callback discards, and with
no `runZonedGuarded` in the app the producer saw the spinner stop and nothing
else. On a form that files a legal attestation, "nothing happened and nobody
said why" is the worst available outcome.

**A nil declaration reported as no declaration.** The SDG headline branched only
on whether a percentage existed, so a producer that filed nil was told nothing
had been filed — the same conflation EPR-42 is about, on the page most likely to
be screenshotted. It now reads the absence reason.

**"0 kg CO2e avoided."** `_CarbonDetail` called `kg.round()`, so any period
under about half a kilogram of avoided emissions printed as a measured zero.
`CarbonEstimate.label` existed for exactly this and was dead code — and was
itself wrong, rendering `4030.0` because it interpolated a double directly.
Chased that to its root: `_trim` in `mass_math.dart` only strips decimals and
assumes its input is already rounded, which is why `formatKilograms` calls
`roundToSignificantFigures` first. The new `formatSignificantFigures` pairs
them, and an existing test that had pinned the buggy `4030.0` is corrected.

**A comment of mine that was wrong.** I had justified hardcoding the carbon
uncertainty ceiling on the client by claiming it "errs toward showing less".
That is false in the direction that matters: an Admin LOWERING the stored
ceiling makes the certificate omit a carbon figure while a client using the
constant keeps printing one. The client now reads `GET /epr/config/policy` and
uses the server's value; the constant is the fallback for a failed read, and the
comment says so.

**Coverage was again partial.** The run hit the session limit with 23 of 42
agents erroring, leaving 22 findings raised but unverified — the `rendering`
reviewer did not run at all in either pass. Worth a third pass before Phase E,
focused on `passportPdf.js`, which has now had no adversarial review across two
attempts.

Files: server/src/{reportJobs,index}.js,
server/test/{reportJobs,firestoreIndexes}.test.js, firestore.indexes.json,
lib/controllers/compliance_controller.dart, lib/services/compliance_service.dart,
lib/core/{carbon_math,mass_math}.dart,
lib/views/producer/{declaration_view,producer_sdg_view}.dart,
test/{compliance_position,core/carbon_math}_test.dart
Checks: 839 server tests (up from 790), 1035 Flutter (up from 1027), 337 rules,
analyze clean, 54 indexes validate. The index test was verified to fail with the
`reportJobs` index removed.

---

## 2026-09-10 03:05 (+06) — EPR producer portal, Phase D: reports, SDG, and two audit findings fixed

Phase D's exit criterion is met: a producer downloads a Bangla and English
Plastic Passport for a period, a third party verifies its serial without a
Chokro account, and the collection percentage appears only because a
declaration was filed.

**Client.** The declaration form (grams in, kilograms shown live beside each
figure, attestation in full rather than behind a link), the passport list with
both editions equally weighted, the collection position on the dashboard, and
the producer SDG view — five alignments, each with its limit at body size
directly under the signal rather than as a footnote, because a card saying
"collected, not recycled" in grey six-point type is how "recycled" gets
published.

**Report jobs (EPR-33/34/35, SEC-6).** Seven reports, produced by a job rather
than a request. The content hash covers the body only and is recomputable by a
third party from the `data` member alone — an earlier version hashed a fragment
that was not valid JSON on its own, so two copies compared equal but nobody
could verify the hash. CSV cells beginning `=`, `+`, `-` or `@` are prefixed:
these exports carry producer-supplied brand names, and `=HYPERLINK(...)` in one
executes when an auditor opens the file. Row-level exports pseudonymise the
disposal id per organisation, so two producers who each received a fragment of
the same bag cannot join their exports.

Delivery refuses at enqueue time when `FIREBASE_STORAGE_BUCKET` is unset, and
names the variable. The alternative — streaming the report in the response — is
the thing EPR-35 exists to prevent.

## The adversarial audit

Seven reviewers, each finding independently, then per-finding skeptics
instructed to refute. 31 findings, 2 survived. **Both were real and both were
serious.**

**A certificate could state a percentage against a withdrawn denominator.**
`assembleFigures` ran outside `issuePassport`'s transaction, so Firestore's
concurrency control never covered the declaration it read. If `openCorrection`
committed in the window, its query for passports with `status == 'issued'`
found nothing — the certificate did not exist yet — and the transaction then
committed a certificate stating 25% against a denominator the producer had just
withdrawn.

Nothing swept it up. `openCorrection` had already run and found nothing,
`submitDeclaration` supersedes no passports, and the verification endpoint
would answer `found: true, status: 'issued'` for as long as the record stood.
The declaration is now read inside the transaction and its fingerprint compared
against what the figures were derived from; a mismatch abandons the issuance
rather than retrying, because a retry would re-use the figures that are already
wrong. The test was checked against the unpatched code and fails there.

**Three of EPR-30's four supersession triggers were documented, not
implemented.** `supersedeForPeriod` was written, exported, commented against
EPR-30 and covered by tests — and called by nothing but its own test file. A
reversed attribution and a re-verified unit mass left every affected
certificate reading `issued`.

That is the failure mode no unit test can catch, because the unit worked. Both
triggers now have production callers, with a materiality threshold in policy for
reversals — superseding on every single-bottle correction would teach producers
and their customers to ignore the status, which is the one thing that would make
supersession useless. `eprRouteGuards.test.js` now reads the call graph and
asserts each trigger has a caller.

**Audit coverage was partial.** The run hit the session limit with 31 of 38
agents erroring. The `transactions` dimension completed and produced both
confirmed findings; `figures`, `tenancy`, `claims`, `client` and `rendering` had
findings raised but not verified, and the `tests` reviewer did not run. Those
dimensions are worth re-running before Phase E.

**A fake that could not sort.** The shared Firestore fake accepted
`orderBy('__name__')` and read it as a data field — undefined for every row, so
the sort was a no-op and the fake returned insertion order. A determinism test
asserting deterministic ordering would have passed on code that did not order at
all. It also accepted `startAfter` and ignored it, so a paged read returned page
one forever. Both fixed, and the determinism tests now discriminate.

**Open for the spec author.** EPR-43's 60% variance threshold and the new
`reversalMaterialityFraction` (1%) are both engineering defaults, not the
author's numbers.

Files: server/src/{reportJobs,passports,producerSkus,eprPolicy,index}.js,
server/test/{reportJobs,passports,eprRouteGuards}.test.js,
server/test/helpers/firestoreFake.js,
lib/{models/{plastic_passport_model,producer_sdg_model,organization_model},
services/compliance_service,controllers/compliance_controller,
core/carbon_math}.dart,
lib/views/producer/{declaration_view,passports_view,producer_sdg_view,
collected_mass_card,producer_dashboard_view}.dart, lib/routing/router.dart,
test/{compliance_position,producer_sdg_model}_test.dart
Checks: 790 server tests (up from 731), 1027 Flutter tests (up from 1012), 337
rules tests, analyze clean, 50 indexes validate. The stale-denominator test was
verified to fail against the unpatched code.

---

## 2026-09-09 22:10 (+06) — EPR producer portal, Phase D (server): the Plastic Passport

A producer's period now becomes a certificate: server-issued, hashed,
immutable, verifiable by a stranger, and printed in Bangla and English. Every
figure on it is read from stored evidence — nothing is accepted from the
request, which is the whole of EPR-31.

The collection percentage appears only because a declaration was filed. With no
submitted declaration the certificate does not print a blank, a dash or a 0%:
it prints "Not stated — no put-on-market declaration has been filed for this
period", because each of the other three reads as a figure.

**Server-side Bangla, and two bugs that rendered clean PDFs with text missing.**
NFR-E-4 wants Bangla; EPR-31 forbids letting the client render the certificate.
Both are now satisfied, but getting there turned up the failure mode that makes
Bengali dangerous: a missing glyph does not raise and does not draw a box — the
character simply is not on the page.

  fontkit 2.0.4 crashes on ordinary Bangla. `পাসপোর্ট` — the certificate's own
  title — reaches a GPOS lookup whose base anchor is a legal NULL offset, which
  `getAnchor` dereferences unconditionally. The OpenType spec says a NULL
  `baseAnchorOffset` means "no attachment point for this mark class", so
  `fontkitNullAnchorFix` implements that and fails loudly if fontkit's internals
  move. 2.0.4 is the latest published version; there is nothing to upgrade to.

  Noto Sans Bengali has no Latin letters at all. So the Bangla edition printed
  `Coca-Cola Bangladesh Beverages Ltd.`, `DoE/EPR/2026/0417` and
  `mixedPlastics-2015-uk-v1` as nothing — the producer's legal identity, its
  regulator's reference, and the factor version that makes the carbon line
  reproducible.

  Helvetica has no Bengali, which is worse. `মেঘনা প্যাকেজিং লিমিটেড` in the
  English edition came out as `šéÇ™‰¨›â ªœÙ¯›é•œyœ›ù`. Most Bangladeshi
  producers have Bangla legal names, and a regulator reading mojibake cannot
  tell a rendering fault from a corrupted record.

Both editions therefore compose both faces, and the split is driven by asking
the font for a glyph rather than by a hardcoded Unicode range — a range-based
splitter has to be maintained by hand and the cost of getting it wrong is
invisible text. Bengali text with no Bengali face refuses outright.

**Serials.** `CHKR-PP-9F2K-7T4D`: eight characters of Crockford base32 without
I, L, O or U. SEC-7 names `CHOKRO-2026-0001` as the thing to avoid — a
sequential serial lets a competitor enumerate every certificate ever issued, and
the verification endpoint would answer each one.

**A serial is unguessable but not secret.** It is printed on a PDF that gets
emailed to customers. So neither the rules nor the download route treat knowing
one as authorisation: reads are membership-scoped, and the PDF route checks the
certificate's own `orgId`. Third parties use
`GET /passports/verify/{serial}` — unauthenticated, five fields by explicit
allowlist, and the same response shape for an unknown serial as for a revoked
one so a guess teaches nothing.

**Three fixed bugs worth naming.**

  `obligationYearAt` compared an instant against a calendar date, so a producer
  whose obligation began 1 July 2026 had July 2026 reported as *before* its own
  obligation — by six hours, because a Dhaka month starts at 18:00 UTC the
  previous day. A null obligation year means no applicable target is stated on
  the certificate. Now arithmetic on Dhaka calendar months.

  `significantFigures` clamped decimal places and never touched the integer
  digits, so every figure of four digits or more disagreed with the client:
  5061 kg here against `mass_math.dart`'s 5060 kg on the dashboard.

  `formatPercent` dropped the decimal above 10%, turning 29.94% into "30%" —
  and 30% is exactly the gazette threshold. The certificate would have stated a
  producer met a target the evidence does not support.

**Declaration routes were missing two guards** the other EPR writes all carry:
`requireActiveOrganization` and `eprWriteLimit`. A suspended workspace is
supposed to be read-only, so without the first a suspended producer could keep
changing the denominator its already-issued certificates were computed against.
`eprRouteGuards.test.js` now reads the route table out of the source and
asserts the chain per route, which is what caught it.

**A fourth copy of the Firestore fake would have had a fourth bug.** The three
in-tree copies had each grown their own: one ignored the query operator, one
had no `set`/`update` on a document ref, and `eprPeriods`' copy had NEITHER the
read-after-write guard NOR operator-honouring filters, long after both were
fixed elsewhere. Extracted to `test/helpers/firestoreFake.js` and all three
migrated — the migration immediately caught a dropped `Timestamp.toDate()`
unwrap, and `eprPeriods.js` is now proven free of read-after-write rather than
assumed to be.

**Added beyond the spec, and flagged:** `listForReview` now reports
`correctionVariance` alongside EPR-43's period-over-period `variance`. EPR-43
asks only for the latter, but for the threat §16 names — "producer understates
put-on-market" for "a flattering percentage" — the sharper signal is a
denominator withdrawn and refiled lower. A producer that files 27,400 kg, sees
18%, then corrects to 7,000 kg to show 71% is caught by neither the
period-over-period comparison (there may be no previous period) nor by the
refiled figure looking odd. What is unmistakable is the withdrawal, and §16
already lists retained versions as part of that control.

**Open question for the spec author.** EPR-43's threshold ("moves 60% against
the previous period") is not yet in `config/eprPolicy` — the queue reports the
variance and leaves the highlighting to the console, which Phase E builds.

Files: server/src/{passports,passportPdf,fontkitNullAnchorFix}.js,
server/src/{declarations,producerAudit,eprPolicy,index}.js,
server/assets/fonts/NotoSansBengali-Regular.ttf,
server/test/{passports,passportPdf,declarations,eprRouteGuards}.test.js,
server/test/helpers/firestoreFake.js,
server/test/{eprPeriods,producerSkus,organizations}.test.js (migrated),
firestore.rules, firestore.indexes.json, rules_test/epr_passports.rules.test.js
Checks: 731 server tests (up from 587), 337 rules tests (up from 312), rules
compile with no warnings, 50 indexes validate. Both editions rendered and
inspected as images: zero .notdef glyphs across all 67 Bangla strings.

---

## 2026-09-09 20:45 (+06) — EPR producer portal, Phase C: attribution, and the points path left alone

Anik's two bottles now become 19.6 g of rigid PET attributed to Coca-Cola in
2026-09 — visible on the producer dashboard, reproducible by recompute, and
awarding no additional points. That last clause is the phase's real deliverable.

Phase C is the only phase that touches the disposal decision path, so it is
behind `EPR_ATTRIBUTION_ENABLED`, off by default. While off, the screening
prompt is byte-identical to the one this service sent before and
`attributeDisposal` returns without a read, so the most-tested code in the
repository behaves exactly as it did.

Attribution runs AFTER the decision commits, in its own transaction, and
swallows every failure. Inside the decision transaction, a registry read failing
or a mass being unverifiable would roll back a Champion's points — a payout
undone because a producer's paperwork was incomplete. `award.js` already applies
that reasoning to the push notification; this extends it.

There is no second model call. The SKU shortlist rides along on the screening
call that already happens, and the recognition answer is stored as server-only
evidence — which also makes manual approval work, since a disposal routed to
review carries its evidence forward rather than re-screening a bin that has
since been emptied.

Sixteen assertions pin EPR-27. `decide()` returns an identical result whether
the verdict carries a high-confidence match, an empty list, or nothing; the flag
vocabulary gained nothing; `attribute.js` names none of wallets, transactions,
dailyCaps, lockouts or stats and requires neither the award nor the decision
module; and `attributeDisposal` cannot throw into its caller, proven with
Firestore unreachable.

Null and empty are treated as different facts throughout. Recognition
unavailable leaves the disposal pending for a backfill; recognition that ran and
matched nothing is unattributable and increments the pool reported as its own
line. The pool sits on a platform rollup rather than any producer's, because an
unrecognised item belongs to nobody — attributing its absence to a company would
invent exactly what EPR-19 forbids.

Every attribution stores the revision and the unit mass it multiplied by, so a
November re-weighing does not change September. Revisions now freeze their
component breakdown too, because the per-polymer split is computed from those
masses and a closed revision's split must stay its own. The split floors each
share on integers and gives the remainder to the heaviest part, so polymer lines
add up to the attributed mass exactly — a breakdown that does not sum to its own
total is what a regulator notices, and rounding is not an answer when both
figures are integers.

The shortlist is an accuracy control before a cost one: a model asked to pick
from hundreds of near-identical bottles will pick one confidently, and a
confident wrong brand attributes one company's kilograms to another. Only
verified products are candidates, ranking is by observed local history, ties
break deterministically, and every returned skuId is checked against the
shortlist that was sent — a model returning an unoffered id has hallucinated,
and accepting it would attribute mass to whichever organisation owns that id.
The model is never told what anything weighs.

The barcode path honours two constraints at once. EPR-6 forbids the disposals
client allowlist growing by a key, so the scan travels with the verification
request and the server writes it. NFR-E-6 forbids a live lookup at the bin, so
nothing is resolved while the person is standing there. A misread is ignored
rather than raised, and the check digit is deliberately unverified — an invalid
GTIN simply does not resolve, while a check-digit disagreement would cost an
accurate attribution.

Reconciliation surfaces a mismatch and never corrects it: the rebuilt figure is
stored beside the incremented one, which is what every report so far was built
from. The walk is resumable and an incomplete pass writes nothing, so paging
cannot manufacture a mismatch.

A focused review of the attribution path found three privacy defects that
together were SEC-3's named failure mode, all fixed.

Producers could read their own raw attribution rows. The rule granted it and my
own comment conceded that no screen rendered them — which was the error: "no
screen renders it" is a statement about the product, not a control. A producer
holds its own Firebase credentials, the composite index is shipped, and the
Firestore SDK is a public API, so a member could query the rows directly and get
binId, a second-precision disposal timestamp and the real disposalId. Bins are
readable by any signed-in account and carry lat/lng, so joining the two
reconstructs "a map of who throws what where, to a commercial party". The grant
is Admin-only until the pseudonymised export exists, and the rules test now pins
the denial rather than the leak.

The period response returned the stored document verbatim, shipping the exact
instant of one person's disposal and the Firebase uid of the Chokro employee who
ran the reconciliation. It is now projected through an explicit allowlist — a
deletion list would have missed both again the next time the rollup gained a
field.

And the k-anonymity floor SEC-3 requires did not exist. It does now, default 5,
applied to geography only: district is the identifying dimension, while category
and polymer are properties of the packaging rather than of a person. Suppression
is stated rather than silent, because an empty district map and a withheld one
are different facts, and rendering the second as the first would be a false
claim about Chokro's own evidence.

Two further silent defects, both caught by this phase's own tests. The
confirmation queue was never written on the unattributable path, so a
low-confidence match reported a deferred count with nothing behind it — in
exactly the case where a deferred match is the only remaining chance of a real
attribution. And the accuracy sample selected nothing: a polynomial hash mapped
ids sharing a prefix into a narrow band, so four thousand sequential ids sampled
zero at 2%. Firestore's real auto-ids are random, which would have hidden that
in production and left the published accuracy figure resting on an arbitrary
slice.

Two more found by review. The district map key was sanitised on write and not on
the recompute or the reversal — the reversal decremented a key that had never
been written, creating a negative district total in a compliance rollup, and
every recompute of a period with a punctuated district reported a mismatch that
was two spellings rather than a discrepancy. And `uniqueSkuCount` was declared,
recomputed and incremented nowhere, so it read 0 for every period; it is now a
set maintained with `arrayUnion`, with the count derived from its length so the
two cannot drift.

An audit agent also left behind a property probe over 20,000 mass values asking
whether `formatKilograms` ever claims a fourth significant figure. It does not,
and that is now a real test rather than a scratch file.

Files: lib/core/epr_period.dart, lib/models (attribution, epr_period),
lib/services/attribution_read_service.dart,
lib/controllers/attribution_controller.dart,
lib/views/producer/collected_mass_card.dart, lib/views/disposal
(barcode_scan_sheet, declare_view), lib/controllers/disposal_controller.dart,
lib/services/verification_service.dart, server/src (eprPeriod, skuShortlist,
attribute, eprPeriods, eprPolicy, screen, verify, award, producerSkus, index),
firestore.rules, firestore.indexes.json, INTEGRATION_NOTES_EPR.md.

Checks: `flutter analyze lib test` clean; 949 Flutter tests pass (878 after
Phase B); 587 server tests pass (497); 312 emulator rules tests pass (290) —
including the QA-2 regression that the disposals client create allowlist has not
grown, asserted field by field; rules compile with no warnings; 44 indexes
validate.

---

## 2026-09-09 14:05 (+06) — EPR producer portal, Phase B: the mass chain, plus an adversarial audit of A and B

A producer can now register what it places on the market, Chokro weighs it, and
the weighed figure — not the declared one — is what any report would use. Coca-
Cola's 250 ml bottle exists, declared at 10 g, verified at 9.8 g with a revision
history, and no attribution exists anywhere yet, which is Phase B's exit
condition.

Mass is integer milligrams end to end (EPR-20). `units × unitMassMg` is exact
integer multiplication and a sum of such products is an exact integer sum, so
there is nothing to accumulate error; rounding happens once, at display, to
three significant figures. Tested over 412,000 rows and over 100,000 tenth-gram
rows for zero drift. A separate exact formatter renders *discrepancies*, because
three significant figures turned a one-milligram component mismatch into "the
parts add up to 10 g, but the unit mass is 10 g".

`producerSkus` is **not** a client write path, which diverges from §5.1 and the
reason is recorded rather than left implicit. §5.1's own test is whether the
governing constraint is expressible where it is enforced; EPR-9's constraint is
that the component masses sum to the declared unit mass, and Firestore rules
have no fold. A create rule there could check that `components` is a list of one
to twelve things and nothing about what is in them — so it would accept a 5 kg
unit mass beside a single 0.1 g body. Rules also cannot append to
`producerAuditLog` (EPR-44) or perform EPR-12's invalidation. The write goes
where those checks run, as a wallet balance does.

The measured mean is always adopted as the verified mass. EPR-11's wording reads
otherwise, but Appendix A step 3 records a measured 9.8 g against a declared
10.0 g that was "within the ± 10% tolerance" and states in bold that reporting
uses 9.8. Appendix A is right: keeping the declaration whenever it is close
enough makes the tolerance a licence to overstate by just under it, repeatably.
Flagged for the author as an EPR-11 wording fix.

An adversarial nine-dimension audit of Phases A and B found four critical
defects that the test suite was passing over, and all four are fixed:

Four transactions read after they wrote. Firestore's Admin SDK throws
unconditionally on that, so every mass verification and every organisation
creation would have failed on the first real request — invisible in tests
because a hand-written fake transaction does not enforce the rule. The audit
append is now split into a read half and a write half so the ordering is a
property of the signature, and all three test fakes now throw on a read after a
write.

The server's gram parser used `Number.parseFloat`, which prefix-parses: '1,250'
became 1 gram against a 1250 gram declaration, and '8.2g' was accepted silently.
Dart rejected all three. Both copies are now pinned against the same inputs.

A reporter could rewrite a verified product's declaration through the server
route, turning a verified 19.5 g bottle into a 1.3 g cap while the verified mass
stayed attached. Changing what was weighed now invalidates the verification and
closes the standing revision rather than deleting it.

The SKU update rule had no affectedKeys guard, so one deleteField write could
remove `revision` — and the next verification would then compute revision 1 and
overwrite the append-only row a passport was built on.

Seven high-severity findings are also fixed: a suspended organisation was still
writable server-side (EPR-47's read-only was not read-only); the audit chain was
an unkeyed hash the named insider adversary could recompute, and is now an HMAC
under a key that must be independent of the Firestore credential; actorName,
actorRole, ip, userAgent and the server timestamp were stored but not hashed;
deleting a log and its head returned intact:true; the invitation ceiling sampled
stale rows and could be bypassed to mint unlimited tokens for one address; and
the 0.1 g unit floor was applied per component, making a bottle with a 0.05 g
tamper ring unregisterable.

The §6.7 boundary statements are now constants rather than strings typed into a
widget, because the first attempt at testing them flagged the correct disclaimer
as a violation — a sentence denying a claim contains the claim. The Plastic
Passport will print the same list.

Files: lib/core (mass_math, sku_csv, epr_claims), lib/models (producer_sku,
sku_revision, producer_audit), lib/services/producer_sku_service.dart,
lib/controllers/sku_controller.dart, lib/views/producer (skus, editor, import),
lib/views/admin/admin_mass_queue_view.dart, lib/routing/router.dart,
server/src (producerSkus, eprPolicy, producerAudit, organizations, auth, index),
firestore.rules, firestore.indexes.json, INTEGRATION_NOTES_EPR.md.

Checks: `flutter analyze lib test` clean; 878 Flutter tests pass (767 after
Phase A); 497 server tests pass (402); 290 emulator rules tests pass; rules
compile with no warnings; 36 indexes validate. AUDIT_CHAIN_KEY joins
APP_CHECK_ENFORCED as release-blocking before a real producer is onboarded.

---

## 2026-09-09 09:40 (+06) — EPR producer portal, Phase A: tenancy and identity

A company can now be approved, invited, sign in, and see nothing but its own
empty workspace — and the rules tests prove it can see nothing else. This is
Phase A of `EPR_PRODUCER_PORTAL_SPEC.md` v1.0; no kilogram, percentage or
compliance figure exists yet, and the workspace states which inputs are
outstanding instead of showing zeros that could be read as measurements.

`producer` joins the stored role vocabulary as a **disjoint** role, not another
inclusive profile. Adding a fourth `AccountProfile` turned three implicit
assumptions into compile errors, which was the point: `accountProfilesForRole`
fell through to Champion, and `UserModel.isChampion` returned an unconditional
true, so a producer role added without touching either would have handed a
corporate compliance account a points wallet. `firestore.rules` states the same
exclusion through `isActiveCitizen()`, which replaces `isActive()` on the four
client create paths a producer would otherwise have passed — disposals, claims,
seller applications and carts. A producer account is a perfectly ordinary active
account, so a rule gated only on activity accepted one.

Five new collections, all server-owned: `organizations`, `organizationMembers`
(composite id `{orgId}_{uid}`, so tenant isolation is one unforgeable document
read), `producerAuditLog`, `producerAuditHeads` and `orgInvitations`. Every
client write is denied, administrators included, in the manner of `wallets` and
`orders`. There is no self-registration: an Admin opens and reviews a company
record — approval sets the size class and obligation start date that decide
which gazette target applies and from when — and people arrive by invitation.

Invitations are 256-bit, single-use, 72-hour, bound to one address, revokable,
capped per organisation. The token is never stored; its SHA-256 digest is the
document id, so a dump of the collection yields nothing redeemable and Chokro
cannot mint access to a customer's workspace from its own database. Chokro has
no mail service, so the link is shown once to the inviter to send — disclosed on
the dialog, along with the consequence that it cannot be re-sent. Email
verification does not have that problem and gates every producer write.

The audit log is append-only in the rules for every principal and SHA-256
chained per organisation with a monotonic sequence, so an edit, a mid-log
deletion, a truncation and a full wipe are four distinguishable findings rather
than one vague "invalid". The rules cannot bind this service — the Admin SDK
bypasses them by definition — so the chain does not prevent tampering; it makes
it detectable by anyone holding the log, the producer included. Audit writes
throw and roll back the action they were recording, and an Admin's read-only
view of a company does not open if its entry cannot be written.

Server-side: `requireProducer`, `requireVerifiedEmail`, `requireFreshAuth` and
`requireOrgRole`, which resolves the organisation from the route or the caller's
own membership and never from the request body. An Admin does not pass it —
a shared code path would give an audit trail that cannot distinguish an owner
acting in their company from a Chokro employee acting on it. App Check
enforcement ships behind `APP_CHECK_ENFORCED` with three named exemptions;
setting it is release-blocking before the first real producer, not a follow-up.

Files: lib/core (constants, account_profile, epr_categories), lib/models
(organization, org_member, producer_audit, user), lib/services
(organization_service), lib/controllers (producer_workspace, admin_producers),
lib/views (producer/*, admin/admin_producers_view, shared/app_shell,
shared/account_profile_switcher, home, profile), lib/routing/router.dart,
server/src (organizations, producerAudit, passwordPolicy, appCheck, auth,
index), firestore.rules, firestore.indexes.json, INTEGRATION_NOTES_EPR.md.

Checks: `flutter analyze lib test` clean; 767 Flutter tests pass (687 before);
402 server tests pass (308 before); 270 emulator rules tests pass (233 before);
`firebase deploy --only firestore:rules --dry-run` compiles with no warnings.

## 2026-09-08 17:25 (+06) — One bin QR now reaches the app or a browser submission

New bin labels encode an HTTPS `/b/{opaque-token}` entry instead of a token-only
barcode. Android and iOS are configured to claim that path after the hosted
association is verified; without the app, Firebase Hosting serves the same
Flutter flow. A first-time visitor is sent straight to the existing
name/email/password registration form, the auth gate retains the exact bin URL,
and successful registration returns to a resolved-bin screen rather than asking
for a second scan. Existing token-only labels remain readable inside the app.

Firestore continues to store the opaque token only, the QR URL exposes no
coordinates or user data, and web submissions use the same authenticated upload,
live-location radius, lockout, daily cap, duplicate detection, automated screen,
human-review fallback and server-only wallet mutation. Native forces a new camera
capture; web uses a file chooser and cannot prove that the chosen file was freshly
captured, so the interface and documentation state that assurance difference
plainly. Malformed tokens and lookalike hosts are rejected; closed and locked-out
bins cannot start a draft. PDF labels, the Admin QR dialog, copy text and
explanatory copy now agree on the public link.

Native association files are included for `chokro-30887.web.app`. The iOS file
uses the project's existing Team ID and bundle ID. Android authorises the local
debug certificate for device testing, and the current Gradle release is
debug-signed for local demos only. Play builds must list the Play App Signing
certificate—not the upload key—while directly distributed APKs need a production
signing key and its SHA-256. The Apple App ID and distribution profile must carry
Associated Domains. An unlisted Android build still receives the browser
fallback, so this limitation fails to a working website rather than a dead QR.

The project brief is now v3.3 with F2.13 and NFR-14, the README carries build and
release instructions, a dedicated integration note records the data and signing
boundaries, and the business brief is now v2.2 with the app/browser path in its
plain-language product explanation.

The web client opts into Flutter path routing so Firebase Hosting can preserve a
clean `/b/...` QR address, while startup migrates older `/#/...` bookmarks.
Cold native app-link URIs are normalized to an internal route before the auth
handoff, so first-time Android and iOS launches also retain the exact bin through
registration instead of falling back to the generic sign-in destination.
Production rollout still requires the Hosting deploy, the Hosting origin in the
trusted service's `ALLOWED_ORIGINS`, confirmed production Cloudinary credentials
and an authenticated upload smoke test, production native signing/provisioning,
and replacement of any token-only physical labels. Browser users see the
immediate decision or history; system push remains mobile-only.

Files: `lib/core/bin_link.dart`, `lib/services/bin_service.dart`,
`lib/controllers/scan_controller.dart`, `lib/core/bin_label_pdf.dart`,
`lib/views/admin/admin_bins_view.dart`,
`lib/views/disposal/bin_entry_view.dart`, `lib/routing/router.dart`,
`lib/main.dart`, `pubspec.yaml`, `lib/services/push_service.dart`,
`android/app/src/main/AndroidManifest.xml`, `ios/Runner/Runner.entitlements`,
`ios/Runner/Info.plist`, `ios/Runner.xcodeproj/project.pbxproj`,
`web/assetlinks.json`,
`web/apple-app-site-association`, `firebase.json`, QR/routing/native
configuration tests, `web/index.html`, `Chokro_Mobile_Project_Brief v3.md`, `README.md`,
`INTEGRATION_NOTES_QR_WEB_FALLBACK.md`, `INTEGRATION_NOTES_F7.1.md`,
`business/What-Chokro-Is.docx`.
Checks: `flutter analyze lib test` clean · `flutter test` 705 pass ·
`flutter build web` succeeds with both association files copied · final 24-page
business brief render visually inspected · Hosting emulator returns HTTP 200 for
the clean bin route and both `/.well-known` proofs with JSON content types.

## 2026-09-08 01:21 (+06) — SDG impact dashboard with honest reporting boundaries

The Admin dashboard now opens with a dedicated SDG impact view and retains the
operational platform data as a second tab, without adding another cramped mobile
navigation destination. It maps Chokro's recorded activity to SDG targets 8.3,
11.6, 12.5 and 13.3 while stating the important limit plainly: these are
operational signals, not official UN indicators or proof of environmental or
economic outcomes. Overlapping goal cards are therefore not summed, and the UI
does not invent kilograms diverted, emissions avoided, jobs or income.

The reporting path now distinguishes server-confirmed data from cached data and
labels the paginated account total as a bounded minimum when appropriate. A
missing stats document in a cold cache no longer flashes a false zero; stats and
account failures are isolated so one cannot hide the other or disable admin
shortcuts; temporary suspension totals expire on time without waiting for a
Firestore update; negative or malformed counters are clamped to zero; all
counters participate in activity detection; and the ambiguous `Sales value`
label is now `Order value placed`. Responsive card sizing, large-text behavior,
contrast, hover feedback and methodology disclosure were hardened as part of the
same pass.

The product brief is now v3.2 with feature F5.5 and NFR-13, the README documents
the two-tab flow, a field-level SDG integration note records provenance and claim
boundaries, and the business brief is now v2.1 with the same plain-language
methodology. No Firestore schema, rule or index migration is required.

Files: `lib/models/sdg_impact_model.dart`, `lib/models/stats_model.dart`,
`lib/core/label_format.dart`, `lib/services/stats_service.dart`,
`lib/services/user_service.dart`, `lib/controllers/dashboard_controller.dart`,
`lib/views/admin/admin_dashboard_view.dart`,
`lib/views/admin/sdg_dashboard.dart`, dashboard/model/format tests,
`Chokro_Mobile_Project_Brief v3.md`, `README.md`,
`INTEGRATION_NOTES_SDG_DASHBOARD.md`, `business/What-Chokro-Is.docx`.
Checks: `flutter analyze lib test` clean · `flutter test` 687 pass ·
`npm test --prefix server -- --runInBand` 308 pass · `flutter build web`
succeeds · final 24-page business brief render visually inspected.

## 2026-09-05 18:41 (+06) — iOS push notifications restored after an Xcode capability toggle

`aps-environment` had been stripped from `ios/Runner/Runner.entitlements` and
`com.apple.Push` from the target's `SystemCapabilities`, staged and ready to
commit. Without the entitlement the app cannot register with APNs, so
`firebase_messaging` never receives an APNS token, `getToken()` returns nothing,
and every path in F7.1 — award, rejection reason, appeal outcome — goes silently
undelivered on iOS while `push_service.dart`, `push_controller.dart` and
`server/src/push.js` all continue to behave as though it worked.

Read as accidental rather than intended, because the removal is exactly two
lines wide. `4081f7a` had turned iOS push on as one coordinated change —
entitlements file, `CODE_SIGN_ENTITLEMENTS` across all three configurations,
`APS_ENVIRONMENT` per configuration, `remote-notification` in `Info.plist`,
both capabilities, deployment target 15.0 — and added
`test/native_release_config_test.dart` in the same commit to hold every one of
them. What was removed is the pair Xcode itself deletes when the Push
Notifications capability is switched off in Signing & Capabilities, and nothing
else: the three `APS_ENVIRONMENT` settings now expanded into nothing,
`CODE_SIGN_ENTITLEMENTS` still pointed at an empty plist, `remote-notification`
was still declared, and the tripwire written alongside the capability was left
in place, failing. A decision to drop iOS push would have taken those with it.

Both lines restored; the files now match `4081f7a` exactly. Note for whoever
hits this again: the Push Notifications capability needs a paid Apple Developer
Program membership, and a personal team gets an automatic-signing fix-it
offering to disable it. That toggle is fine to make locally and must not be
staged — `native_release_config_test.dart` is what catches it.
Files: `ios/Runner/Runner.entitlements`, `ios/Runner.xcodeproj/project.pbxproj`.
Checks: `flutter test` 675 pass, 0 failures — clearing the pre-existing failure
recorded in the two entries below.

## 2026-09-05 18:27 (+06) — Registration could hang forever on a slow connection

`Create account` had no deadline on the half of registration that needs one.
Offline persistence is enabled app-wide, which makes `WriteBatch.commit()`
resolve on the server's acknowledgement rather than on the local write, so on a
connection that never delivers it neither returned nor threw. `signUp` awaits
it, so three things followed: the button spun indefinitely with no error; the
rollback in `signUp`'s `catch` never ran, leaving a Firebase account with no
profile; and `authControllerProvider` stayed `AsyncLoading`, which is the flag
`AppShell`, `StartupErrorView` and `AccountIncompleteView` all read to disable
their sign-out buttons — so a stalled registration locked every way out of the
account it had half-created. `push_service.dart` documents this exact trap for
an offline delete and bounds it; the registration path had been left unbounded.
The profile write and the rollback delete now both have deadlines, and a
timeout is reported as a message naming the step that timed out.

Separately, the router left `/register` the moment the Firebase account
existed — before the profile write it was waiting on. That disposed
`RegisterView`, taking the spinner and, in the failure branch, the `AppSnackBar`
that fires only `if (mounted)`: a slow registration that failed reported nothing
at all. Whether the user was then bounced to `/account-incomplete` or `/login`
depended on which of the listener and the write came back first. The gate now
distinguishes a profile that is missing because something broke from one that is
missing because it has not been written yet, and holds the form in place until
registration ends either way.
Files: `lib/services/user_service.dart`, `lib/controllers/auth_controller.dart`,
`lib/routing/router.dart`, `test/registration_stall_test.dart` (new).
Checks: `flutter analyze` clean · `flutter test` 674 pass, 1 pre-existing
failure in `native_release_config_test.dart` from the emptied
`Runner.entitlements` in the working tree (unrelated, as in the entry below).

## 2026-09-03 21:38 (+06) — Points no longer awarded for waste that never went in the bin

Screening now asks the two questions the disposal award actually rests on —
is a bin visible, and is the waste in it — and `decide()` flags `noBinVisible`
/ `wasteNotInBin` when the answer is not a clear yes, including when the model
does not answer at all. Previously a sharp photo of the declared waste held in
hand at the bin passed the geofence, the duplicate check, the type match and
the confidence threshold, so it auto-approved and paid out. Both flags are
advisory: an administrator can still approve a bin the model missed. Capture
guidance now asks for the photo the check requires, and the review queue shows
the screen's verdict beside the photograph.
Files: `server/src/screen.js`, `server/src/decide.js`, `server/src/verify.js`,
`server/src/award.js`, `lib/models/disposal_model.dart`,
`lib/views/disposal/photo_view.dart`, `lib/views/admin/admin_disposals_view.dart`,
server + Flutter tests.
Checks: `npm test --prefix server` 308 pass · `flutter analyze` clean ·
`flutter test` 666 pass, 1 pre-existing failure in
`native_release_config_test.dart` from the emptied `Runner.entitlements` in the
working tree (unrelated).

## 2026-09-01 21:30 (+06) — Listing images pinned to this project's Cloudinary account

`validProductImage` in `firestore.rules` matched the account segment of a
delivery URL as `[^/]+` — any Cloudinary account on the internet — while its own
comment claimed the URL "must name the authenticated seller's own upload folder
on the configured host". A seller could open a free Cloudinary account, upload
under the folder `chokro/products/<their own uid>/`, and publish a listing whose
bytes they kept control of: swappable after the listing had been seen, and
logging the address of every buyer who scrolled past it.

Nothing else caught this. A product document is written by the *client*
(`ProductService.create`), and unlike a disposal or claim photograph — which
`isTrustedImageReference` re-validates server-side, cloud name included, during
verification — the server never re-reads a listing's `imageUrls`. These rules
were the only check there was.

The account is now named once, in `cloudinaryCloud()`, and pinned in all three
provenance patterns (products, evidence, profile photos). The legitimate path is
unaffected: every URL the app stores comes from `photoUrl` in this service's own
upload response.

Release note: this couples the rules to one Cloudinary account, deliberately and
in a single place. It must equal the server's `CLOUDINARY_CLOUD_NAME`; if the two
disagree, listing photo writes fail with permission-denied while uploads keep
succeeding. Any historical listing whose images were served from a different
account would also become uneditable until its photographs are re-uploaded —
none exist today, since `.env` and the integration notes both name `ata3ir5d`.

Files: `firestore.rules`, `rules_test/*.js` (fixtures repointed)
Checks: 233 rules tests pass, up from 232 — the new one asserts a listing whose
image sits on `attacker-cloud` is refused, which the old pattern accepted.

## 2026-09-01 21:24 (+06) — The reward accent was invisible in the dark theme

`AppTheme.reward` was a single constant, `#E4A11B`, chosen against the balance
card's light-theme background. That card is painted with a `primary` ->
`lerp(primary, tertiary, .68)` gradient, and `primary` is a dark emerald
(`#156348`) in the light theme but a *light* mint (`#8dd5b3`) in the dark one —
so this is the one accent in the app whose backdrop gets lighter exactly where
every other surface gets darker. The amber measured 3.23:1 on the light theme's
emerald and **1.31:1** on the dark theme's mint: an effectively invisible
sparkle, sitting beside an `onPrimary` label that inverted correctly.

Now a brightness-aware `ColorScheme.reward`, alongside `success` and `warning`
in the same extension: `#F0B94A` light (4.04:1), `#6E4600` dark (4.84:1). The light
value is the `gold` the photocard export already uses, so the warm accent is one
tone across the product rather than two near-misses. The `AppTheme.reward`
constant stays for the photocard, which is fixed light paper and does not want a
theme-aware colour.

Files: `lib/core/theme.dart`, `lib/views/home/home_view.dart`,
`test/ux_hardening_test.dart`
Checks: 665 Flutter tests pass, up from 663. The two new ones measure the accent
against both gradient stops in both themes; reverting the constant fails the dark
case at the measured 1.31.

## 2026-09-01 21:12 (+06) — Rate limits on the eight endpoints that had none

`/whoami`, `/admin/ping`, `GET /claims/quota`, `GET /config/points`,
`POST /sellers/:uid/listings`, `POST /bins`, `POST /bins/:id/active` and
`POST /config/points` carried no limiter. Every authenticated request already
costs a `verifyIdToken(checkRevoked: true)` round trip to Google plus a
`users/{uid}` read before any handler runs, so an unlimited endpoint hands one
account an unbounded lever on this single free instance even where its own
handler is cheap — and `POST /sellers/:uid/listings` sweeps a seller's entire
catalogue.

The four writes take the existing `writeLimit`. The four reads take a new
`readLimit`
of 60/minute, set two orders of magnitude above what the app does: the policy is
fetched once per session and cached by `policySnapshotProvider`, and the claim
quota is read once before composing a claim. `/health` and `/photos/limits` stay
open — both are unauthenticated and constant-cost, and Render pings the former.

Files: `server/src/index.js`
Checks: 300 server tests pass.

Also added a `chokro-web-static` launch entry serving `build/web`, which is how
the release bundle was opened for the visual pass — `flutter run -d web-server`
never reaches first frame without the Dart Debug Extension, so it is not a usable
preview target here.

## 2026-09-01 21:04 (+06) — `unawaited_futures` was configured but never enabled

`analysis_options.yaml` promoted `unawaited_futures` to `warning` under
`analyzer: errors:`, with the comment "a dropped future is a silently swallowed
failure". That section only changes the severity of a diagnostic already being
produced, and the rule is in neither `flutter_lints` nor the
`lints/recommended.yaml` it includes — so the guard had never once fired. A probe
file with a plainly dropped future analysed clean.

Enabling it found four dropped futures, all deliberate: two
`SemanticsService.sendAnnouncement` calls that must not delay the auth call
behind them, and two `context.push` results neither caller uses. All four are now
`unawaited(...)`, which is what keeps the rule useful for the next one.

Files: `analysis_options.yaml`, `lib/views/auth/login_view.dart`,
`lib/views/auth/register_view.dart`, `lib/views/claims/claim_history_view.dart`,
`lib/views/seller/seller_products_view.dart`
Checks: `flutter analyze` clean with the rule live.

## 2026-08-26 11:47 (+06) — A launch config for the trusted service

Registering a bin failed with "Could not reach the server. It may be offline,
or it may be refusing requests from this address." The message was accurate and
the client code was correct: nothing was listening on `localhost:8787`, the
address the running web build was compiled against. `.claude/launch.json`
described only the hosting origin, so there was no configured way to start the
backend; it now carries a `chokro-server` entry running `npm run dev` from
`server/`. That script is the one that sets `ALLOW_LOOPBACK_ORIGINS=true`,
which matters because `flutter run -d chrome` takes a fresh random port each
launch and `ALLOWED_ORIGINS` names only `http://localhost:5000` — so a server
started with `npm start` would have refused the browser and produced the very
same sentence.

No application code changed.

Files: `.claude/launch.json`
Checks: `/health` 200; preflight `OPTIONS /bins` from the app's live origin
`http://localhost:64129` returns 204 with a matching
`Access-Control-Allow-Origin`; `POST /bins` reaches the handler and returns
401 `unauthenticated` instead of failing to connect.

## 2026-08-26 11:40 (+06) — The five never-audited areas, audited

The prior audit planned eleven areas of `lib/` and ran six. The remaining five
— `admin-queues`, `admin-config`, `wallet-donations`, `seller`, `shared-core` —
had never been looked at by anyone. They have now been, and the results were
worse than the six that had: **six high-severity defects**, three of them in
paths that move points or make decisions about them.

The ones worth naming:

- **Sign-out could not complete offline.** `unregisterDevice` was written to
  "never throw" so cleanup could not block sign-out — but Firestore offline
  persistence *queues* a delete, and the Future neither returns nor throws
  until it reaches a server. The `await` simply never finished, the catch never
  ran, and a user out of signal was never signed out at all.
- **The appeal review gate leaked between appeals.** The "I reviewed the
  photograph" tick lives in the card's local State and the cards were unkeyed,
  so resolving one appeal shifted the rest up a position and Flutter re-used the
  State by index — arming Uphold and Decline on evidence nobody had opened.
- **A listing save wrote stale stock over the server's decrements**,
  resurrecting stock that sales had already consumed.
- **Retrying a failed donation could debit twice.** `resetDraft()` nulled the
  idempotency key and the screen called it from six ordinary-interaction
  callbacks, so tapping the same amount chip after a lost response minted a
  second key.
- **The redemption block accepted ratios the app will not honour** — only the
  integer quotient is used, so "150 points to BDT 20" was applied as 7 points
  per taka and "10 points to BDT 100" gave away a hundredfold.
- **The points policy silently reverted another admin's change**: a full
  overwrite from a baseline cached for the whole session, with no version check
  anywhere on the path.

Plus: every text field's resting outline measured 1.33:1 against its own fill,
under WCAG's 3:1 floor for a control boundary; `friendlyErrorMessage` forwarded
raw `StateError` text so users read "Bad state: Not signed in."; an offline user
with a cold cache was told their profile was missing and to register again; and
a failure in `main()` left a black screen.

Two reported findings dissolved on contact with the code, and one of my own
earlier fixes was a regression the audit caught: the image work had downscaled
the eco-action queue's photo, which is not a thumbnail but the image an admin
decides a claim from. `image_delivery.dart`'s own library doc states the
invariant that was broken. The appeals queue's private viewer is now shared as
`EvidenceThumbnail`/`showEvidencePhoto`.

Files: ~25 modified, 3 added (`views/shared/evidence_viewer.dart`,
`views/shared/notice_card.dart`, `core/image_delivery.dart`), 7 new test files.

Checks: `flutter analyze` clean · `flutter test` 619 → **646** ·
`npm test --prefix server` 282 · `rules_test` 232 · `flutter build web` succeeds.

## 2026-08-26 09:30 (+06) — Verified the outstanding UX audit, then fixed it

`UX_AUDIT_OUTSTANDING.md` opened by saying its own verification stage never
ran, and that roughly one in ten of its findings would dissolve on contact with
the code. That stage was run: all 44 leads read against the real source. 43
confirmed or partly confirmed, 1 dissolved (`market-buyer-9` — the catalogue's
Search key does work). Two of the doc's *suggested fixes* were also wrong and
would have shipped new bugs: comparing bins by the nullable `id` skips the
reset in exactly the case that needs it, and clearing the cached photo upload
on `clearPhoto` would have attached a stale photo URL to a retaken photograph.
Both corrections are recorded in the code where they were made.

Highlights: the eco-action form opened onto a stale "Sent for review" with no
form for anyone who had ever left it by the back button; a suspended user's
navigation tabs were silently inert; the quota banner said "3 claims left this
week" when the number counts *approvals*; the profile picker could not be
scrolled at accessibility text sizes, locking an Admin out of the Champion
workspace; and signing out recorded the current screen, so the next person to
sign in on a shared handset landed there.

Also consolidated three divergent private `_Notice` widgets into one shared
tone-based `NoticeCard`.

Files: 30 modified, 2 added (`views/shared/notice_card.dart`, and the corrected
quota expectations in `test/claim_quota_status_test.dart`).

Checks: `flutter analyze` clean · `flutter test` 594 → **598**.

## 2026-08-26 09:31 (+06) — Performance: image decode and list virtualisation

Two costs shipped for the life of the project, neither visible in a screenshot.

Every photograph was delivered at upload resolution — the compressor targets
1600 px — and painted into 40 px avatars and 76 px thumbnails. Flutter decodes
to uncompressed RGBA regardless of the box, so each was ~10 MB of cache: a
twenty-item catalogue held ~200 MB of bitmaps and pulled ~8 MB over the wire to
draw twenty thumbnails. `core/image_delivery.dart` now asks Cloudinary for the
size actually being painted and caps the decode either way. Stored URLs are
never rewritten, so `isTrustedImageReference` is unaffected, and admin review
surfaces keep their full-resolution request — an admin judges evidence from
that image and there is no zoom viewer — taking only the decode bound.

`ListView(children: [Center(child: Column(...))])` gives the list a single
child, so nothing virtualises: all forty order cards and every listing were
laid out and painted every frame. The width constraint moved to the viewport
and the rows now build lazily.

Files: `core/image_delivery.dart` (new), 8 views, `test/core/image_delivery_test.dart`
and `test/performance_regression_test.dart` (new).

Checks: `flutter analyze` clean · `flutter test` 598 → **611**.

## 2026-08-26 09:32 (+06) — Wallet and donation audit, and a gap the disposal fix opened

Neither area had ever been audited. The wallet header rendered
`balance?.toString() ?? '0'`, so a newest ledger entry with no `balanceAfter`
showed a Champion with points a balance of **zero**, beside a ledger full of
credits — `ledgerBalanceProvider`'s own doc comment already promised a fallback
to `wallets/{uid}` and now has one. The donation screen stranded its receipt
the same way the eco-action form did. A suspended Greenpreneur could open the
listing editor and upload photos before the save was refused, though
`firestore.rules:860` requires `isActiveSeller()` to create a listing at all.

The gap: guarding `startForBin` on the bin changing — so re-scanning the same
bin stops destroying the photograph — also reused a *submitted* draft, marching
the user through photo and location to land on a receipt from ten minutes ago.
A submitted draft is now never reused, and both halves are pinned against each
other in `test/disposal_draft_reuse_test.dart`.

Files: `controllers/ledger_controller.dart`, `views/donations/donation_view.dart`,
`views/disposal/scan_view.dart`, `views/seller/seller_products_view.dart`,
`test/disposal_draft_reuse_test.dart` (new).

Checks: `flutter analyze` clean · `flutter test` 611 → **619**.

## 2026-08-24 19:15 (+06) — Fixed two navigation dead ends on the Champion path

"My appeals" and "My orders" were bare `Scaffold`s reached with `context.go`,
which replaces the stack — so no back button rendered and neither screen has a
navigation bar, leaving no way off either one. The orders case is on the
purchase path, straight from the checkout receipt. Both now sit inside
`AppShell`, which supplies its "Back to home" affordance exactly when there is
nothing to pop. Also corrected the README's local-run command, whose
copy-pasteable block gave the Android-emulator address to every target.

Files: `views/appeals/appeals_view.dart`, `views/orders/buyer_orders_view.dart`,
`core/api_config.dart`, `services/server_warmup.dart`, `README.md`,
`test/core/api_config_test.dart` (new).

Checks: `flutter analyze` clean · `flutter test` 567 → **576**.

## 2026-08-24 18:40 (+06) — Greenpreneur sales report, and web fixes

Added a sales report for the 3ZERO Greenpreneur — order value, cash collected,
simulated payments and amounts still to collect, over today / 7 / 30 / 90 days
and all time — as a new `Sales` tab and a home card. Figures are deliberately
split rather than summed: nothing in this system ever pays a seller, and the
prototype online methods move no money, so a single "received" total would be
partly fictional. Also fixed a listing-editor save that reported success as
failure when the page had been refreshed, and gave the form keyboard navigation.

Files: `core/sales_report.dart`, `controllers/sales_report_controller.dart`,
`views/seller/seller_sales_view.dart` (new); `order_service.dart`,
`constants.dart`, `router.dart`, `app_shell.dart`, `home_view.dart`,
`product_edit_view.dart`, `order_card.dart`; two new test files.

Checks: `flutter analyze` clean · `flutter test` 525 → **567** ·
`flutter build web` succeeds.

## 2026-08-24 17:20 (+06) — UI/UX pass: layout, contrast, and dead ends

Fixed usability and correctness defects the suite did not cover: two layout
overflows that hit at the default text size, error snackbars rendered at 1.70:1
contrast, and dead ends in the scanner, checkout, the Greenpreneur destinations
and Android back. Remaining leads, and the five areas the audit did not reach,
are in `UX_AUDIT_OUTSTANDING.md`.

Files: 22 modified, 3 added (`views/shared/app_snackbar.dart`,
`views/shared/unsaved_changes.dart`, `test/ux_hardening_test.dart`).

Also fixed a `ListTile` assertion caught on device: the appeal evidence card
wrapped its `CheckboxListTile` in an opaque `DecoratedBox`, hiding the tile's ink
splashes, so the confirmation an admin must tick gave no press feedback.

Checks: `flutter analyze` clean · `flutter test` 496 → **525** ·
`flutter build web` succeeds.

## 2026-08-24 12:52 (+06) — Internal audit of `5b1b779`: fixed seven defects

Read the whole trust boundary — `server/src`, `firestore.rules`, `lib/` —
looking for defects rather than working against someone else's list. The payout
path was sound: nothing found could mint points, escalate privilege, or let a
client write a balance. The one finding with a user-visible consequence was the
weekly claim quota, which always displayed as unused because the client parsed a
wire key the server has never sent. Full write-up in `AUDIT_2026-08-24.md`.

Files: `lib/services/claim_service.dart`, `lib/core/product_taxonomy.dart`,
`lib/core/validators.dart`, `server/src/award.js`, four views
(`seller_products`, `product_detail`, `admin_appeals`, `appeal_form`),
`seller_application_view`, `rejection_reason_dialog`, `checkout_view`,
plus `AUDIT_2026-08-24.md` and three test files.

Checks: `flutter analyze` clean · `flutter test` 482 → **496** ·
`npm test --prefix server` 279 · `rules_test` 222 · `flutter build web` succeeds.

---

## 2026-08-24 07:30 (+06) — Admin UX upgrade

Added the admin to-do list and today's review workload, reworked the appeals
review screen, and gave the points-policy editor its provenance. *(backfilled —
`5b1b779`)*

## 2026-08-23 21:05 (+06) — Polished app shell, authentication, marketplace discovery, filters, and product counts

*(backfilled — `745930a`)*

## 2026-08-23 14:13 (+06) — Implemented the prototype online payment system for orders and green-initiative donations

Simulation only: no credentials collected, no processor contacted, receipts
permanently labelled `SIM-`. *(backfilled — `222bceb`)*

## 2026-08-23 03:25 (+06) — Added an explicit QR layout boundary and accessibility

*(backfilled — `a7fccbb`)*

## 2026-08-23 03:11 (+06) — Improved navigation, responsive layouts, messaging, validation, pending-application handling, and account isolation; documentation updated

*(backfilled — `7335941`)*

## 2026-08-20 12:31 (+06) — Two iOS files updated

*(backfilled — `9b4feeb`)*
