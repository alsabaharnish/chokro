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
