# Recovered audit findings — 2026-09-17

**What this is.** 127 findings raised by adversarial-review workflow
agents between 2026-09-08 and 2026-09-10. Several of those runs hit session
limits before their verification stage completed, so the findings were never
triaged — and the only trace that survived in `commits_m.md` was the sentence
*"eight lower-severity findings, still unverified"*, which turned out to
undercount them by more than an order of magnitude.

Recovered from the workflow journals under
`~/.claude/projects/.../subagents/workflows/*/journal.jsonl`, which persist the
structured return value of every agent.

**Read this as leads, not defects.** They are unverified agent claims. Past
experience on this repository is that roughly one in ten dissolves on contact
with the code, and that some *suggested fixes* were wrong in ways that would
have shipped new bugs. Verify before acting.

**Most are already closed.** These runs preceded several fix passes, and the
mechanical triage below shows the majority of the high-severity claims no
longer describe the code. The value here is the residue.

| Severity | Count |
|---|---|
| critical | 18 |
| high | 42 |
| medium | 45 |
| low | 22 |
| **total** | **127** |

Counts include duplicates: several agents reviewing the same module reported
the same defect independently, which is a signal about confidence rather than
noise to strip.

---

## Triage, 2026-09-17

Mechanically checkable claims, run against the current tree:

| Claim | Status |
|---|---|
| `reportJobs` tested `row.reversed === true` on a field nothing writes | Fixed — no occurrences remain |
| no `reportJobs` composite index | Fixed — index present |
| no `plasticPassports` composite index | Fixed — 8 present |
| `signedUrlFor` never re-checked `minRole` | Fixed — `orgRoleAtLeast(actorRole, …)` present |
| `supersedeForPeriod` never called from production | Fixed — called from 2 production sites |
| `fontkit` undeclared in package.json | Fixed — declared |
| no `storage.rules` | **Was still live. Fixed 2026-09-17.** |
| `GET /passports/verify/:serial` not App Check exempt | **Was still live. Fixed 2026-09-17.** |
| `listJobs` returns `storagePath` verbatim | **Unverified** — `storagePath` still appears in the module |
| `localeCompare` makes report row order locale-dependent | **Unverified** — still present |

### Two fixed today

**`appCheck.js` — the verification endpoint was not App Check exempt.** The
most urgent of the 127, because `APP_CHECK_ENFORCED` is release-blocking under
NFR-E-9 and SEC-10, so enforcement was going to be turned on. The verification
URL is printed into every certificate, held by people with no app to attest
with, in a content-hashed document that cannot be reissued with a corrected
URL. Enforcing without the exemption would have invalidated every certificate
already issued.

Worse than reported: `EXEMPT_PATHS` is exact-match, and
`/passports/verify/<serial>` is a different string for every certificate. The
obvious fix — adding the route to that list — would have matched nothing while
the deploy log claimed an exemption was in place. Fixed with a prefix list.

**`firebase.json` / `storage.rules` — the export bucket had no declared
posture.** No `storage` target, so `firebase deploy` never deployed a ruleset,
and nothing in the repository stated what the bucket holding every
organisation's report artefacts — including the row-level chain-of-custody
export — was supposed to allow. Now denies every client path; the only read
route is the signed-URL endpoint, which is role-checked and audited.

### Still open

**`verifySerial` returns a sixth field.** EPR-29 says the endpoint returns
*"only"* five things, and `supersededBy` is a sixth. Two agents flagged it
independently. It is not obviously a defect: the holder of a superseded
certificate needs to find the current one, and that is why it was added. But
it hands an unauthenticated caller a second valid serial, which cuts against
SEC-7's enumeration argument.

**This is a decision for the spec author, not a fix.** Removing it breaks a
real use case; keeping it contradicts the word "only". Listed alongside the
EPR-11 tolerance and `reversalMaterialityFraction` questions.

---


## Second triage pass, 2026-09-17 (afternoon)

Every CRITICAL and HIGH finding was checked mechanically against the current
tree. Most no longer describe the code — they were closed by fix passes that
ran after these agents reported. Four were still live.

### Fixed in this pass

**`passports.js` — the collection percentage was overstated.** The numerator
summed every gazette category Chokro collected; the denominator summed only
the categories the producer declared. A producer who declared rigid and had
flexible collected too got those kilograms in the numerator with nothing in
the denominator to answer for them.

On this module's own test fixture that is 27.8% where the honest comparison is
22.9% — and against the year-3 target of 30% those are different stories, on a
document a regulator reads. EPR-24 makes the target a percentage of what was
placed on market, declared per gazette category; a ratio across two different
category sets is not that percentage.

Both sides now cover the same set, and the excluded mass is reported as
`collectedOutsideDeclarationMassMg` rather than discarded — it is real material,
and the reason it cannot enter the ratio is an incomplete declaration, which is
worth surfacing. Raised independently by two agents; an existing test had
pinned the inflated value, which is why nothing failed.

**`eprPeriods.js` — `carried` was unvalidated.** The resumed-recompute running
totals arrive in the request body and seed the figure that becomes the
independent check on the incremented counters. Whoever ran the check chose what
it started from. Now validated against an allowlist of keys and whole
non-negative values, rejecting rather than clamping. Malice was never required:
a client resuming with stale state did the same thing silently.

**`reportJobs.js` — `listJobs` leaked `storagePath`.** The single-job route
stripped it with a spread; the list route, which never knew about the rule,
returned the document verbatim. Replaced with one allowlist projection at the
source.

**`reportJobs.js` / `skuShortlist.js` — `localeCompare` ordering.** Every sort
sat under a comment promising output "byte-identical across runs" and used
collation that varies with the process locale and Node's ICU build. On real
Bangladeshi district names the default locale sorts Latin first and `bn` sorts
Bengali first — the same rows, a different order, a different `contentHash`,
on a deploy where nothing but `LANG` changed. Now code-point order.

### Checked and closed

The §6.7 boundary statements ARE on the certificate (the first triage grep
missed their wording). The audit digest covers `actorName`, `actorRole`, `ip`
and `userAgent`. `supersedeForPeriod` is called from production.
`canonicalPayload` carries producer identity. Transaction read-before-write
ordering is correct in `producerSkus.js` and `organizations.js`. Period reads
go through `projectForProducer`.

### Not triaged

The MEDIUM and LOW findings have not been checked. They are the residue, and
they are listed below.

*Corrected 17 September 2026 (evening): this paragraph previously also excluded
"the client-side Dart findings", which was wrong and misleading — the Dart
findings at CRITICAL were checked in this pass like every other, and both are
closed (`compliance_controller.dart` carries an explicit "a failed read is not
an absent declaration" guard; `declaration_view.dart`'s one-shot `_hydrated`
bool is now `String? _hydratedFor`, keyed by period). The sentence implied two
CRITICAL defects were unexamined when they were fixed.*

---

## Third triage pass, 2026-09-17 (evening) — MEDIUM, `firestore.rules`

Four MEDIUM findings named `firestore.rules`. Taken first because the rules are
the boundary that survives when the Node service is bypassed.

**Three are closed, by a stronger fix than any of them proposed.** They all
described the `producerSkus` client write path — a `hasOnly` allowlist that
could not match a server-created document, an authorisation chain with no
notion of a suspended tenant, and a `massStatus` lock rendered unreachable by
the first two. The write path no longer exists: `allow create, update, delete:
if false`. There is nothing left to get wrong, which also closes the CRITICAL
field-deletion finding at the same line.

**One was live and is now fixed: `producerAuditHeads` was admin-only.**

`producerAudit.js` justifies the whole design on the grounds that tampering is
"detectable, by anyone holding the log — including the producer whose history
it is". That was not true. A producer could read every entry and still had no
way to check them: no verification endpoint outside `requireAdmin`, and no
sight of the chain head — and truncation is only visible as a head whose
sequence runs past the entries that survive. The one check a producer could
make alone was the one the rules withheld.

Two changes, because the producer needs both halves:

- `producerAuditHeads` is readable by the organisation whose head it is.
  Nothing new is disclosed — the head holds `orgId`, `sequence`, `digest` and
  `updatedAt`, all of which the organisation already reads off its own entries.
  What it gains is the pointer to compare them against. Writes stay denied to
  everyone, administrators included.
- `GET /epr/audit/verify`, at `orgViewer`, scoped to the caller's own
  organisation from the membership and never from a parameter. Full
  verification of a keyed chain is impossible without the key by design, so
  this is the half the producer cannot do alone.

`projectVerification` is an explicit allowlist like every other client-facing
projection here, and `keyed` travels with the verdict: the producer is the
party that would be disputing with the operator, and is the reader it is least
fair to overstate the control to.

### MEDIUM, `reportJobs.js` — ten findings, two of them duplicates

**Four were already closed.** Both index findings (`listJobs` on
`reportJobs`, `reconciliationVariance` on `plasticPassports`) are covered by
declared indexes and by `firestoreIndexes.test.js`, which parses every query in
`src/` and asserts `reportJobs` among them. `localeCompare` survives only in a
comment explaining why it is not used.

**Four were live and are fixed.**

*Chain-of-custody rows carried dates outside their own period.* `attribute.js`
derives the period from `decidedAt` and stores it as `disposalDecidedAt`;
`createdAt` is when the document happened to be written. Across a month
boundary they differ, so a disposal decided at 23:00 on the 30th and attributed
minutes later exported with October's date in September's report. Now dated
from `disposalDecidedAt`, falling back for rows written before the field.

*SKU performance columns did not multiply out.* `units` and `massMg`
accumulated across every attribution while `unitMassMgUsed` and `skuRevision`
were taken from whichever was read first, so a mass re-verified mid-period —
an ordinary event under EPR-12 — produced a row where units × unitMassMgUsed ≠
massMg. Now blanked, with `unitMassVaried` / `revisionVaried` saying why. A
weighted average was rejected: it reconciles, and it is a figure that was never
used to attribute anything.

*The geographic CSV dropped its suppression notice.* When the k-anonymity floor
bites, `projectForProducer` returns an empty district map — so the CSV was a
column header with nothing under it, reading as "no geography recorded", which
`eprPeriods.js:485` states explicitly must never happen. `serialise` now emits
`payload.note` as `#` lines, read off the payload rather than passed in so a
report that gains a qualification later cannot ship a CSV without it. Inside
the hashed body, deliberately: a qualification excluded from the hash can be
stripped without invalidating it.

*The DoE annual return registered the wrong passports.* Fifty most recent
across all time, in a document reporting one registration year. Now filtered to
the twelve periods the return covers.

**One is recorded rather than fixed.** The job document's `cursor` is written
`null` and never advanced, so `resume` re-runs from the beginning — correct,
since the read is idempotent and the output deterministic, but it does not help
a period too large to read inside one instance lifetime. Durable cursors mean
deciding what a partially-read report means when the rows changed between
attempts, which is an EPR-34 determinism question rather than a pagination one.
The module header claimed the cursor worked; that claim is now corrected, since
a comment describing a capability the code lacks stops anyone looking for it.

### MEDIUM, `passports.js` — ten findings, seven distinct

**Four were already closed.** `supersedeForPeriod` now has three production
call sites (`index.js:2233`, `passports.js:1069`, `passports.js:1118`).
`canonicalPayload` carries `legalName`, `doeRegistrationNo` and
`obligationYear`, so two figure sets naming different producers no longer hash
identically. The collection percentage was fixed in the second pass. And
`supersedeForPeriod`'s query filters `status == 'issued'`, so it cannot strip a
revocation.

**Three were live and are fixed.**

*A suspended organisation could be issued a certificate.* EPR-47 makes a
suspended workspace read-only with "no new issuance", and
`requireActiveOrganization` enforces that on every producer route — but issuance
is an ADMIN route, so that middleware never ran, and `issuePassport` checked
only that the organisation document existed. A suspended, closed or
never-approved company could be handed a Chokro-signed certificate that the
public endpoint reports as `issued`. Now refused in the module rather than at
the route, so it holds for every caller.

*A retry was a reissue.* Every call minted a fresh serial and superseded what
stood before it, so a lost response or a double-click produced a second
certificate over byte-identical figures and marked the first `superseded` — and
a third party holding the first reads that as "the evidence changed" when
nothing did. `contentHash` already decides identity, so an identical standing
certificate is now returned rather than replaced.

*A supersession could commit with nothing in the audit chain.* This was a
`batch.commit()` followed by a separate `audit.append()`, and the second was
allowed to fail on its own. Now one transaction: query, chain head, then every
write. `producerAudit.js` states the rule — an action that could not be logged
has not happened — and invalidating somebody's certificate is not the operation
to except from it.

**One adjacent gap, smaller than first recorded.** With the rate corrected, the
certificate no longer prints an inflated figure. It was noted here that it
"says nothing" about the mass collected in undeclared categories — *that was
wrong, and rendering the certificate showed it.* The **By gazette category**
table lists every gazette category with its collected mass beside its declared
mass, and prints **"not declared"** in the declared column where the producer
declared none. A reader sees 880 kg of flexible packaging collected against
"not declared" on the face of the document.

What is genuinely absent is only a summary line tying that to the percentage —
saying that the figure excludes it and by how much. Worth considering, much
smaller than recorded, and not release-blocking.

---

## The findings

Ordered by severity, then file. Duplicates retained.


### CRITICAL

- `firestore.rules:1310` — The update rule protects server-owned fields only through validSkuDraft's absence checks (`!('massStatus' in d)` etc., firestore.rules:1279-1288). An absence check is satisfied by DELETING the field, and unlike every other update path in this file (products:1029, users:495, appeals:1151, sellerApplications:748) this rule pins no `diff(resource.data).affectedKeys()`. A client may therefore remove massStatus, rejectionReason, reviewedBy, reviewedAt, submittedAt, submittedBy, revision, verifiedUnitMassMg/G, verifiedBy, verifiedAt, activeFrom and activeTo in a single write, with no audit entry and no skuRevisions row.
- `firestore.rules:1345` — The `attributions` read grant hands any orgViewer of a producer the full evidence row, which carries `binId`, `disposalDecidedAt` (a Timestamp, second precision) and the real `disposalId` (server/src/attribute.js:403-422). Combined with `bins` being readable by any signed-in user (firestore.rules:610, bins carry lat/lng per server/src/bins.js:124), this is exactly the "map of who throws what where" SEC-3 names as its failure mode. No k-anonymity floor exists anywhere in the repo (grep for kAnon/anonymityFloor/K_MIN/suppress across server/, lib/, firestore.rules returns nothing).
- `lib/controllers/compliance_controller.dart:75` — compliancePositionProvider never checks DeclarationDetail.hasError, so a failed declaration read is rendered as "you have not filed a declaration" — a false statement about the producer's paperwork on both the dashboard card and the SDG page.
- `lib/views/producer/declaration_view.dart:174` — The `_hydrated` guard is a one-shot bool that is never reset when the reporting period changes, so after switching periods the form still holds the previous period's typed figures and saves/files them against the newly selected period.
- `lib/views/producer/declaration_view.dart:174` — The `_hydrated` latch is set once for the life of the screen and is never reset when the reporting period changes, so after switching periods the form keeps the previous period's figures and files them — under attestation — against the new period.
- `server/src/attribute.js:472` — The period-rollup `update` object is a plain object built in a loop over matches, so two matches sharing a computed key (same gazette category, same district, or same polymer) overwrite instead of accumulating — mass is silently dropped from every figure on the Plastic Passport.
- `server/src/index.js:2273` — `supersedeForMassChange` is called on every `setVerifiedMass`, including a SKU's *first* verification, so verifying a brand-new product falsely marks every currently-issued passport for that organisation as superseded.
- `server/src/organizations.js:225` — `txn.set(orgRef, record)` at line 225 precedes `await audit.appendInTransaction(txn, …)` at line 226, whose `txn.get(headRef)` (server/src/producerAudit.js:201) is a read after a write and throws `Firestore transactions require all reads to be executed before all writes.` (@google-cloud/firestore build/src/transaction.js:95-98).
- `server/src/organizations.js:225` — `txn.set(orgRef, record)` (line 225) executes before `await audit.appendInTransaction(txn, ...)` (line 226), and `appendInTransaction` performs `await txn.get(headRef)` at producerAudit.js:200. The Node Firestore SDK's Transaction.get() throws `Firestore transactions require all reads to be executed before all writes` as soon as the write batch is non-empty, and that error is not retryable.
- `server/src/passportPdf.js:537` — The third instance of this module's defining bug is still live: `splitRuns` treats "the Bengali face has a glyph" as "neutral" and hands the character to whichever run is in progress without ever asking `helveticaCovers`, so the 21 code points that Noto Sans Bengali covers and WinAnsi does not are printed as mojibake in BOTH editions, with no error.
- `server/src/passports.js:420` — `issuePassport` assembles every figure OUTSIDE the transaction and its transaction reads nothing a correction writes, so a correction committing in that window produces a permanently-'issued' certificate stating a percentage against a formally withdrawn denominator.
- `server/src/producerSkus.js:93` — The two copies of milligramsFromGrams disagree on any numeric string with trailing junk or a comma. Dart uses double.tryParse (whole-string, returns null on '8.2g', '1,250', '8.2.5', '10kg'); JS uses Number.parseFloat, which stops at the first invalid character and returns the prefix. I ran both: Dart returns null for all four, the server returns 8200, 1000, 8200 and 10000 mg respectively. The file's own comment (line 83-87) claims both copies are tested against the same worked example so a divergence becomes a failing test — but server/test/producerSkus.test.js:50 omits '8.2g', which test/core/mass_math_test.dart:37 asserts must be null, so the divergence is invisible to CI.
- `server/src/producerSkus.js:258` — `saveSkuDraft`'s guard block (lines 258-266) refuses an edit only when the stored `massStatus` is `'submitted'` or `status` is `'retired'`. `'verified'` falls through. The subsequent `txn.update(ref, record)` (line 326) overwrites `name`, `brand`, `gtin`, `gazetteCategory`, `polymer`, `components`, `declaredUnitMassMg`, `declaredUnitMassG`, `sampleImageUrls` and `recognitionHints`, while leaving `massStatus: 'verified'`, `verifiedUnitMassMg`, `revision`, `activeFrom` and `activeTo` exactly as they were. No `skuRevisions` row is opened — the `declarationChanged` reason declared at line 66 and in lib/models/sku_revision_model.dart:23 has no call site anywhere in the codebase. firestore.rules:1313-1314 blocks precisely this edit for the direct client write path (`resource.data.massStatus in ['draft','rejected']`); the server endpoint the app actually uses does not, so the rules and the service disagree and the weaker one is the reachable one.
- `server/src/producerSkus.js:651` — `openRevisionInTransaction` enqueues `txn.set(previousRef, …)` (line 629) and `txn.set(revisionRef, …)` (line 636) and only then calls `audit.appendInTransaction(txn, …)` (line 651), which performs `await txn.get(headRef)` at server/src/producerAudit.js:201. The Admin SDK forbids a read after a write in the same transaction: @google-cloud/firestore 7.11.6 build/src/transaction.js:95-98 throws `Firestore transactions require all reads to be executed before all writes.` unconditionally when `_writeBatch` is non-empty. Both callers are affected: `recordMassAudit` also writes `txn.set(auditRef, …)` at line 483 before reaching it, and `setVerifiedMass` reaches it after the same two revision writes. The module's own contract comment at producerSkus.js:596-598 states this invariant and the function then violates it internally.
- `server/src/producerSkus.js:651` — `openRevisionInTransaction` calls `audit.appendInTransaction` (producerSkus.js:651) after writes have already been staged on the transaction. `appendInTransaction` performs `await txn.get(headRef)` (server/src/producerAudit.js:201). The Firestore Node SDK rejects that: `@google-cloud/firestore/build/src/transaction.js:96` throws `Firestore transactions require all reads to be executed before all writes.` as soon as `_writeBatch` is non-empty. Two staged writes precede the audit read: `txn.set(auditRef, …)` in `recordMassAudit` (line 483) and `txn.set(previousRef, { activeTo: now }, { merge: true })` — the close of the standing revision — in `openRevisionInTransaction` (line 629).
- `server/src/reportJobs.js:288` — `listJobs` runs `where('orgId','==',…).orderBy('requestedAt','desc')` on the `reportJobs` collection, but `reportJobs` has no entry at all in firestore.indexes.json — and no test in the suite ever calls `listJobs`, because the shared fake ignores indexes entirely.
- `server/src/reportJobs.js:545` — `skuPerformance` skips reversed attributions by testing `row.reversed === true`, but attributions have no `reversed` field — reversal is marked by `reversedAt` — so reversed rows are counted into the report's units and mass.
- `server/src/reportJobs.js:653` — `chainOfCustody` emits `reversed: row.reversed === true`, which is always `false` because no writer ever sets a `reversed` boolean — every withdrawn attribution is exported to an auditor as live.

### HIGH

- `firebase.json:1` — `reportJobs.js` is the repo's only Cloud Storage writer, yet firebase.json declares no `storage` target and no `storage.rules` file exists, so the bucket holding every organisation's report artefacts is governed by whatever rules the console holds.
- `firestore.indexes.json:885` — No composite index exists for `reportJobs` on (orgId ASC, requestedAt DESC), so `listJobs` fails with FAILED_PRECONDITION the first time it runs against real Firestore.
- `firestore.indexes.json:885` — No composite index exists for `plasticPassports` on (orgId, periodId, issuedAt), so the reconciliation and variance report always fails.
- `firestore.rules:1254` — `brandKey`, `gtin`, `volumeMl`, `declaredUnitMassG`, `sampleImagePublicIds`, `createdAt`, `updatedAt`, `createdBy` and `updatedBy` appear in the hasOnly list at 1249-1255 and are then never mentioned again in validSkuDraft; `sampleImageUrls` is bounded to six entries but no entry is validated. Every other client-writable collection in this file pins the server clock (`createdAt == request.time` at 261, 477, 743, 1024, 1068, and `updatedAt == request.time` at 561) and pins the actor (`reviewedBy == request.auth.uid` at 751 and 1154). producerSkus does neither, on create or on update — products even re-pins `createdAt == resource.data.createdAt` on update (1035), which this rule omits.
- `firestore.rules:1271` — Lines 1271-1273 check only `components is list` and size 1..12. No element is checked for part/polymer/massMg, and no sum constraint exists — yet the block comment at 1233-1234 states the governing constraint kept in rules is 'within these bounds, summing to the declared total'. The file validates every other bounded list slot by index (validProductImages:816, validProductSearchTokens:836, validCartItems:955), so the omission is not a limitation of rules. The server enforces both (normalizeComponents at producerSkus.js:104 and the exact-equality sum at 180-186); a direct client write skips them entirely.
- `firestore.rules:1300` — `allow create` (line 1300) and `allow update` (line 1310) on producerSkus require only `isOrgMemberAtLeast(orgId,'orgReporter')` plus `validSkuDraft`. Neither `isOrgMemberAtLeast` (line 415) nor any other helper in this file references `request.auth.token.email_verified` — grep finds no occurrence of email_verified anywhere in firestore.rules. producerSkus is, by the file's own comment at line 1227, 'the one EPR collection a client really writes', and the app already uses the client SDK for Firestore everywhere else.
- `lib/controllers/compliance_controller.dart:22` — When the workspace is not `isReady`, `declarationProvider` returns a clean empty `DeclarationDetail` with `error == null` and `attestationText: ''`, while `declarationPermissionsProvider` (line 107) never checks `isReady` — so the screen simultaneously claims nothing was filed and offers an attestation dialog containing no attestation text.
- `lib/controllers/compliance_controller.dart:73` — `compliancePositionProvider` never inspects `detail.hasError`, and `ComplianceService.loadDeclaration` swallows every failure into a successful `DeclarationDetail.failed(...)` rather than throwing, so a network or HTTP failure is rendered on the dashboard as the positive statement that the producer has filed nothing.
- `lib/core/sku_csv.dart:373` — The spec (line 359) puts the 0.1-5000 g bound on declaredUnitMassG, the unit mass. Both implementations apply it per component instead: the CSV parser routes each component mass through milligramsFromGrams (lib/core/mass_math.dart:80 enforces minUnitMassMg = 100), server/src/producerSkus.js:118 checks massMg < MIN_UNIT_MASS_MG per entry, and lib/models/producer_sku_model.dart:124 does the same on read. The rationale in mass_math.dart:40-45 is that a sub-0.1 g mass cannot be verified by physical sampling of a single unit — that argument is about the whole unit, not about a part of it.
- `lib/models/producer_sku_model.dart:313` — componentsSumToDeclared is exact integer equality with no tolerance, deliberately, but the message that explains a failure formats both sides with formatGrams, which rounds to three significant figures. Any discrepancy below the third significant figure prints as two identical numbers. lib/core/sku_csv.dart:308 has the same defect in the downloadable CSV error report. The existing test (test/core/sku_csv_test.dart:159) only uses a 0.5 g gap, which formats distinctly, so the boundary QA-3 asks for is untested.
- `lib/views/producer/declaration_view.dart:302` — _run catches only DeclarationRejected and OrgActionException, so a transport-level failure (timeout, socket drop) during saveDraft/submit/openCorrection escapes uncaught and the filing fails with no message, no error state and no retry.
- `lib/views/producer/producer_sdg_view.dart:178` — _MassHeadline collapses all three RateAbsence values into the single sentence "no put-on-market declaration has been filed for this period", so a filed nil declaration is reported on the SDG page as no filing at all.
- `server/src/appCheck.js:54` — The public verification endpoint `GET /passports/verify/:serial` is absent from `EXEMPT_PATHS`, so turning on App Check — which NFR-E-9/SEC-10 make release-blocking before the first real producer — makes every third-party verification return 401 and renders every issued certificate unverifiable by exactly the audience EPR-29 exists for.
- `server/src/auth.js:308` — `requireOrgRole` resolves only the `organizationMembers/{orgId}_{uid}` document (auth.js:280-282) and then attaches `req.orgMembership` and calls `next()` (auth.js:308). It never fetches `organizations/{orgId}` or inspects its `status`. Every producer write route in index.js derives its tenant from `req.orgMembership.orgId` and therefore inherits the same blind spot. `organizations.createInvitation` is the ONLY code path in the whole feature that checks org status (organizations.js:704), and `setOrganizationStatus`'s own docstring (organizations.js:410-412) states "Suspension makes the portal read-only and stops new issuance." On the client, `OrganizationModel.isReadOnly` (lib/models/organization_model.dart:125) is consumed only by `producer_dashboard_view.dart:110` and `producer_members_view.dart:73` — i.e. suspension is enforced by hiding buttons in Flutter and nowhere else.
- `server/src/index.js:1440` — The handler returns whatever `eprPeriods.listPeriods` produced, and that is the stored document verbatim (server/src/eprPeriods.js:390 `{id: d.id, ...d.data()}`). The document carries `lastAttributionAt: serverTimestamp()`, rewritten on every rollup increment (server/src/attribute.js:469), alongside `disposalCount` and `massMgByDistrict`. Nothing suppresses a period whose counts are below any floor, and no floor is defined. The comment at index.js:1424-1428 asserts "a rollup carries no disposal reference, so there is nothing in it that could correlate an event or a person" — `lastAttributionAt` is precisely such a reference, in time rather than by id.
- `server/src/index.js:1546` — The reconciliation route passes `req.body.carried` unvalidated into `recomputePeriod`, and those client-supplied running totals are written onto the `eprPeriods` document — including `skuIds`, which is the "Distinct products" figure printed on every passport issued afterwards.
- `server/src/index.js:1868` — An unrenderable producer-supplied character produces a permanently undownloadable issued certificate, answered by a 503 whose message is false and which discards the typed diagnostic built for exactly this case.
- `server/src/index.js:2053` — `POST /epr/reports/:jobId/download` guards only on `orgViewer` and never re-checks the report type's `minRole`, so any org member can download the owner-only row-level chain-of-custody export and the other owner-only artefacts.
- `server/src/index.js:2055` — The download route guards only `requireOrgRole('orgViewer')` and `signedUrlFor` never re-checks `REPORT_TYPES[...].minRole`, so the owner-only restriction on `chainOfCustody` and `doeAnnualProgress` is enforced at enqueue and not at delivery.
- `server/src/organizations.js:713` — The pre-flight query is `.where('orgId','==',orgId).where('status','==','pending').limit(MAX_PENDING_INVITATIONS + 1)` — 21 documents — and `live` (line 720) is filtered out of that sample. Nothing ever flips an expired invitation off `status: 'pending'` (stated as deliberate at lines 828-835: expiry is resolved lazily at read time), so stale pending documents accumulate without bound. With no orderBy, Firestore returns the 21 lexicographically smallest document ids, and the document id is the SHA-256 hex of a random token, so the sample is effectively a random 21-document subset of that org's pending invitations.
- `server/src/passportPdf.js:155` — The certificate prints "no put-on-market declaration has been filed for this period" whenever the declared total is zero, so a producer that filed and attested an all-nil declaration is told on its own certificate that it filed nothing — on the same page that names the person who attested it.
- `server/src/passportPdf.js:262` — BOUNDARIES omits the §6.7 statements that EPR-28.5 requires on the document itself: nowhere does the certificate say that no Chokro figure is DoE-approved, certified or accepted, that the obligated entity remains the producer, or that the figures are operational records rather than official environmental measurements.
- `server/src/passportPdf.js:537` — splitRuns' "neutral" branch decides coverage against the Bengali face but then assigns the character to the run in progress (usually Helvetica), so 20 code points the bundled font covers and WinAnsi does not print as mojibake with no error.
- `server/src/passportPdf.js:795` — A nil put-on-market declaration and no declaration at all both reach the PDF as `collectionRate === null`, so the certificate prints "no put-on-market declaration has been filed for this period" on a period where one was filed and attested — contradicting its own Evidence block two sections later.
- `server/src/passportPdf.js:913` — The carbon line on the certificate carries only a factor version string — none of EPR-38's three mandatory caveats and no source citation travel with it, so the artefact never says the figure is UK-derived, not polymer-specific, or conditional on downstream recycling.
- `server/src/passportPdf.js:938` — A nil put-on-market declaration — which `declarations.js` explicitly permits — makes the certificate state "no put-on-market declaration has been filed for this period" on the same page as the declared figure and the attester's name, so the artefact contradicts itself and makes a false statement about the producer's filing.
- `server/src/passports.js:130` — `canonicalPayload` omits every producer-identity field that the certificate actually prints, so two figure sets naming different producers, different DoE registration numbers, different attesters and different obligation years hash identically — and the hash printed on the page therefore does not bind the page's most forgeable content.
- `server/src/passports.js:264` — The certificate's headline collection percentage divides a numerator covering every collected category by a denominator covering only the declared ones, and prints that inflated figure beside the gazette target with none of the disclosure the client screen carries.
- `server/src/passports.js:264` — The headline collection percentage divides mass collected across all gazette categories by mass declared only in the categories the producer chose to declare, and unlike the dashboard the certificate carries no statement that the numerator contains mass missing from the denominator.
- `server/src/passports.js:670` — `supersedeForPeriod` — the only implementation of three of EPR-30's four mandatory supersession triggers — is never called from any production path (only from server/test/passports.test.js:700,717), so a reversed attribution or a re-verified mass silently changes a period whose certificate stays 'issued' with the pre-change figures.
- `server/src/producerAudit.js:122` — The canonical digest input (lines 122-134) covers only previousDigest, orgId, sequence, action, actorUid, targetType, targetId, summary, beforeDigest, afterDigest and timestampIso. The entry written at lines 227-245 additionally stores `actorName`, `actorRole`, `ip`, `userAgent` and `timestamp` (the server clock). None of these participate in the hash, and `verifyChain` never cross-checks `timestamp` against the signed `timestampIso` despite the comment at lines 106-107 claiming the two exist precisely so they can be compared. Crucially, `listForOrg` (line 378) — the source for both the producer timeline (index.js:1181) and the Admin EPR-44 timeline (index.js:1705) — orders by the unsigned `timestamp`, not by the signed `sequence`.
- `server/src/producerAudit.js:246` — `computeDigest` (line 109) is a bare, unkeyed SHA-256 over fields the writer controls, and it is exported (line 392). `producerAuditHeads/{orgId}` is an ordinary mutable document (line 250-255) holding the only out-of-band value verifyChain compares against. Nothing else anchors the chain — no HMAC key, no signature, no external notarisation, no snapshot outside Firestore. Consequently the comment at lines 246-249 ("Rewriting it cannot forge a chain — the digests live in the entries") and the identical claim in firestore.rules:1386-1389 are false: an insider who can write the entries can also recompute their digests.
- `server/src/producerAudit.js:352` — The truncation check is guarded by `complete && head && …`. When `producerAuditHeads/{orgId}` does not exist, `head` is null (line 344-345) and the check is skipped entirely, so with zero surviving entries `findings` is empty, `complete` is `0 < 500` = true, and line 363 yields `intact: true`. The test at server/test/producerAudit.test.js (`a wholly emptied log is detected`) only deletes the entries and leaves the head, so it never exercises this path. Deleting the head is also strictly easier than rewriting it, and the next legitimate append silently restarts at sequence 1 with previousDigest null (line 204-205), producing a fresh, perfectly valid-looking chain.
- `server/src/reportJobs.js:288` — `listJobs` combines an equality filter on `orgId` with `orderBy('requestedAt','desc')` but `firestore.indexes.json` contains no `reportJobs` composite index, so `GET /epr/reports` fails with FAILED_PRECONDITION on every call.
- `server/src/reportJobs.js:599` — The SEC-3 k-anonymity floor guarding the district breakdown is evaluated against the period's TOTAL disposal count rather than per district, so a district containing a single disposal is published whenever the period as a whole clears k.
- `server/src/reportJobs.js:640` — `chainOfCustody` exports raw per-row `district`, `binId` and `date`, bypassing the k-anonymity floor that `geographicRecovery` applies through `projectForProducer`.
- `server/src/reportJobs.js:755` — `reconciliationVariance` queries plasticPassports with two equality filters plus `orderBy('issuedAt','asc')`, a combination no index in firestore.indexes.json serves, and the only test of this report type is the vacuous catalogue loop at reportJobs.test.js:675.
- `server/src/reportJobs.js:816` — `surplusMass` treats a declared-nil denominator as a valid one, so the Surplus mass statement reports a producer's entire collected mass as surplus above the gazette target.
- `server/src/reportJobs.js:1016` — `signedUrlFor` accepts `actorRole` but never compares it against `REPORT_TYPES[job.reportType].minRole`, and the download route only requires `orgViewer` — the suite asserts the minRole *constants* (reportJobs.test.js:661-666) instead of the enforcement, and every delivery test passes `actorRole: 'orgOwner'`.
- `server/src/reportJobs.js:1112` — `year` is validated only as `Number.isInteger` while `twelvePeriodsFrom` treats it as an obligation-year ordinal, so a calendar year produces a DoE annual return of twelve empty periods presented as that year's figures.
- `server/test/eprRouteGuards.test.js:47` — The route-table regex ends every chain at the first literal `(req, res)`, so a route whose handler is not an inline `(req, res)` is dropped from ROUTES entirely and its guards are credited to the preceding route — and the canary at line 120 uses lower bounds far too loose to notice.
- `server/test/reportJobs.test.js:675` — `expect(() => reportJobs.buildReport({...})).not.toThrow()` wraps an `async` function, which never throws synchronously — the assertion cannot fail, so the catalogue-vs-builder check it is named for verifies nothing.

### MEDIUM

- `firestore.rules:1249` — `request.resource.data` on an update is the full post-write document, so it carries every stored key the write did not touch. saveSkuDraft writes massStatus, status, verifiedUnitMassMg:null, verifiedBy:null, verifiedAt:null, activeFrom:null, activeTo:null, revision:0, createdAt and createdBy on create (producerSkus.js:299-308), and a Firestore field set to null is present for `in`. None of those keys are in the hasOnly list at 1249-1255, so hasOnly fails for every real document and the documented path 'a reporter may revise its own declaration' (comment at 1307-1314) is denied outright. The only updates the rule accepts are the field-stripping ones in the finding above, and the `resource.data.massStatus in ['draft','rejected']` lock at 1313 can never be reached with the stored fields intact.
- `firestore.rules:1300` — `producerSkus` is the one EPR collection with a client write path. Its create rule (firestore.rules:1300) and update rule (firestore.rules:1310) both authorise solely through `isOrgMemberAtLeast`, which (firestore.rules:415-420) resolves `isSignedIn() && isActive() && exists(orgMemberPath(orgId)) && orgRoleAtLeast(...)`. `isActive()` is the *user's* platform status from `users/{uid}`; nothing in the chain ever `get()`s `organizations/{orgId}`. So the rules layer, which is the boundary that survives when the Node service is bypassed entirely, has no notion of a suspended tenant. Note this is a distinct enforcement point from the server middleware: even after `requireOrgRole` is fixed, the client SDK path remains open.
- `firestore.rules:1312` — On an update, `request.resource.data` is the merged resulting document, so it contains every field already stored. `saveSkuDraft` writes `massStatus`, `verifiedUnitMassMg`, `verifiedBy`, `verifiedAt`, `activeFrom`, `activeTo` and `revision` on create (server/src/producerSkus.js:299-306) — explicit nulls are present keys in Firestore rules, and `revision: 0` is a value. None of those seven names appear in `validSkuDraft`'s `hasOnly` allowlist (firestore.rules:1250-1256), so `validSkuDraft(request.resource.data, …)` at line 1312 is false for any server-created SKU, and `validSkuDraft`'s own `!('massStatus' in d)` checks (lines 1279-1289) also fire against the merged document. The `resource.data.massStatus in ['draft','rejected']` clause at lines 1313-1314 is therefore dead: it never decides an outcome.
- `firestore.rules:1394` — `match /producerAuditHeads/{orgId} { allow read: if isAdmin(); }` denies org members any sight of the chain head, and the only verification endpoint, GET /epr/admin/organizations/:orgId/audit/verify (server/src/index.js:1723-1725), is behind `requireAdmin`. The producer-facing route (index.js:1174-1189) returns entries only. This contradicts server/src/producerAudit.js:20-23, which justifies the whole design on the grounds that the log is checkable "by anyone holding the log — including the producer whose history it is, and including a Department of Environment inspector".
- `lib/controllers/auth_controller.dart:249` — `signOut` unregisters the push device and then calls `authService.signOut()` (auth_service.dart:20 → `_auth.signOut()`), which clears local state only. There is no `revokeRefreshTokens` call anywhere under server/src and no sign-out endpoint on the service. auth.js:37-50 relies on `verifyIdToken(token, true)` to catch revocation, but nothing in this system ever writes the revocation state that flag reads.
- `lib/core/carbon_math.dart:286` — carbonUncertaintyCeiling is hardcoded at 0.25 on the client while the server's value is admin-configurable down to 0.01, so lowering the policy makes the SDG card show a carbon figure the Plastic Passport for the same period refuses to state.
- `lib/core/carbon_math.dart:286` — `carbonUncertaintyCeiling` is a hard-coded client constant of 0.25 while the server reads a mutable policy value, so lowering the policy makes the dashboard publish an avoided-emissions figure the passport refuses — the exact thing EPR-39 forbids.
- `lib/core/sku_csv.dart:300` — server/src/producerSkus.js:125 returns null from normalizeComponents when components.length > 12, which validateSkuDraft turns into the problem 'Break the product down into parts, each with a known polymer and a mass.' Neither the CSV parser (which caps recognitionHints at 12 on line 334 but leaves components uncapped) nor ProducerSkuModel.submissionProblems (lib/models/producer_sku_model.dart:304) knows about that limit, so the client preview marks such a row valid.
- `lib/views/producer/declaration_view.dart:294` — `_run` guards every `setState` with `if (mounted)` but calls `ref.invalidate` (and `_submit` calls `ref.read`) after an await with no such guard; `WidgetRef` throws a real `StateError` — not a debug assert — once the widget is unmounted, so navigating away during an in-flight save produces an uncaught exception instead of a completed refresh.
- `lib/views/producer/declaration_view.dart:812` — `_VersionHistory` reads `PutOnMarketDeclaration.totalMassMg`, whose getter returns null unless `isUsable` (status == 'submitted'), but the server's `putOnMarketVersions` rows are written with no `status` field at all — so every row in the producer's filing history renders as an em dash instead of its declared mass.
- `lib/views/producer/producer_dashboard_view.dart:299` — The dashboard states the "Applicable collection target" from organization.collectionTargetAt(DateTime.now()) directly above a period selector that reaches back twelve months, so the screen can assert two different gazette targets for the producer at once.
- `lib/views/producer/producer_dashboard_view.dart:329` — EprAbsenceReasons.targetIsNotAnAssessment — the sentence written for exactly the case where a target is shown beside a figure — is rendered only in the branch where no target is known, so it disappears at the moment the screen states whether the producer is at or above the gazette target.
- `lib/views/producer/producer_sdg_view.dart:177` — The SDG view collapses all three `RateAbsence` reasons into the single sentence "no put-on-market declaration has been filed for this period", which is a false statement about the producer's own filing whenever a declaration exists but yields no rate.
- `lib/views/producer/producer_sdg_view.dart:341` — _CarbonDetail renders the carbon estimate with `kg.round()` instead of CarbonEstimate.label, so any non-zero estimate below 0.5 kg is displayed as "0 kg CO2e avoided (indicative)".
- `rules_test/epr_tenancy.rules.test.js:1` — The only EPR rules suite covers organizations, organizationMembers, producerAuditLog and EPR-1 role disjointness. QA-2 (spec lines 1095-1101) requires, by name, 'exact-key allowlists and bounded numbers on producerSkus', 'append-only enforcement on skuRevisions and producerAuditLog', 'orgViewer write denial', 'cross-tenant write denial', and proof 'that the disposals client allowlist has not grown'. None of those five exist in this file or anywhere under rules_test/ for the EPR collections — and the four defects above all sit on the untested producerSkus create/update path.
- `server/src/declarations.js:374` — `submitDeclaration` supersedes nothing, so a passport issued before any declaration existed keeps verifying as 'issued' while printing the now-false sentence that no put-on-market declaration has been filed for the period.
- `server/src/fontkitNullAnchorFix.js:73` — `fontkit` is required directly by the shim (and by passportPdf.js:97) but is not declared in server/package.json — it resolves only because pdfkit hoists it, so npm is free to give the shim and pdfkit two different fontkit copies, in which case install() patches a prototype pdfkit never uses and still reports `patched: true`.
- `server/src/fontkitNullAnchorFix.js:118` — install() verifies only that `applyAnchor` exists — never that the guard still discriminates — the `skipped()` counter it returns is read nowhere in production, and no test in the repo asserts a single glyph position, so a patch that starts skipping EVERY anchor silently degrades mark placement with zero signal.
- `server/src/index.js:938` — PRIVILEGED_AUTH_MAX_AGE_SECONDS is applied via requireFreshAuth only to the membership/invitation and admin decision routes. Every producer read route — /epr/me (1005), /epr/members (1033), /epr/invitations (1051), /epr/audit (1174), and the SKU list/history routes (1196, 1230) — carries only requireAuth + readLimit. No idle timer or absolute session cap exists on the client either: grep for idle/sessionTimeout/lastActivity across lib/views/producer, lib/controllers/producer_workspace_controller.dart and lib/core/constants.dart returns only HTTP request timeouts (ApiConfig.coldStartTimeout).
- `server/src/index.js:982` — The catch block special-cases only `weak_password` and `email_in_use`; everything else falls through to the unconditional `res.status(400).json({error:'invalid_invitation', message:'This invitation link is no longer valid. Ask for a new one.'})` at lines 986-990, discarding err.code and err.message. organizations.js:936-941 deliberately builds `error.code = 'unavailable'` with the message 'The account service is temporarily unavailable', and organizations.js:888 builds 'Enter your name.' — both are thrown away here. eprFailure (index.js:940), which does map `unavailable` to 503, is not used on this route.
- `server/src/index.js:1869` — Issuance never checks that a passport's figures can be rendered, and the download route collapses `unrenderable_text` into the same generic 503 as an outage, so an Admin can mint a certificate whose PDF is permanently undownloadable while the prior valid certificate has already been superseded.
- `server/src/organizations.js:944` — `auth().createUser(...)` at line 944 happens outside the transaction. The compensating `deleteUser` at line 1007 runs only when the transaction body throws, and when it itself fails it only logs (line 1009). Nothing covers the process dying between line 944 and the commit at line 1002. The orphan then trips the existing-account refusal at lines 927-933, and no route in server/src deletes an auth account.
- `server/src/passportPdf.js:344` — bengaliFontAvailable() gates only on file size, and registerFonts opens and patches with the Bengali font for both editions, so a corrupt Bengali file breaks the pure-Latin English edition and a wrong font produces a diagnostic that blames fontkit.
- `server/src/passportPdf.js:757` — heightOfFlow measures a mixed-script string entirely in the dominant run's face, and Helvetica reports zero width for Bengali code points, so the status banner's coloured rectangle is drawn one text line short.
- `server/src/passportPdf.js:916` — The certificate prints the carbon estimate at whole-kilogram precision (up to five significant digits) while every other figure on the page is rounded to three, overstating the precision of a factor whose source reports no uncertainty range and disagreeing with the figure the client derives from the identical stored inputs.
- `server/src/passportPdf.js:950` — The "Applicable gazette target" line and the obligation year are drawn only inside the `else` branch of the collection-rate test, so a certificate for any period with no declaration silently omits the gazette target even though `figures.applicableCollectionTarget` is populated and hashed.
- `server/src/passports.js:415` — `issuePassport` and `assembleFigures` check only that the organisation document exists, never its `status`, and the admin issue route has no equivalent of `requireActiveOrganization` — so a suspended, closed or never-approved organisation can be handed a fresh Chokro-signed certificate that verifies publicly as `issued`, contradicting EPR-47's "portal read-only, no new issuance".
- `server/src/passports.js:429` — The issue route has no idempotency guard and `issuePassport` mints a fresh document id on every call, so a client retry (or an Admin double-click) after a lost response issues a second certificate that supersedes the first over byte-identical figures.
- `server/src/passports.js:670` — `supersedeForPeriod` — the documented handle for EPR-30's three non-declaration supersession triggers — is exported but never called from anywhere in the service, so a certificate whose underlying evidence has changed keeps reporting `issued` on the public verification endpoint.
- `server/src/passports.js:670` — `supersedeForPeriod` is never called from anywhere in the codebase, so EPR-30's non-declaration supersession triggers never fire and a certificate whose underlying period has since changed still verifies as `issued`.
- `server/src/passports.js:692` — `supersedeForPeriod` commits its batch and only then appends the audit entry in a separate transaction, and the batch writes are unconditional — so it can strip a certificate's revocation and can supersede certificates with no audit-chain entry at all (SEC-12).
- `server/src/producerAudit.js:347` — `complete = entries.length < limit` (line 347) and `intact = complete && findings.length === 0` (line 363). The only caller, server/src/index.js:1727, invokes `verifyChain({ orgId })` with no `limit`, so the default 500 applies and the route accepts no `limit` query parameter and implements no `startAfter` paging. Every state-changing action logs an entry (sku.saved on each draft save, member changes, admin views), so 500 is reached by an ordinary active producer.
- `server/src/producerAudit.js:352` — The head carries both `sequence` and `digest` (written together at lines 250-255), but the only cross-check is `(head.sequence || 0) !== lastSeen` at line 352. `head.digest` is never compared with `entries[entries.length - 1].digest`, so a head whose digest contradicts the surviving log passes verification. The test suite likewise asserts only on `expected`/`found` sequence numbers.
- `server/src/producerSkus.js:383` — `submitForVerification` refuses only a re-submission of an already-`submitted` SKU (line 353), so a `verified` SKU can be pushed back to `'submitted'`; `rejectSku` then moves it to `'rejected'` (line 716). Neither `txn.update` touches `skuRevisions/{skuId}_{revision}`, whose `activeTo` remains null. `openRevisionInTransaction` is the only writer of `activeTo` (line 629) and it runs only when a *new* mass is established. The SKU document and the revision row therefore give contradictory answers to "was a verified mass in force at this moment": `ProducerSkuModel.reportableUnitMassMg` (lib/models/producer_sku_model.dart:251) returns null, while `SkuRevisionModel.isCurrent` (lib/models/sku_revision_model.dart:117) and `SkuRevisionModel.wasActiveAt` (line 124) both still return true for the old figure.
- `server/src/reportJobs.js:31` — The module header states "`POST /epr/reports/{jobId}/resume` picks it back up from its cursor" and `enqueue` writes a `cursor` field (line 225), but no code ever reads or advances it — `readAllAttributions` restarts from row zero on every run and accumulates the whole period in memory.
- `server/src/reportJobs.js:225` — The job document's `cursor` field is written as null at enqueue and never updated, so `resume` restarts the read from row zero — a report too large to finish inside one instance lifetime can never complete.
- `server/src/reportJobs.js:288` — `listJobs` runs an equality filter plus an `orderBy` on a different field with no matching composite index declared, so the reports list endpoint fails permanently in production.
- `server/src/reportJobs.js:551` — `skuPerformance` takes `unitMassMgUsed` and `skuRevision` from whichever attribution for that SKU is read first, so a mass re-verification mid-period yields a row whose units × unitMassMgUsed does not equal its massMg.
- `server/src/reportJobs.js:564` — Row ordering uses `String.prototype.localeCompare`, whose collation is locale- and ICU-dependent, so the same scope can serialise in a different order — and hash differently — on two hosts, defeating EPR-34.
- `server/src/reportJobs.js:643` — `chainOfCustody` dates each row from `createdAt` (when the attribution document was written) rather than `disposalDecidedAt` (the time that assigned the period), so rows can carry dates outside the period the report covers.
- `server/src/reportJobs.js:697` — The DoE annual return's `passportRegister` lists the organisation's 50 most recent passports across all time rather than those covering the twelve periods the report is about.
- `server/src/reportJobs.js:755` — `reconciliationVariance` queries `plasticPassports` with two equality filters plus `orderBy('issuedAt','asc')`, a combination for which no composite index is declared, so that report type can never complete.
- `server/src/reportJobs.js:755` — The `reconciliationVariance` report queries `plasticPassports` with two equality filters plus `orderBy('issuedAt','asc')`, a shape no index in `firestore.indexes.json` covers, so that report type always fails.
- `server/src/reportJobs.js:963` — The CSV branch of `serialise` emits only `payload.rows`, so the geographic recovery report's `districtsSuppressed` flag and its explanatory note are silently dropped from the CSV edition.
- `test/compliance_position_test.dart:300` — The test named 'carries no figures' asserts `expect(passport.toString(), isNot(contains('0.95')))`, but `PlasticPassportModel` has no `toString()` override, so the value is always `Instance of 'PlasticPassportModel'` and the assertion cannot fail.

### LOW

- `lib/models/producer_sku_model.dart:373` — milligramsFromGrams is documented (lib/core/mass_math.dart:56-61) as returning null and never a fallback, because a default multiplies into every kilogram reported. ProducerSkuModel.fromJson then writes `declaredUnitMassMg: declaredMg ?? 0`, converting the refusal into the value zero, which massLabel renders through formatGrams as '0 g' — the exact string formatKilograms's own comment (line 184-186) argues must never stand in for an absent figure.
- `lib/models/producer_sku_model.dart:481` — _components maps through SkuComponent.tryParse and then whereType<SkuComponent>(), discarding every entry that fails to parse without recording that anything was discarded. This is the opposite of the discipline in the same feature: sumMilligrams (lib/core/mass_math.dart:109) deliberately reports MassSum.skipped so 'a total that quietly dropped rows is surfaced rather than corrected'. SkuComponent.tryParse (line 110-127) explicitly anticipates documents not written by the current server ('a migration may have written either' massMg or massGrams), so the drop path is reachable by design, and the per-component 0.1 g floor makes it easier to hit.
- `lib/models/put_on_market_model.dart:69` — `PutOnMarketLine.tryParse` falls back to `milligramsFromGrams`, which enforces the single-unit bounds of 100 mg–5,000,000 mg, so any declaration line delivered without `massMg` and heavier than 5 kg is silently dropped from the denominator.
- `lib/views/producer/declaration_view.dart:216` — Contrary to the comments at lines 43-45 and compliance_service.dart:140-143 ("Nothing is converted here" / "the server is the only thing that converts"), the client converts the typed grams to integer milligrams and then back to grams before sending, so the server never receives what the user typed and a sub-milligram figure is silently altered or zeroed.
- `server/src/appCheck.js:54` — EXEMPT_PATHS holds three entries but the comment immediately above it (lines 40-52) says 'Two of them, and each for a stated reason' and then justifies only /health and /epr/invitations/redeem; /epr/password-policy has no stated rationale. The route itself (index.js:957-959) is registered with no requireAuth and no limiter, unlike every other route in the file.
- `server/src/eprPeriods.js:327` — `reverseAttribution` decrements `attributionCount` but never `disposalCount`, so the Evidence block on a certificate can state more disposal events than there are surviving attributions.
- `server/src/eprPeriods.js:390` — `listPeriods` (and `getPeriod` at line 393) return the stored document verbatim. `storeRecomputeResult` writes `recomputedBy: adminUid` into that same document (server/src/eprPeriods.js:164), so the internal Firebase uid of the Chokro employee who ran the reconciliation is shipped to the producer over /epr/periods.
- `server/src/fontkitNullAnchorFix.js:34` — The docblock's measurement — the justification a maintainer will rely on to decide the skip is safe — is factually wrong on both counts: the counts are 3, not 7, and the reph is not a precomposed GSUB glyph.
- `server/src/fontkitNullAnchorFix.js:65` — The docblock names `server/test/passportBanglaShaping.test.js` as the tripwire that stops the shim from silently regressing; that file does not exist in the repository.
- `server/src/fontkitNullAnchorFix.js:138` — On a NULL anchor the patch returns from applyAnchor but fontkit's applyLookup cases 4/5/6 still `return true`, so the remaining subtables of that lookup are never tried — where the OpenType spec and HarfBuzz treat an absent anchor as "this subtable has nothing for this class" and fall through to the next one.
- `server/src/passportPdf.js:417` — install() is called on the English path too, so a shim failure that only concerns Bengali shaping takes down English certificates that need no Bengali glyph at all.
- `server/src/passportPdf.js:597` — `isInvisible` treats newline and tab as strippable, so a multi-line revocation reason is rendered with its sentences run together without any separator.
- `server/src/passportPdf.js:827` — Three figures EPR-28.2 requires on the passport are absent from the rendered document — units, distinct bins/districts, and the unattributed pool — and the unattributed pool's absence lets the certificate read as though every disposal in the period was attributed.
- `server/src/passportPdf.js:1059` — The carbon row hardcodes the English unit 'kg' instead of the localised STRINGS[locale].kg that every other mass on the page uses, so the Bangla edition prints an English unit.
- `server/src/passports.js:285` — `assembleFigures` never reads `unattributedDisposalCount`, so the unattributed pool that EPR-28 lists as required passport content appears on no certificate and in no report.
- `server/src/passports.js:449` — The supersession queries cap at 20 (issuePassport) and 50 (openCorrection, supersedeForPeriod) and no caller checks whether the cap was hit, so a truncated result set silently leaves stale 'issued' certificates behind with no error and no note in the audit summary.
- `server/src/passports.js:628` — `verifySerial` returns a sixth field, `supersededBy`, beyond EPR-29's exhaustive five, handing an unauthenticated caller a second valid serial and a walkable supersession chain on an endpoint SEC-7 designs specifically to defeat enumeration.
- `server/src/passports.js:698` — `verifySerial` returns a sixth field, `supersededBy`, beyond EPR-29's explicit five-field allowlist, disclosing the serial of a certificate the caller was never given.
- `server/src/reportJobs.js:293` — `listJobs` returns each job document verbatim, including `storagePath`, which the single-job poll route deliberately strips — so the private bucket object path for every artefact is handed to every org member.
- `server/test/eprRouteGuards.test.js:185` — 'every admin EPR route requires an admin' filters `adminRoutes()` — itself defined at line 80 as the routes that `has('requireAdmin')` — by `!r.has('requireAdmin')`, so the result is empty by construction and the expectation cannot fail.
- `test/epr_claim_boundaries_test.dart:23` — The QA-4 prohibited-claims scan lists no Phase D screen, so the two most claim-sensitive new surfaces — the declaration form and the passports list — are not checked at all, and adding them would immediately fail on inline copy that duplicates rather than reuses the shared constants.
- `test/producer_sdg_model_test.dart:96` — The 'never claim recycling, a credit, an offset, or jobs' test accepts any sentence containing the bare substring 'not', which matches inside 'another', 'note', 'cannot' and 'nothing', so a sentence making the forbidden claim can satisfy the denial check.

### MEDIUM, `passportPdf.js` — eleven findings, eight distinct

**Six were already closed.** The §6.7 boundary statements are on the
certificate. `splitRuns`' neutral branch now asks BOTH faces, with a comment
naming the exact 17 code points the old version mis-routed. `absentRateSentence`
distinguishes a nil declaration from an absent one. `heightOfFlow` measures
across every face the string uses and takes the maximum. The gazette target is
drawn in the no-rate branch too. And `registerFonts`' recovery path no longer
breaks the Latin-only English edition when the Bengali file is unusable.

**Two were live and are fixed.**

*The carbon figure carried none of EPR-38's three caveats.* The spec is
unambiguous — "Three honest caveats must travel with it in the interface and in
every report" — and the certificate is the most report-like artefact there is.
`lib/core/carbon_math.dart` carried all three for the producer's own screen;
the document a regulator reads carried none. The boundary block's
"indicative... not a verified carbon credit or offset" is EPR-39's
no-offset prohibition, which is a different point. All three are now drawn
beside the figure, in both editions, because EPR-38 says "on the same screen,
not behind a tooltip".

*The carbon figure was rounded differently from every other number on the page.*
`Math.round` prints every digit the arithmetic produced, so an estimate of
51,234 kg printed exactly that beside masses rounded to 51,200.
`carbon_math.dart` states the rule for the client — the same three significant
figures as the masses, "because the factor is an estimate derived from a
different country's electricity mix, so a fourth digit would claim a precision
nothing in the chain supports" — and the certificate both claimed it and
disagreed with the producer's own screen over identical stored inputs.

**A note on how the caveats are tested.** Not by reading the rendered PDF:
PDFKit writes text as positioned glyph runs inside compressed streams, so "does
the page say UK-derived" is not a question the artefact answers to a grep, and
a regression would render perfectly, say nothing, and pass every render test.
The decision is split into `carbonCaveatsFor` and asserted directly; the
rendering path is the same `writeFlow` loop every other block uses. Both
editions were also rendered and inspected by eye.
