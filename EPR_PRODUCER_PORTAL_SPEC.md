# Chokro — EPR Producer Portal

**Product and engineering specification, v1.0**
Prepared 8 September 2026 · Author: Al Sabah Arnish (Chokro / Lamppost)
Audience: Senior Flutter Architect · Mobile Application Security Engineer · Code Quality Auditor

---

## 0. How to read this document

This specifies a new workspace inside the existing Chokro Flutter/Firebase
application: a **producer portal** for companies that are legally obligated
under Bangladesh's 2026 Extended Producer Responsibility (EPR) guidelines, plus
the data machinery that makes the portal's numbers defensible, plus the
administrative oversight that makes them auditable.

It is written for three readers with three different jobs, and it is organised
so that each can find their own sections without reading the others':

| Reader | Read closely | Skim |
|---|---|---|
| Flutter Architect | §3–§9, §13, §14, Appendix B | §11, §12 |
| Security Engineer | §4, §5.2, §6.2, §7.4, §11, §15 | §8, §9 |
| Code Quality Auditor | §5, §6.4, §9, §12, §13, Appendix A | §1, §2 |

**Status of the contents.** §1 is external regulation and is sourced (Appendix
C). §3 is the current state of the codebase and is verified against it. §5–§13
are requirements: they are decided unless a line says otherwise. §15 lists the
questions that are genuinely open, each with a recommendation and the
consequence of choosing otherwise — those are for me and for legal counsel, not
for the implementers to guess at.

**Conventions.** New requirements are numbered `EPR-n` for functional,
`SEC-n` for security, `QA-n` for code quality, `NFR-E-n` for non-functional, so
they can be cited in review comments and commit messages without ambiguity.
They continue the existing `FR-n` / `NFR-n` scheme in
`Chokro_Mobile_Project_Brief v3.md` rather than renumbering it.

**One rule above all others**, inherited from the existing system and extended
here: *no client computes or writes a compliance figure.* Every gram, every
percentage, every certificate is produced by the trusted Node service. The
reasoning is the same reasoning that keeps wallet balances off the client — if
two code paths can write a number that a regulator will read, security rules can
only police one of them.

---

## 1. Why this exists

Bangladesh gazetted **Guidelines for Extended Producer Responsibility (EPR)
Implementation for Plastics on 13 August 2026**, issued by the Ministry of
Environment under section 13 of the Bangladesh Environment Conservation Act,
1995. The guidelines are in force. Their relevant provisions:

- **Who is bound:** producers, importers and brand owners of plastic products.
  Industries producing solely for export orders are excluded.
- **Five plastic categories:** rigid plastic; flexible plastic; Styrofoam/EPS;
  non-prohibited single-use plastic; and "other" products (sanitary napkins,
  diapers, cigarette filters).
- **Targets:** at least **15% collection and 7.5% recycling in years 1–2**,
  rising to **30% collection and 15% recycling** thereafter, with the targets
  subject to review after three years.
- **Phase-in by size:** large industries in years 1–2, medium industries in
  years 3–4, small industries in year 5.
- **Registration:** with the Department of Environment (DoE) within **six
  months** of being listed; a registration is valid for **three years**.
- **Reporting:** **annual progress reports are mandatory** — a registration is
  not renewed without them.
- **Compliance route:** an obligated entity may comply alone or **jointly
  through an approved Producer Responsibility Organisation (PRO)**.
- **Plastic credits** are permitted for waste handled in excess of targets.
- **Enforcement:** the DoE conducts inspections, audits and **data
  verification**; false information can mean suspension or cancellation of
  registration and legal action.

Two of those provisions are the entire commercial thesis of this work. First,
**annual progress reports gate renewal** — so every obligated company needs a
reporting artefact on a fixed clock, from a source it can defend. Second, the
**DoE verifies data** — so the artefact has to survive inspection, which rules
out spreadsheets of self-declared estimates and rules in exactly what Chokro
already produces: attributable, geofenced, timestamped, screened, immutably
ledgered disposal evidence.

The gap the guidelines leave is equally clear, and the Daily Star's editorial on
the gazette named it: a producer cannot physically retrieve its own packaging
from millions of households, and the country lacks a digital reporting system
and a formal payment channel for the collectors who do the retrieving. That is a
description of what Chokro is.

### 1.1 Chokro's position — evidence provider, PRO-ready

**Decided.** Chokro is a **compliance-grade evidence and reporting provider**.
The obligated entity remains the producer; the producer files with the DoE;
Chokro supplies the data, the audit trail and the certificate. Chokro does not
represent itself as discharging anyone's legal obligation, and no screen,
document or PDF produced by this system may imply otherwise (see §6.7).

The data model, however, is built so that Chokro can be **registered as a PRO
later without re-modelling anything** — obligations are already tracked per
producer and per period, evidence is already attributable per producer, and a
PRO simply becomes an additional actor that holds a set of producer obligations.
That is a schema decision, not a claim: see `organizations.complianceRoute` in
§5.1.

### 1.2 What this unlocks beyond compliance

Chokro's reward pool has never had a funder. Three provisions of the gazette
create one:

1. **Obligated demand.** Producers must report; reporting has a price.
2. **Plastic credits.** Surplus collection is a tradable instrument, which
   means attributed kilograms have a market value, not just a reporting value.
3. **The PRO route.** It gives a lawful vehicle for pooling many producers'
   money into one collection programme — which is what pays Champions and
   collectors.

That is the business case. It is in this document only because it explains why
certain integrity controls in §6.2 and §11 are not optional: the moment a
kilogram is worth money, every number in this system becomes an attack surface.

---

## 2. The idea in one page

A producer registers its **products** — not its waste. Coca-Cola Bangladesh
signs in and enters its 250 ml PET bottle: a sample photograph, the polymer
type, the gazette category, and **the mass of one unit — say 10 grams**. Chokro
verifies that declared mass, approves it, and versions it.

From then on, the screening model that already looks at every disposal
photograph is also asked a second question: *which registered products are in
this picture, and how many of each?* When Anik photographs two Coca-Cola 250 ml
bottles going into a registered bin in Mohammadpur, the system records the
disposal as it always has — geofence, photo provenance, duplicate hash, AI
screen, human review if anything is unclear — and then, separately, attributes
**2 × 10 g = 20 g of rigid PET** to Coca-Cola Bangladesh, at that bin, on that
date.

Those grams accumulate. At the end of a reporting period the producer's
workspace shows kilograms collected by gazette category, by month, by district,
by SKU — measured against the units the producer declared it placed on the
market, which is what turns kilograms into the **percentage the gazette actually
asks for**. The producer downloads a **Plastic Passport**: a serialised,
hash-verifiable certificate of what was collected on its behalf, with the
evidence pack behind it. It also sees its SDG alignment and a sourced carbon
figure, both bounded by the same honesty rules the existing Admin SDG dashboard
already follows.

Chokro's Admins see all of it: every company, every SKU declaration awaiting
approval, every anomaly, every certificate issued, and a per-company activity
trail.

**The thing to understand about this design** is where the trust sits. The
producer supplies the unit mass — the one number in the chain it has both the
best knowledge of and an incentive to distort. Chokro verifies it, versions it,
and can re-verify it by physical sampling. The AI supplies the unit count, which
is the number a bin-side photograph can actually support. Neither party supplies
the figure the regulator reads; that is computed, server-side, from an approved
mass and a screened count, and it is reproducible from stored inputs. §6.2 and
§6.4 are therefore the load-bearing sections of this document.

---

## 3. What exists today

The reviewers must not have to re-derive this. Verified against the repository
at commit `561a298`, 8 September 2026.

### 3.1 Built and working

| Area | Where | Relevance to this spec |
|---|---|---|
| Flutter client, Riverpod, go_router, responsive web + mobile | `lib/` | The portal is a new set of routes in this app, not a new app |
| Trusted Node service, Firebase Admin SDK | `server/src/` (25 modules, 22 routes) | Every new compliance write lands here |
| Security rules with exact key allowlists, closed enums, server-only fields | `firestore.rules` (1,062 lines) | New collections follow the same shape |
| Rules tests on the emulator | `rules_test/` | Tenant isolation must be proven here |
| Four-step verified disposal: bin → photo → location → confirm | `lib/views/disposal/`, `server/src/verify.js` | The source of every attributed gram |
| AI photo screening (Groq, `qwen/qwen3.6-27b`), null-on-failure → human review | `server/src/screen.js` | Extended, not replaced, for SKU recognition |
| Immutable points ledger, server-only wallet writes | `server/src/award.js` | The precedent this spec copies |
| Bin registry with geofence radius and printable QR labels | `lib/models/bin_model.dart`, `lib/core/bin_label_pdf.dart` | Geography for reporting; PDF and Bangla font machinery to reuse |
| Client-side PDF generation with Bangla glyph support | `lib/core/pdf_fonts.dart` | Reusable for *drafts* only — see §7.4 |
| Admin dashboard with SDG impact tab and deliberate claim boundaries | `lib/views/admin/sdg_dashboard.dart`, `lib/models/sdg_impact_model.dart` | The methodology precedent §9 must extend, not contradict |
| Platform counters | `stats/platform`, `lib/models/stats_model.dart` | Pattern for period rollups |
| Marketplace, orders, donations, appeals, suspension, lockouts | various | Untouched by this work |

### 3.2 The six gaps this specification closes

1. **No mass.** `disposals` records `declaredItemCount` and a
   `DisposalItemType` enum of seven values. There is no gram, no kilogram, and
   no field that could hold one. EPR is measured in kilograms.
2. **No brand.** Nothing in the schema knows whose packaging was disposed of.
   Attribution is the product.
3. **No gazette taxonomy.** The seven `DisposalItemType` values
   (`plasticBottle`, `plasticOther`, `paper`, `glass`, `metal`, `eWaste`,
   `organic`) do not map onto the gazette's five plastic categories. A
   report cannot be filed in Chokro's vocabulary.
4. **No corporate identity.** Roles are `admin`, `seller`, `buyer`, and they are
   *inclusive* — an Admin holds all three profiles. There is no organisation
   entity, no company account, no multi-user tenancy, and no role that is
   deliberately outside that inclusive hierarchy. A producer must be.
5. **No reporting period.** `stats/platform` is all-time with no baseline and no
   period dimension, which is precisely why the existing SDG dashboard shows no
   progress bars. Compliance reporting is period arithmetic by definition.
6. **No document issuance.** Nothing in the system produces a serialised,
   verifiable, revocable certificate.

### 3.3 Two existing constraints that shape every design below

**There is no scheduler.** Cloud Functions require a billing account and the
free Render instance sleeps, so nothing in this system can wake up and do work
on a timer. The codebase already solves this once, honestly, in
`UserModel.isActiveAt`: temporary suspensions expire *lazily*, resolved at read
time by whoever asks. Compliance rollups must respect the same reality. They are
therefore **incremented transactionally at attribution time** and
**recomputable on demand**, never "generated nightly" (§6.4, §13).

**There is no cursor paging.** `AppConstants` caps are mostly ceilings, not page
sizes, and eleven streams once had no limit at all. A producer's annual report
spans potentially hundreds of thousands of disposals; it can never be a client
query. This is the reason period rollups exist as stored documents (§5.1).

---

## 4. Identity, tenancy and roles

### 4.1 `producer` is a disjoint role, not another inclusive profile

**EPR-1.** Add one stable wire role value, `producer`, to
`AppConstants` alongside `roleAdmin` / `roleSeller` / `roleBuyer`, with the
user-facing label **"EPR Producer"**.

**This role must not join the inclusive hierarchy.** Today an Admin holds
Greenpreneur and Champion, and a Greenpreneur holds Champion, because those are
progressive citizen profiles. A producer is a company employee doing regulatory
work; giving them a Champion wallet by inheritance would let a corporate account
earn and spend points, which is both meaningless and an integrity hole. The
architect must therefore review every place the inclusive assumption is encoded
— `lib/core/account_profile.dart`, `canAccessAdminRoutes` and the gate logic in
`lib/routing/router.dart`, `activeRouteRedirect`, the profile switcher, and the
`isAdmin()` / role helpers in `firestore.rules` — and make the disjointness
explicit rather than emergent.

**EPR-2.** Existing invariant 7 ("selecting a profile never grants a role")
extends verbatim: selecting an organisation never grants membership. Both the
rules and the server middleware authorise against stored membership documents,
never against a client-supplied `orgId`.

### 4.2 Organisations and membership

**EPR-3.** A producer user belongs to exactly one organisation in v1. An
organisation has members with **organisation-scoped capabilities**, distinct
from the platform role:

| Org role | Can |
|---|---|
| `orgOwner` | everything below, plus invite/remove members and submit put-on-market declarations |
| `orgReporter` | create and edit SKUs, request mass verification, generate reports, download passports |
| `orgViewer` | read dashboards and download already-issued reports only |

Rationale for three and not one: the person who knows a bottle's gram weight is
a packaging engineer, the person who signs a regulatory declaration is a
compliance officer, and the person who wants the SDG slide is in marketing. One
shared login for all three is how credentials get pasted into group chats.

### 4.3 Sign-in — email invitations, not usernames

**Requested as "login with their user name and password". Recommended
change, and the reason.**

Chokro's authentication is Firebase email/password throughout. Adding usernames
means adding a public username→account lookup, which is an account-enumeration
surface and a support burden ("which of our four usernames was it?"), for no
gain: a company employee has a work email and it is the address a password reset
must go to anyway.

**EPR-4.** Producer accounts are created by **invitation**: an Admin approves
the organisation, then an `orgOwner` (or an Admin) invites members by work email
address. The invitation is a single-use, time-limited, server-issued token (see
SEC-9). Self-registration into a producer organisation is not possible — a
company's compliance data is not something anyone should be able to join by
filling in a form.

If a username-style login is a hard commercial requirement, the acceptable
implementation is an alias resolved **server-side only** to the account's email
before Firebase sign-in, with per-IP rate limiting and identical failure
messages for "no such alias" and "wrong password". It is listed in §15 as an
open decision because it is a product call, not an engineering one.

### 4.4 Multi-factor authentication

A corporate compliance portal should have MFA. The honest constraint: Firebase
Auth's TOTP/SMS second factor requires **Identity Platform**, which requires
billing to be enabled on the project — the same billing barrier that already
shapes the no-scheduler decision and the iOS push situation.

**EPR-5.** Ship v1 with: mandatory email verification, a strong-password policy
enforced server-side at invitation redemption, idle and absolute session
timeouts on the portal (§SEC-10), and login-notification email to the org owner.
**Design for** TOTP behind a feature flag so that enabling Identity Platform is
a configuration change and not a re-architecture. Enrolling MFA before a
producer's first passport is issued is the target; §15 records the decision.

---

## 5. Data model

All new collections are **server-owned by default**. The client-writable surface
is deliberately tiny: SKU drafts, put-on-market drafts, and cart-like
ephemera — nothing else. Everything a regulator would read is written by the
Node service with the Admin SDK.

### 5.1 New collections

Field types are Firestore types. **(S)** marks server-only fields — no client
write path exists, Admins included, in the manner of `wallets` and `orders`.

**`organizations/{orgId}`**
```
legalName            string        registered legal name
tradeName            string        brand-facing name
bin                  string  (S)   Business Identification Number
tradeLicenceNo       string  (S)
doeRegistrationNo    string? (S)   DoE EPR registration, if issued
sizeClass            enum    (S)   large|medium|small  gazette phase-in
obligationStartDate  timestamp (S) from sizeClass + listing date
complianceRoute      enum    (S)   self|pro     PRO-ready, see 1.1
status               enum    (S)   pendingReview|active|suspended|closed
categories           array   (S)   subset of the five gazette categories
contactName/Email/Phone  string
address, district, city  string
verifiedBy           string? (S)   admin uid
verifiedAt           timestamp?(S)
createdAt            timestamp (S) server clock
```

**`organizationMembers/{orgId}_{uid}`** — composite id, so membership is a
single-document read in rules with no query.
```
orgId, uid           string  (S)
orgRole              enum    (S)   orgOwner|orgReporter|orgViewer
status               enum    (S)   invited|active|removed
invitedBy            string  (S)
invitedAt/activatedAt/removedAt    timestamp? (S)
```

**`producerSkus/{skuId}`** — the product registry. This is the one collection
with a real client write path, on the same test the codebase already applies to
`products`: the governing constraint ("the owning org's reporter, in good
standing, within these bounds") is expressible where it is enforced.
```
orgId                string        set on create, immutable
name                 string        "Coca-Cola 250 ml PET bottle"
brand                string
gtin                 string?       barcode (GTIN), if any
volumeMl             number?
gazetteCategory      enum          rigid|flexible|eps|singleUse|other
polymer              enum          pet|hdpe|pvc|ldpe|pp|ps|other|multilayer
components           array         [{part, polymer, massGrams}] per part
declaredUnitMassG    number        sum of components, 0.1 - 5000 g
sampleImageUrls      array         2–6 own-folder image URLs
sampleImagePublicIds array         proves the images are this org's
recognitionHints     array         label colours, wordmark, shape
massStatus           enum    (S)   draft|submitted|verified|rejected|superseded
verifiedUnitMassG    number? (S)   the figure reporting uses
verifiedBy/At        (S)
activeFrom/activeTo  timestamp (S) effective-dated; see §6.2
revision             number  (S)   monotonic
status               enum          draft|submitted|active|retired
createdAt            timestamp     server clock
```

**`skuRevisions/{skuId}_{revision}`** **(S, append-only)** — the immutable
history of every declared and verified mass, with who changed it and why. A
report issued last quarter must remain reproducible after a producer edits a
gram weight this quarter. Without this collection that is impossible, which
makes it a compliance requirement rather than a nicety.

**`skuMassAudits/{auditId}`** **(S)** — a physical re-weighing: sample size,
measured mean grams, standard deviation, weighing location, operator uid,
photograph of the scale, verdict (`withinTolerance` | `outsideTolerance`),
resulting action. This is what makes a declared mass a verified mass (§6.2).

**`putOnMarketDeclarations/{orgId}_{periodId}`** — units and mass the producer
placed on the market in a period, per category and optionally per SKU. Client
(orgOwner) writes a **draft**; submission, locking and any correction after
submission are server operations, and every version is retained. Without this
collection, Chokro can report kilograms but not the **percentage** the gazette
requires (§6.5).

**`attributions/{attributionId}`** **(S)** — one document per (disposal, SKU)
pair. The atomic evidence record.
```
disposalId, orgId, skuId, skuRevision     string
binId, district, city                     string
gazetteCategory, polymer                  enum
units                                     number   recognised count
unitMassGUsed                             number   verified mass then in force
massGrams                                 number   units × unitMassGUsed
method                                    enum     aiSku|barcode|humanReview|manualAdmin
confidence                                number?  model confidence
confidenceTier                            enum     high|medium|low
periodId                                  string   YYYY-MM, Asia/Dhaka
disposalDecidedAt                          timestamp
createdAt                                 timestamp
reversedBy/At/Reason                      string?  reversed, never deleted
```

**`eprPeriods/{orgId}_{periodId}`** **(S)** — the rollup that makes reporting
possible without unbounded reads. Counters incremented in the same transaction
that writes the attribution, plus a recompute stamp so a rebuilt total can be
compared against the incremented one.
```
orgId, periodId
massGramsByCategory     map      category → grams
unitsByCategory         map
massGramsByDistrict     map
attributionCount        number
disposalCount           number
uniqueSkuCount          number
estimatedShare          number   share of mass from medium-confidence
lastAttributionAt       timestamp
recomputedAt            timestamp?
recomputeMatched        bool?
```

**`recyclingReceipts/{receiptId}`** **(S)** — a downstream recycler's
acknowledgement of mass received, with the custody chain that links it back to
bins and dates. This is the *only* lawful basis for a recycling figure as
opposed to a collection figure (§6.6). Out of scope for v1 delivery, in scope
for v1 schema, because a report template that has no place to put it will be
rebuilt later.

**`plasticPassports/{passportId}`** **(S)** — issued certificates: serial,
orgId, period, scope, figure snapshot, content hash, storage reference, issuer
uid, issuedAt, `status` (`issued` | `superseded` | `revoked`), supersededBy,
revocationReason.

**`emissionFactors/{factorId}`** **(S)** — the versioned, sourced factor
registry (§9.2). A carbon number that cannot name its factor and its source does
not ship.

**`producerAuditLog/{entryId}`** **(S, append-only)** — actor, org, action,
target, before/after digest, IP, user agent, timestamp. Covers every membership
change, mass verification, declaration submission, passport issuance and
revocation, and every report export.

**`reportJobs/{jobId}`** **(S)** — asynchronous report generation: requested
scope, status, progress, output reference, expiry. Reports are not generated
inside a request/response cycle (§13).

### 5.2 Changes to existing collections

**EPR-6.** `disposals` gains **server-only** fields and nothing else:
`skuMatchCount`, `attributedMassGrams`, `gazetteCategoryResolved`,
`attributionStatus` (`none` | `pending` | `attributed` | `unattributable`).
Every one is written by the service. The client create allowlist in
`firestore.rules` **must not grow by a single key** — if a client can write a
mass, the mass is worthless.

**EPR-7.** `screen.js` gains an SKU-recognition response block. The existing
`screenConfidence` / `screenItemCount` / `screenBinVisible` / `screenWasteInBin`
fields keep their exact current meanings; the points decision continues to read
only those. See §6.3 and the warning in §6.8.

**EPR-8.** New composite indexes in `firestore.indexes.json`:
`attributions(orgId ASC, periodId ASC, createdAt DESC)`;
`attributions(orgId ASC, skuId ASC, createdAt DESC)`;
`attributions(disposalId ASC)`;
`producerSkus(orgId ASC, status ASC, createdAt DESC)`;
`producerSkus(massStatus ASC, createdAt ASC)` for the admin queue;
`organizationMembers(uid ASC, status ASC)`;
`plasticPassports(orgId ASC, issuedAt DESC)`;
`producerAuditLog(orgId ASC, timestamp DESC)`.
The auditor should reject any producer-facing screen that needs an index not
listed here without a written reason.

---

## 6. The mass chain — how a gram becomes a compliance figure

This is the heart of the system. Read it as a single argument: each subsection
closes a hole that would otherwise make the final number indefensible.

### 6.1 Registration of a product and its declared unit mass

**EPR-9.** An `orgReporter` creates an SKU with everything in §5.1's
`producerSkus`, and cannot submit it without: at least two sample photographs
taken against a plain background, a gazette category, a polymer, and a
**component breakdown** whose masses sum to `declaredUnitMassG`.

The component breakdown is not bureaucracy. A 250 ml PET bottle is a PET body,
an HDPE or PP cap and often a PVC or PET label sleeve — three polymers and three
gazette-relevant masses in one object the AI will see as one bottle. Reporting
category totals from a single blended figure is wrong in a way that a DoE audit
would find. Declaring components lets one recognised unit contribute grams to
more than one polymer line while remaining one unit.

**EPR-10.** Bulk entry matters: a beverage company has dozens of SKUs. Provide
CSV import with a strict template, per-row validation, an all-or-nothing preview
and a downloadable error report. Do **not** accept a CSV that sets any
server-owned field.

### 6.2 Verifying the declared mass — the integrity crux

The producer declares the number that multiplies into every kilogram Chokro will
ever report on its behalf. Consider the incentives honestly:

- **Overstating** unit mass inflates collected kilograms — the numerator — and
  makes target attainment look better, and inflates any plastic credit.
- **Understating** put-on-market figures shrinks the denominator, with the same
  effect.
- Both are "false information" within the meaning of the gazette's enforcement
  clause, which puts Chokro in the middle of a legal exposure if its
  certificates simply repeat what a producer typed.

**EPR-11.** A declared mass is never used for reporting. Only
`verifiedUnitMassG` is, and it is set by Chokro through one of:

1. **Physical sampling** — Chokro weighs *n* ≥ 5 units of the SKU on a
   calibrated scale, records mean and standard deviation, photographs the scale
   reading, and writes a `skuMassAudits` document. Default acceptance tolerance:
   **± 10%** of declared, with the measured mean adopted as verified when it
   falls outside. (The tolerance and *n* are policy values, stored in
   `config/eprPolicy` in the manner of the existing points policy, not
   constants in code.)
2. **Documentary verification** — a manufacturer's technical data sheet or
   packaging specification, attached and checked by an Admin, for SKUs Chokro
   cannot obtain.
3. **Admin override**, always with a stated reason, always logged.

**EPR-12.** Verified masses are **effective-dated and never edited in place**.
A change writes a new `skuRevisions` row, sets `activeTo` on the old revision
and `activeFrom` on the new one. Every attribution stores the `skuRevision` and
the `unitMassGUsed` it actually used. This is what makes last quarter's passport
still true after this quarter's re-weighing — and it is the difference between a
reproducible report and a report that quietly rewrites history.

**EPR-13.** Re-verification is periodic, not one-off: an SKU whose verified mass
is older than the policy interval (default 12 months) or whose attributed mass
in a period exceeds a policy threshold is queued for re-sampling. Packaging is
light-weighted constantly; a 2026 bottle weighs less than a 2024 one.

**EPR-14.** An SKU registered by one organisation for a **brand it does not
own** is fraud with a clear motive — claiming a competitor's collected mass, or
claiming a popular brand's. Onboarding therefore requires brand-ownership
evidence (trade licence, trademark registration or a written authorisation from
the brand owner) and the Admin queue must surface **brand-name collisions across
organisations** as a blocking flag.

### 6.3 Recognition at the bin

**EPR-15.** `screen.js` is extended, not replaced. The model is additionally
given a **candidate SKU shortlist** and asked to return, as strict JSON, a list
of `{skuId, units, confidence}` alongside its existing verdict fields.

The shortlist matters for cost and for accuracy. Sending a full national product
catalogue in a prompt is neither affordable nor accurate. Shortlist by: the
declared `DisposalItemType`, the bin's district, and the SKUs most frequently
matched at that bin — capped (default 40 candidates), with the cap in
`config/eprPolicy`.

**EPR-16.** Every existing discipline in `screen.js` is inherited without
exception: **it never throws; every failure returns null; a null recognition
result means "not attributed", never "attributed as generic", and never an
approval.** A screening outage must degrade attribution, not disposal.

**EPR-17.** Confidence tiers decide what happens to a match:

| Tier | Default threshold | Outcome |
|---|---|---|
| `high` | ≥ 0.85 | attributed automatically |
| `medium` | 0.60–0.85 | attributed, flagged, included in the **sampling audit queue** and counted in `estimatedShare` |
| `low` | < 0.60 | **not attributed**; queued for human confirmation |

Thresholds live in `config/eprPolicy`. Chokro must also run a **standing
accuracy audit**: a policy-set random percentage of high-confidence matches
(default 2%) is human-reviewed regardless, and the measured precision/recall is
published inside every report's methodology section. A recognition system whose
accuracy is unmeasured cannot support a regulatory claim, and the DoE's data
verification power means someone will eventually ask.

**EPR-18. The barcode path, which should be preferred wherever it is
available.** Visual brand recognition of a crushed bottle in a dim bin at dusk
is a hard computer-vision problem. Reading a GTIN barcode is a solved one.
Add an optional barcode-scan step to the disposal flow — the app already holds
camera and QR-scanning machinery for bins — and treat a scanned GTIN that
resolves to a registered SKU as a `barcode`-method attribution at `high` tier
without model involvement. Where a Champion scans, accuracy stops being
probabilistic. Consider a small sponsor-funded incentive for scanning; see the
warning in §6.8 before deciding.

**EPR-19.** Unmatched mass is **never invented**. A disposal that yields no SKU
match is recorded as `unattributable` and contributes to a visible
**unattributed pool**, reported as its own line. If a category-average estimate
is ever introduced, it must be a distinct `method` value, excluded from the
headline figure, shown separately, and labelled as an estimate on every surface
including the PDF. §15 records this as a decision to take deliberately, not
drift into.

### 6.4 The arithmetic, stated exactly

**EPR-20.** For each attributed pair:

```
massGrams = units × unitMassGUsed(skuRevision active at disposalDecidedAt)
```

evaluated in **integer milligrams internally** and rounded once, at the point of
display or export, to three significant figures for kilograms. Floating-point
accumulation across hundreds of thousands of rows is how two reports of the same
period end up disagreeing in the third decimal, and a regulator who spots that
disagreement is entitled to distrust everything else.

**EPR-21.** Attribution runs **only after a disposal reaches a terminal
approved state** (`autoApproved` or `manualApproved`), inside the same trusted
service that already commits the decision, and it is **idempotent on
`disposalId`** in the manner of the existing award path. A rejected disposal
never attributes. An appeal that overturns a rejection attributes on approval; an
attribution that must be undone is **reversed** with a reason, never deleted
(`reversedBy`/`reversedAt` in §5.1).

**EPR-22.** The same transaction increments the `eprPeriods` rollup. A separate
Admin-triggered, resumable **recompute job** rebuilds a period from
`attributions` and records whether the rebuilt total matched the incremented one.
Given §3.3's no-scheduler reality, this is the substitute for a nightly
reconciliation, and the match/mismatch flag is itself a reportable control.

**EPR-23.** Period boundaries are **Asia/Dhaka calendar months**, `periodId`
formatted `YYYY-MM`, derived on the server from the disposal's decision
timestamp. Not the client's clock, not UTC. A December/January boundary error in
an annual filing is a compliance error.

### 6.5 The denominator — put-on-market

**EPR-24.** The gazette's targets are percentages of what a producer placed on
the market. Chokro can measure the numerator; only the producer knows the
denominator. So:

- An `orgOwner` submits a **put-on-market declaration** per period: units and
  mass per gazette category, with SKU-level detail where available.
- The declaration is **attested** — a named person, a date, and explicit text
  stating that false information is an offence under the guidelines.
- Once submitted it locks; corrections create a new version and both are
  retained, and any passport issued against the superseded version is marked
  superseded (§7.3).
- **No percentage, no target status and no compliance-sounding statement is
  displayed anywhere for a period with no submitted declaration.** The
  workspace shows kilograms collected and says plainly that the percentage
  cannot be computed until the declaration is filed. This is the same discipline
  the existing SDG dashboard already applies when it refuses to show progress
  bars against absent baselines.

### 6.6 Collection is not recycling

**EPR-25.** The gazette sets two different targets — 15% collection and 7.5%
recycling in years 1–2. Chokro's evidence supports the **collection** number
today: a photographed, geofenced, screened disposal into a registered bin is a
collection event. It does **not** support a recycling number, because nothing in
the system yet observes material arriving at a recycler.

v1 therefore reports collection, and every report states in its own text that
the recycling line is **not** covered by Chokro's evidence. Closing that gap
needs the `recyclingReceipts` custody chain — bin → collector → aggregator →
recycler, each hop acknowledged by the receiving party — and that is a v2
programme with real-world onboarding, not a schema change. Shipping a recycling
percentage without it would be exactly the "false information" the enforcement
clause contemplates.

### 6.7 What this system must refuse to claim

**EPR-26.** These are hard prohibitions, enforceable in code review and covered
by tests (QA-4):

- No screen, report or PDF states or implies that Chokro has discharged a
  producer's legal obligation, or that a figure is DoE-approved, certified or
  accepted.
- No figure is presented as an official measurement of an environmental outcome
  where it is an operational record of activity — the existing SDG dashboard's
  language is the standard to match.
- No recycling percentage without recycler receipts (§6.6).
- No compliance percentage without a submitted put-on-market declaration (§6.5).
- No carbon figure without a named, versioned, sourced factor (§9.2).
- No number whose provenance cannot be traced field-by-field to stored inputs.

### 6.8 A warning the architect should read twice

**Mass must stay out of the points path in v1.**

It is tempting to award bonus points for a branded, recognised item — it would
drive scanning and improve attribution. It would also couple the reward economy
to the compliance economy, and that coupling has two consequences. First, it
turns the recognition model into a payout oracle, which means every weakness in
brand recognition becomes a way to mint points: print a wordmark, photograph it,
repeat. Second, it gives Champions an incentive to *mis*state what they are
disposing of, which pollutes the very dataset a regulator will audit.

**EPR-27.** In v1, SKU attribution changes no points, no wallet balance and no
ledger entry. `decide.js` reads exactly the fields it reads today. If a
brand-sponsored multiplier is later wanted, it belongs in the bounded campaign
mechanism (named material, named bins, fixed date window, capped total spend,
server-held policy), where its cost is capped and its abuse is contained — not
in the attribution path.

---

## 7. The Plastic Passport

The producer's headline deliverable, and the artefact most likely to be handed
to a regulator, a buyer's sustainability team or a journalist. It has to be
worth trusting.

### 7.1 What it is

**EPR-28.** A **Plastic Passport** is a per-organisation, per-period,
per-scope PDF certificate stating what Chokro's evidence shows was collected on
that producer's behalf. It contains:

1. **Header** — Chokro identity, the producer's legal and trade name, DoE
   registration number if held, the period covered in Asia/Dhaka dates, the
   passport serial, issue timestamp, and a QR code linking to the verification
   page (§7.2).
2. **The figures** — mass collected by gazette category and by polymer; units;
   number of distinct disposal events; number of distinct bins and districts;
   the unattributed pool; and, only if a put-on-market declaration exists, the
   collection percentage against it with the applicable gazette target stated
   beside it.
3. **Photographic evidence** — the producer's own approved SKU sample images,
   plus a bounded sample of **privacy-gated** disposal photographs (§7.4).
4. **Methodology** — how mass was derived (verified unit mass × recognised
   units), the verified mass and revision used per SKU, recognition accuracy as
   last measured, `estimatedShare` for the period, and the factor version behind
   any carbon figure.
5. **Boundaries** — the §6.7 statements, in plain language, on the document
   itself. Not in a footnote in six-point type.
6. **Integrity block** — the SHA-256 hash of the canonical figure payload, the
   issuing Admin, and the document's revision/supersession status.

Bangla and English editions of every passport, using the existing
`lib/core/pdf_fonts.dart` glyph handling. A certificate a Bangladeshi regulator
cannot read in Bangla is a design failure.

### 7.2 Verification

**EPR-29.** A public endpoint — `GET /passports/verify/{serial}` — returns
**only**: whether the serial exists, its status (`issued` / `superseded` /
`revoked`), the organisation's trade name, the period, and the content hash. It
returns no figures, no evidence, no member details, no contact information. Its
purpose is to let a third party confirm that the PDF in their hand is the
document Chokro issued and has not been superseded — nothing more. See SEC-7.

### 7.3 Revocation and supersession

**EPR-30.** A passport is immutable once issued. Reissue **supersedes**; it does
not overwrite. Any of these events must supersede every affected passport
automatically and notify the organisation: a corrected put-on-market
declaration, a re-verified unit mass that changes a period already certified, a
reversed attribution above a policy materiality threshold, or an accuracy audit
that invalidates a batch of matches. Revocation (fraud, error, organisation
closure) is Admin-only, always with a recorded reason, and always visible on the
verification endpoint.

### 7.4 Generation, signing and the photograph problem

**EPR-31.** Passports are **generated server-side**. The existing client-side
PDF machinery (`bin_label_pdf.dart`, `pdf_fonts.dart`) may generate an
on-screen **draft preview**, watermarked `DRAFT — NOT AN ISSUED CERTIFICATE`,
but a client-rendered file can never be the authoritative artefact: the client
does not hold the serial, the hash or the signing key, and a certificate a user's
device produced is a certificate a user's device can alter.

**EPR-32. The photographs are a privacy hazard, and the largest one in this
specification.** Disposal photographs are taken in public by ordinary people.
They can contain bystanders' faces, house numbers, vehicle plates, shop signage
and precise geolocation in EXIF. Putting a sample of them into a document handed
to a multinational's compliance team, unfiltered, is a data-protection incident
waiting for the Bangladesh Personal Data Protection Act to give it a name.

Requirements, all of them mandatory:

- Only photographs that have passed an **explicit publication gate** may appear
  — reusing the consent-and-review pattern the codebase already implements for
  eco-action photocards, not inventing a looser one.
- **EXIF is stripped** on the served derivative; no coordinates, no device
  identifiers, no capture timestamps beyond the date already stated.
- A human Admin approves every image that enters a passport. No automatic
  selection.
- No Champion name, email, uid, points balance or any other identifier appears
  anywhere in the document or its metadata (SEC-3).
- Default to the producer's own SKU sample images plus **aggregate bin-context
  photographs**; treat individual disposal photographs as an opt-in enhancement
  that a producer can request and an Admin can refuse.

---

## 8. Report suite

**EPR-33.** Beyond the passport, the portal produces:

| Report | Audience | Contents | Format | Cadence |
|---|---|---|---|---|
| **DoE annual progress report** | Department of Environment | Registration details, category masses, collection % against declaration, methodology, evidence summary, gazette-target comparison, recycling-gap statement | PDF + structured export | Annual, on the producer's registration clock |
| **Period collection statement** | Producer's compliance team | Monthly/quarterly mass by category, polymer, district, SKU; trend; unattributed pool | PDF + XLSX | Monthly |
| **SKU performance report** | Packaging and brand teams | Per-SKU units and mass recovered, recognition confidence mix, verified mass and revision used | XLSX | On demand |
| **Geographic recovery report** | Producer + city corporations | Mass by district, city and bin cluster, with bin counts and active-bin coverage | PDF + XLSX | On demand |
| **Chain-of-custody export** | Auditors, DoE data verification | Row-level attributions: attribution id, disposal id (pseudonymous), bin, date, SKU, revision, units, unit mass, mass, method, confidence — **no personal identifiers** | CSV + JSON | On demand |
| **Audit pack** | DoE inspection | The above plus mass-audit records, SKU revision history, accuracy-audit results, recompute reconciliation, passport register | ZIP | On demand |
| **Plastic-credit statement** | Producer, credit counterparties | Surplus mass above target, by category and period, with the eligibility caveats spelled out | PDF | On demand, once the credit framework is understood (§15) |
| **Reconciliation / variance report** | Chokro Admin + producer | Incremented vs recomputed totals, reversals, superseded passports, declaration versions | PDF | Per period close |

**EPR-34.** Every report carries, on its first page: the generating system and
version, the exact period in Asia/Dhaka, the generation timestamp, the requesting
user, a content hash, and the same §6.7 boundary statements. Two reports of the
same scope and period must be **byte-identical apart from the generation
timestamp and requester** — determinism is what lets an auditor compare their
copy to the producer's.

**EPR-35.** Reports are produced by a **job**, not a request: `POST
/epr/reports` enqueues, `GET /epr/reports/{jobId}` polls, output is fetched
through a **short-lived signed URL** (SEC-6). A year of attributions is not
something to stream into a Flutter widget, and the free-tier service will not
hold a connection open long enough to try.

---

## 9. The producer dashboard — SDG alignment and carbon

The existing Admin SDG dashboard set a standard this section is bound by. It
maps activity to selected UN targets, refuses to sum overlapping goal cards,
shows no progress bars against absent baselines, and states in the interface
that its signals are operational records and not official indicators or proof of
environmental outcomes. It specifically declines to invent kilograms, avoided
emissions, jobs or income.

This work changes exactly one of those constraints: **kilograms now exist**, and
they exist with a documented derivation. Everything else stands.

### 9.1 Per-organisation SDG view

**EPR-36.** A company-scoped SDG view, deriving from a new
`ProducerSdgSnapshot` model in the same shape as the existing
`SdgImpactSnapshot` — a pure, testable derivation with **no arithmetic in the
view**.

| Alignment | Signal now available | Required interpretation |
|---|---|---|
| Goal 12, Target 12.5 | Mass collected by category, and collection % where a declaration exists | Collected and attributed, not recycled. Overlaps Goal 11 — cards are not additive |
| Goal 11, Target 11.6 | Geographic recovery across districts and bins | Recovery from registered bins, not municipal waste-diversion measurement |
| Goal 13, Target 13.3 | Carbon avoided, per §9.2, plus participation counts | A factor-based estimate with a stated boundary and uncertainty, not a measured or verified reduction |
| Goal 8, Target 8.3 | Collector and Champion participation attributable to this producer's material | Participation records; not employment, income or job creation |
| Goal 17 | Producer participation in a shared reporting infrastructure | Descriptive |

**EPR-37.** Every card states its period, its source fields, and — where mass
includes medium-confidence matches — the `estimatedShare` for that period. A
producer that cannot see how much of its number is uncertain will publish the
number as if it were certain.

### 9.2 Carbon — a sourced factor registry, not a coefficient in code

**EPR-38.** Carbon avoided is computed as

```
kgCO2e avoided = Σ over materials ( tonnes collected × factor(material, version) )
```

where every factor is a document in `emissionFactors` carrying: material,
factor value, unit, system boundary, geography, source citation, publication
year, version, `activeFrom`/`activeTo`, and the uncertainty the source itself
reports. **A factor without a citation cannot be written**, and a report pins
the factor version it used so the figure remains reproducible when the registry
is updated.

**Starting point for the registry, with a real source.** Turner, Williams and
Kemp (2015) derive avoided-emission factors for source-segregated recycling of
**−1,024 kg CO₂e per tonne of mixed plastics** collected for recycling
(alongside −314 for mixed glass and −8,143 for aluminium cans), on an
avoided-virgin-production boundary. That is a defensible v1 default and it is
citable. Three honest caveats must travel with it in the interface and in every
report:

1. It is a **UK-derived** factor. Bangladesh's electricity mix, transport
   distances and reprocessing routes differ, so the figure is indicative rather
   than national. Sourcing or commissioning a Bangladesh-specific factor is a
   genuine research contribution and a v2 item.
2. It is **mixed plastics**, not polymer-specific. Polymer-specific factors
   should replace it as they are sourced, which is why the schema keys factors by
   material.
3. The benefit is realised **only if the material is actually reprocessed** —
   which loops back to §6.6. Until recycler receipts exist, the carbon figure is
   explicitly labelled as **conditional on downstream recycling**, and the
   interface says so on the same screen, not behind a tooltip.

**EPR-39.** Prohibited outright: an unsourced factor; a "trees equivalent" or
"cars off the road" conversion; any wording that presents the estimate as
verified, offset-grade or tradable; and any carbon figure at all for a period
whose `estimatedShare` exceeds a policy ceiling.

---

## 10. Administrative oversight

Arnish's requirement — "admin should be able to track each company and their
activities" — becomes the following, and the reviewers should treat it as
first-class product rather than a back office.

**EPR-40. Producer directory.** All organisations with status, size class,
obligation start, registered SKU count, verified-mass coverage (what share of
active SKUs have a verified mass), current-period attributed mass, last passport
issued, and outstanding declarations. Sortable, filterable, bounded query with a
disclosed cap in the `AppConstants` manner.

**EPR-41. Onboarding review queue.** Legal identity documents, brand-ownership
evidence, size classification (which sets the gazette phase-in), and category
scope. Approve / reject / request-more-information, each with a reason recorded.
Brand-collision detection across organisations is a blocking flag (EPR-14).

**EPR-42. Mass verification queue.** Every SKU in `submitted` state, oldest
first, with the declared components, the sample photographs, any prior revision,
and the audit-entry form. This queue is the single most consequential screen in
the system: it is where a number that will appear on regulatory filings is
accepted or refused.

**EPR-43. Declaration review.** Put-on-market submissions with
period-over-period variance highlighted. A declaration that moves 60% against
the previous period without a note is either a business change or a manipulation
and either way an Admin should see it.

**EPR-44. Per-company activity timeline.** A single chronological view over the
`producerAuditLog`: member invited, SKU submitted, mass verified, declaration
filed, report generated, passport issued, passport superseded. Exportable. This
*is* the "track each company and their activities" requirement.

**EPR-45. Anomaly detection**, as an Admin queue rather than an automatic
block, with the policy thresholds stored in config:

- attributed mass for one SKU jumping beyond a multiple of its trailing average
- one bin producing an implausible share of one brand's attributed mass
- one Champion account attributed a disproportionate share of one brand
- recognition confidence distribution drifting for a specific SKU (usually a
  packaging redesign the producer has not declared)
- declared unit mass more than the tolerance away from the category's own
  distribution for comparable products
- collection percentage crossing a gazette target within days of a period close

**EPR-46. Read-only "view as organisation".** An Admin can see exactly what a
producer sees, in a visually distinct read-only mode, with the view recorded in
the audit log. There is **no impersonation** — no Admin action is ever taken
under a producer's identity, because an audit trail that cannot distinguish the
two is not an audit trail (SEC-12).

**EPR-47. Issuance register and controls.** Every passport and report ever
issued, with the ability to supersede or revoke, and a reason. Ability to
suspend an organisation (portal read-only, no new issuance) without deleting its
history.

**EPR-48. Reconciliation console.** Trigger and monitor recompute jobs, see
incremented-vs-recomputed variance per organisation and period, and see the
standing accuracy-audit results (EPR-17) with their trend.

---

## 11. Security requirements

For the Mobile Application Security Engineer. These are requirements, not
suggestions, and each has a stated failure mode because a control whose purpose
is not understood gets refactored away.

**SEC-1. Tenant isolation is the primary control.** Every producer-facing read
and write is scoped by a **stored membership document**, never by a
client-supplied `orgId`. In `firestore.rules`, membership is resolved by direct
`get()` on the composite-id `organizationMembers/{orgId}_{uid}` — a single
document read, no query — and the same check is re-applied in server middleware.
*Failure mode:* one company reads another's compliance data, which is the single
most damaging incident this product can have.

**SEC-2. Custom claims are a cache, not the authority.** If `orgId` and
`orgRole` are mirrored into Firebase custom claims for rule performance, the
server must still verify against the stored document on every write, because a
claim is only as fresh as the client's last token refresh — a removed member
keeps a valid token until it expires. Membership revocation must therefore take
effect **server-side immediately**, and the rules must not treat a claim as
sufficient for a write. *Failure mode:* a dismissed employee exports the
company's data on the way out.

**SEC-3. Producers never see a Champion's identity.** No uid, name, email,
phone, photograph of a person, wallet balance or points figure crosses into any
producer-facing surface, response payload, export or PDF. Row-level exports use
a **per-organisation pseudonymous disposal reference**, not the real
`disposalId`, so two organisations cannot correlate the same event or the same
person across their exports. Any producer-facing aggregate broken down finely
enough to isolate individuals (a single bin, a single day) is suppressed below a
policy **k-anonymity floor** (default k = 5). *Failure mode:* Chokro leaks a
map of who throws what where, to a commercial party, in a jurisdiction now
legislating on personal data.

**SEC-4. No client write to any compliance field.** Extends existing invariant 1
verbatim to: attributions, verified unit masses, period rollups, submitted
declarations, passports, factors and audit-log entries. The client create
allowlists for `disposals` must not gain a single key (EPR-6). Rules tests must
prove each denial, including for an Admin. *Failure mode:* the entire evidentiary
value of the system evaporates.

**SEC-5. Server-side authorisation on every new route**, in the existing
`requireAuth` + role-middleware pattern, plus a new `requireOrgRole(orgId,
minRole)` that reads live membership. No route infers authorisation from the
request body. *Failure mode:* an `orgViewer` submits a legal declaration.

**SEC-6. Report artefacts are private and short-lived.** No public bucket, no
guessable path, no permanent URL. Fetched only through a signed URL that is
scoped to the requesting user, expires in minutes, and is single-use where the
storage layer allows it. Every download is logged with actor, org and artefact.
*Failure mode:* a passport URL forwarded in an email becomes a permanent
unauthenticated data feed.

**SEC-7. The verification endpoint is deliberately impoverished** (EPR-29): it
must not become a data-leak or enumeration surface. Serials are **non-sequential
and unguessable** — a random component, not `CHOKRO-2026-0001` — the endpoint is
rate-limited per IP through the existing `rateLimit.js`, and it returns the same
shape for unknown and revoked serials rather than distinguishing them by error
class. *Failure mode:* a competitor enumerates every certificate Chokro has ever
issued.

**SEC-8. Invitations.** Cryptographically random (≥ 128 bits), single-use,
expiring (default 72 hours), bound to the exact invited email, revocable, and
rate-limited per organisation. Redemption requires setting a password that meets
the server-side policy. Invitation state transitions are audit-logged. *Failure
mode:* an intercepted or replayed invitation link mints access to a company's
compliance workspace.

**SEC-9. Session handling on the portal.** Idle timeout and absolute maximum
session lifetime, both shorter than the consumer app's; re-authentication
required before the privileged actions — submitting a declaration, verifying a
mass, issuing a passport, changing membership. Sign-out revokes refresh tokens
server-side, not just locally. *Failure mode:* an unattended office desktop.

**SEC-10. Firebase App Check** is already a known gap in Chokro's security
posture and it stops being deferrable here. Without it, the Firestore and
service endpoints accept traffic from any client bearing a valid token,
including scripts. Enforce App Check on the Node service and on Firestore before
the first real producer is onboarded. *Failure mode:* automated scraping or
write-attempt traffic against a corporate dataset.

**SEC-11. Abuse and cost controls.** Report generation and exports are
rate-limited and quota-capped per organisation and per user; the AI recognition
path has a per-period spend ceiling with a defined degradation behaviour (fall
back to no attribution, never to invented attribution); shortlist size is capped
(EPR-15). *Failure mode:* one organisation's export loop exhausts the Firestore
read budget or the model quota for everyone.

**SEC-12. Audit log integrity.** `producerAuditLog` is append-only in the rules
for every principal including Admins, entries are hash-chained (each carries a
digest of the previous entry for its organisation) so removal is detectable, and
the log is included in the audit pack. No impersonation exists anywhere in the
system (EPR-46). *Failure mode:* an insider edits history, and nothing Chokro
issues can be defended.

**SEC-13. Personal data governance.** Bangladesh's Personal Data Protection Act
work is already on Chokro's radar with a real deadline and a need for legal
counsel; this feature materially increases exposure because it introduces
commercial third-party recipients of data derived from individuals' activity.
Required before launch: a documented data-flow map showing exactly what crosses
to a producer; a retention schedule per collection (attributions and audit
entries have a compliance-driven retention that is *longer* than a Champion's
right-to-erasure expectation — that tension needs a lawyer's answer, not an
engineer's); EXIF stripping (EPR-32); and updated consent language for Champions
that says their disposal activity contributes to aggregate producer reporting.

**SEC-14. Threat model — who gains what, and what stops them.**

| Adversary | Gain sought | Control |
|---|---|---|
| Producer inflates declared unit mass | inflated kilograms, credits | Verified mass only (EPR-11); physical sampling; tolerance; revisions (EPR-12); mass-audit records in the audit pack |
| Producer understates put-on-market | flattering percentage | Attested declaration; variance review (EPR-43); retained versions; supersession (EPR-30) |
| Producer registers a rival's brand | claims another's mass | Brand-ownership evidence and collision flags (EPR-14) |
| Champion farms one brand | points, and skewed brand data | Attribution is outside the points path (EPR-27); existing lockouts, duplicate-hash and cap checks; per-account anomaly queue (EPR-45) |
| Fabricated or reused photographs | fake collection evidence | Existing photo-provenance, duplicate-hash and geofence controls; native capture requirement; the web client's known inability to prove live capture must be disclosed in report methodology |
| Org member exfiltrates data | competitive intelligence | Org roles (EPR-3); export quotas and logging (SEC-6, SEC-11); no personal data to exfiltrate (SEC-3) |
| Cross-tenant read attempt | rival's compliance position | Rules-level membership isolation with emulator tests (SEC-1) |
| Forged or altered passport | false compliance evidence | Server-side issuance and hashing (EPR-31); verification endpoint (EPR-29); non-sequential serials (SEC-7) |
| Insider (Chokro Admin) abuse | favourable numbers for a client | Append-only hash-chained log (SEC-12); no impersonation; reason required on every override; recompute reconciliation (EPR-48) |

---

## 12. Code quality requirements

For the Code Quality Auditor. These extend the conventions the codebase already
holds itself to.

**QA-1. Derivation lives in models, never in views.** `ProducerSdgSnapshot`,
mass arithmetic, percentage computation, period resolution and carbon
calculation are pure, injectable and unit-tested. A widget that performs
arithmetic on a compliance figure is a defect regardless of whether the output
is currently correct — the existing `sdg_impact_model.dart` is the precedent and
its comment ("the view contains no hidden impact arithmetic") is the rule.

**QA-2. Rules tests are mandatory, per denial.** New `rules_test/` suites must
prove, at minimum: cross-tenant read denial; cross-tenant write denial;
`orgViewer` write denial; Admin denial on attributions, rollups, passports and
audit entries; append-only enforcement on `skuRevisions` and
`producerAuditLog`; exact-key allowlists and bounded numbers on `producerSkus`
and declaration drafts; and that the `disposals` client allowlist has **not**
grown.

**QA-3. Arithmetic is tested at the boundaries**, not just the happy path:
integer-milligram accumulation over large row counts; rounding at three
significant figures; a revision boundary crossed mid-period; a reversal after a
period rollup; Asia/Dhaka month boundaries including the December/January roll;
malformed and negative persisted counters parsing to zero (the existing
`stats_model.dart` behaviour); and a recompute that disagrees with the
incremented total surfacing rather than silently correcting.

**QA-4. A traceability test for prohibited claims.** Every figure rendered in a
producer-facing surface must be traceable to stored source fields. Enforce it as
a test over the report/passport composition layer that asserts: no percentage
without a declaration; no recycling figure at all; no carbon figure without a
resolved factor version; and that the §6.7 boundary statements are present in
every generated document. §6.7 is not a documentation convention — it is
testable, so test it.

**QA-5. Determinism test.** Generating the same report twice over the same data
yields byte-identical output apart from generation timestamp and requester
(EPR-34). Golden-file tests for the passport PDF at both language editions.

**QA-6. Wire-value stability.** `producer`, the org roles, gazette categories
and polymer values are stored strings and are **never renamed** once written,
following the existing rule for `admin`/`seller`/`buyer`. Display labels are
mapped separately, as `AppConstants.roleLabel` already does.

**QA-7. Migration discipline.** Every schema addition ships with a documented,
resumable, idempotent backfill script that can be dry-run, in the manner of
`server/scripts/`. Nothing depends on a field existing in historical documents;
readers tolerate absence (the codebase's existing tolerance of a null
`createdAt` on freshly registered users is the model).

**QA-8. Gates unchanged and green.** `flutter analyze lib test` clean;
`flutter test` fully passing (687 tests at the time of writing — the count only
goes up); `npm test --prefix server`; the emulator rules suite; and
`firebase deploy --only firestore:rules --dry-run` compiling. No new analyzer
suppressions without an inline reason.

**QA-9. Documentation obligations.** An `INTEGRATION_NOTES_EPR.md` in the
established style — product shape, reporting contract with its interpretation
column, data and failure behaviour, main implementation files, verification —
and a `Chokro_Mobile_Project_Brief` revision entry. The reporting-contract table
in the existing `INTEGRATION_NOTES_SDG_DASHBOARD.md` is the format to copy.

**QA-10. Bounded reads everywhere.** Every new query has a disclosed cap in
`AppConstants` or is a job (EPR-35). No unbounded stream reaches production,
which is the same rule that closed the eleven unbounded streams already found in
this codebase.

---

## 13. Non-functional requirements

**NFR-E-1. Platform.** The portal is **Flutter web** in the existing codebase,
under `/producer/*` routes, laid out for a desktop browser (the existing 900 px
breakpoint and rail logic apply). No new mobile navigation destination is added;
the tested five-item Admin navigation stays as it is. Producer routes on a
handset render read-only summaries rather than a cramped compliance workspace.

**NFR-E-2. No scheduler.** Nothing may depend on timed background execution
(§3.3). Rollups increment transactionally; recomputes are triggered; renewal and
declaration reminders are computed **lazily at read time**, in the pattern of
`UserModel.isActiveAt`, and shown as due/overdue when someone opens the
workspace.

**NFR-E-3. Report latency.** A monthly report completes within 60 seconds of job
start at 50,000 attributions in the period; an annual audit pack within 10
minutes. Jobs are resumable and report progress. The free-tier service sleeps —
the client must tolerate a cold start and say so rather than appearing broken,
reusing `server_warmup.dart`.

**NFR-E-4. Bangla.** Bangla is a launch requirement for producer-facing
documents and a same-release requirement for the portal interface. A regulator
receiving an English-only certificate about Bangladeshi waste is being asked to
do Chokro's work.

**NFR-E-5. Accessibility and layout.** The existing standard holds: legible at
320 logical pixels with 2× text scaling, cards collapsing to one column, no
overflow. Wide data tables scroll inside their own container.

**NFR-E-6. Offline.** Producers are on desks and do not need offline. The
Champion-side change (barcode scan, EPR-18) **does**, and it must not make the
disposal flow require another live round trip — a disposal that fails at the bin
because a barcode lookup timed out is a worse product than no barcode path at
all. Resolve the GTIN opportunistically and attribute later, server-side.

**NFR-E-7. Cost.** Attribution adds one model call per approved disposal (or
extends the existing one) plus a bounded number of reads and one transaction. It
must be modelled against the existing per-user cost figures before launch, with
the recognition spend ceiling of SEC-11 in place. The shortlist cap exists for
this reason as much as for accuracy.

**NFR-E-8. Retention and reproducibility.** Attributions, revisions, audit
entries, declarations and issued passports are retained for at least the DoE's
audit horizon (three-year registration cycle plus margin; confirm with counsel
per SEC-13). Any report ever issued must remain reproducible from retained
inputs for that whole period.

**NFR-E-9. Deployment.** Portal origins must be added to the service's
`ALLOWED_ORIGINS`; the loopback development flag must never be set in
production. Signed-URL storage configuration and App Check enforcement are
release-blocking, not follow-ups.

---

## 14. Delivery plan

Five phases. Each ends in something demonstrable, and each is independently
shippable — deliberately, because the regulatory clock and the sales
conversation will not wait for all five.

**Phase A — Tenancy and identity.** `producer` role as a disjoint role;
`organizations` and `organizationMembers`; invitation flow; admin onboarding
review queue; producer directory; audit log; `/producer` shell with an empty
dashboard; App Check enforcement.
*Exit:* a company can be approved, invited, sign in, and see nothing but its own
empty workspace — and the rules tests prove it can see nothing else.

**Phase B — Product registry and verified mass.** `producerSkus`,
`skuRevisions`, `skuMassAudits`, CSV import; the Admin mass-verification queue;
effective-dated verified masses.
*Exit:* Coca-Cola's 250 ml bottle exists, declared at 10 g, verified by Chokro,
with a revision history — and no attribution yet exists anywhere.

**Phase C — Attribution.** `screen.js` SKU recognition with the shortlist,
confidence tiers, human confirmation queue, barcode path; `attributions` and
`eprPeriods` written transactionally with the disposal decision; recompute job;
accuracy audit sampling.
*Exit:* Anik's two bottles become 20 g of rigid PET attributed to Coca-Cola in
`2026-09`, visible in the producer dashboard, reproducible by recompute, and
awarding no additional points.

**Phase D — Declarations, reporting and the passport.** Put-on-market
declarations; report jobs; the report suite; server-side passport generation,
hashing, serials, verification endpoint, supersession and revocation; SDG and
carbon views with the factor registry.
*Exit:* a producer downloads a Bangla and English Plastic Passport for a period,
a third party verifies its serial, and the collection percentage appears only
because a declaration was filed.

**Phase E — Oversight, hardening and audit readiness.** Anomaly queues;
reconciliation console; audit pack; per-company activity timeline; retention
implementation; penetration testing against SEC-1 through SEC-14; the accuracy
figures published in report methodology.
*Exit:* Chokro can survive a DoE data-verification request on a real
producer's filing.

**Sequencing note for the architect.** Phase C is the only phase that touches
the existing disposal decision path, which is the most safety-critical and
most-tested code in the repository. It should be built behind a flag, with
attribution failure proven never to affect a disposal outcome, and it should be
the phase that gets the disproportionate share of review time.

---

## 15. Open decisions

Each needs an answer from me (with counsel where noted) before the phase that
depends on it. Each carries a recommendation and the cost of the alternative.

1. **Username login (§4.3).** *Recommend:* email invitations only.
   *If usernames are required:* server-side alias resolution with uniform
   failure messages and per-IP limits, accepting the enumeration risk.
   *Needed before:* Phase A.
2. **MFA and Identity Platform (§4.4).** *Recommend:* enable billing and ship
   TOTP before the first paying producer; feature-flag it now. *Otherwise:*
   corporate customers with security review processes will ask, and "not
   available" is a poor answer. *Needed before:* Phase A close.
3. **Mass verification tolerance and sample size (EPR-11).** *Recommend:*
   ± 10%, n ≥ 5, in `config/eprPolicy`. Wants a defensible basis — ideally a
   documented method note. *Needed before:* Phase B.
4. **Category-average estimates for unmatched mass (EPR-19).** *Recommend:*
   not in v1. Attributing only what is recognised is a smaller number and a
   defensible one, and a defensible number is the product. *Needed before:*
   Phase C.
5. **Branded-item incentive (§6.8).** *Recommend:* no points effect in v1;
   revisit only through the bounded campaign mechanism. *Needed before:*
   Phase C.
6. **Bangladesh-specific emission factor (§9.2).** *Recommend:* ship with
   Turner et al. (2015) fully cited and caveated; pursue a national factor as a
   research output. *Needed before:* Phase D.
7. **Plastic credits (§8).** The gazette permits them; the operational
   framework — who issues, who verifies, how they transfer — needs research
   before Chokro reports a credit-eligible surplus. *Recommend:* report surplus
   mass, call it surplus, do not call it credits until the framework is
   understood. *Needed before:* Phase D.
8. **PRO registration (§1.1).** Whether Chokro applies to be an approved PRO,
   and when. Changes the commercial model and the legal obligations, not the
   schema. *Needed before:* commercial commitments, not code.
9. **Retention versus erasure (SEC-13).** How long attributions derived from an
   individual's activity are kept, and what a Champion's deletion request means
   for a producer's already-issued certificate. **Legal counsel required.**
   *Needed before:* Phase D.
10. **Pricing and contract terms.** Not an engineering question, but it
    determines whether quotas are per-seat, per-SKU or per-tonne, and quotas are
    an engineering question. *Needed before:* Phase D.
11. **Disposal photographs in passports (EPR-32).** *Recommend:* default to SKU
    sample images and bin-context photographs; treat individual disposal
    photographs as opt-in with Admin approval per image. *Needed before:*
    Phase D.

---

## 16. Out of scope for v1

Named explicitly so nobody builds them by inference:

- Any recycling percentage, and the full bin → collector → aggregator →
  recycler custody chain (schema stubbed, §6.6).
- Collector accounts with real bKash/Nagad payouts.
- Weighing at collection as a mass source. This specification's mass comes from
  the SKU registry; scale-based mass is a complementary future source, and where
  both exist they must be reconciled rather than summed.
- Multi-organisation membership for one user; PRO-as-actor holding many
  producers' obligations.
- Direct DoE system integration or electronic filing.
- Credit trading, marketplace or transfer mechanics.
- A second material vertical (e-waste, sanitary waste) or the textile/jhut
  marketplace.
- A native mobile producer app.

---

## Appendix A — The worked example, end to end

Numbers are illustrative; the point is that every one of them is traceable.

1. **Onboarding.** Coca-Cola Bangladesh is approved as an organisation:
   `sizeClass: large`, so its gazette phase-in is years 1–2 and its applicable
   targets are 15% collection / 7.5% recycling. Its compliance officer is
   invited as `orgOwner`; a packaging engineer as `orgReporter`.
2. **Registration.** The engineer registers `Coca-Cola 250 ml PET bottle`:
   category `rigid`, components — PET body 8.2 g, PP cap 1.3 g, PET label
   0.5 g — `declaredUnitMassG: 10.0`, four sample photographs, GTIN recorded.
3. **Verification.** Chokro weighs five units: mean 9.8 g, SD 0.2 g — within the
   ± 10% tolerance. `skuMassAudits` records the sample, the scale photograph and
   the operator. `verifiedUnitMassG: 9.8`, revision 1, `activeFrom` today.
   **Reporting uses 9.8, not the declared 10.0.**
4. **Disposal.** Anik scans bin `MHP-014` in Mohammadpur, photographs two
   bottles going in, passes the geofence at 4 m, the photo hash is unique, and
   the screen returns `binVisible: true`, `wasteInBin: true`, count 2, type
   `plasticBottle`. The disposal auto-approves and credits Anik's points exactly
   as it does today.
5. **Attribution.** In the same transaction as the decision, recognition returns
   `{sku: cocacola-250-pet, units: 2, confidence: 0.91}` — `high` tier. The
   service writes one `attributions` document: 2 × 9.8 g = **19.6 g**, of which
   16.4 g PET body, 2.6 g PP cap, 1.0 g PET label; bin `MHP-014`; district
   Dhaka; `periodId 2026-09`; `method: aiSku`; revision 1. `eprPeriods`
   `cocacola_2026-09` increments. **Anik's points do not change.**
6. **The month.** 412,000 units recognised across 38 SKUs → 3,940 kg attributed;
   `estimatedShare` 6.2% from medium-confidence matches; 1,180 kg in the
   unattributed pool, reported as its own line.
7. **Declaration.** The compliance officer files September put-on-market:
   61,000 kg rigid plastic, attested and locked.
8. **The figure.** 3,940 ÷ 61,000 = **6.5% collection**, shown beside the
   applicable 15% target, with the recycling line stated as **not covered by
   Chokro's evidence**.
9. **Carbon.** 3.94 t × −1,024 kg CO₂e/t (Turner et al. 2015, mixed plastics,
   avoided-virgin boundary, factor version `mixedPlastics-2015-uk-v1`) ≈
   **4,030 kg CO₂e avoided**, labelled UK-derived, mixed-polymer, and
   conditional on downstream recycling.
10. **The passport.** Serial `CHKR-PP-9F2K-7T4D`, issued by an Admin,
    figures hashed, Bangla and English editions, methodology and boundaries
    printed on the document, verifiable at `/passports/verify/CHKR-PP-9F2K-7T4D`.
11. **Later.** A November re-weighing finds the bottle light-weighted to 9.1 g.
    Revision 2 opens with `activeFrom` in November; September's passport remains
    correct because its attributions stored revision 1 and 9.8 g. Nothing is
    rewritten.

---

## Appendix B — File-level change map

Orientation for the architect, not a substitute for their own design.

**New Flutter**
```
lib/models/       organization_model.dart, org_member_model.dart,
                  producer_sku_model.dart, sku_revision_model.dart,
                  attribution_model.dart, epr_period_model.dart,
                  put_on_market_model.dart, plastic_passport_model.dart,
                  emission_factor_model.dart, producer_sdg_model.dart
lib/core/         epr_categories.dart (gazette taxonomy + polymer enums),
                  mass_math.dart (integer-milligram arithmetic, rounding),
                  epr_period.dart (Asia/Dhaka period resolution),
                  carbon_math.dart (factor application)
lib/services/     organization_service.dart, producer_sku_service.dart,
                  attribution_read_service.dart, epr_report_service.dart,
                  passport_service.dart, emission_factor_service.dart
lib/controllers/  producer_dashboard_controller.dart, sku_controller.dart,
                  declaration_controller.dart, report_job_controller.dart,
                  admin_mass_queue_controller.dart,
                  admin_producers_controller.dart
lib/views/producer/   dashboard, skus (list/edit/import), declarations,
                      reports, passports, members, settings
lib/views/admin/      admin_producers_view.dart, admin_mass_queue_view.dart,
                      admin_declarations_view.dart, admin_anomalies_view.dart,
                      admin_issuance_register_view.dart,
                      admin_reconciliation_view.dart
lib/routing/router.dart   /producer/* routes, producer gate, disjoint-role
                          handling in canAccessAdminRoutes and profile logic
lib/core/constants.dart   roleProducer, roleProducerLabel, new read caps
```

**New server**
```
server/src/organizations.js   onboarding, membership, invitations
server/src/producerSkus.js    submission, verification, revisions, audits
server/src/attribute.js       recognition → attribution → rollup, idempotent
server/src/skuShortlist.js    candidate selection and cap
server/src/eprPeriods.js      increment and recompute
server/src/declarations.js    put-on-market submit, lock, version
server/src/passports.js       generation, serial, hash, supersede, revoke, verify
server/src/eprReports.js      job queue, generators, signed URLs
server/src/emissionFactors.js registry and version pinning
server/src/producerAudit.js   append-only hash-chained log
server/scripts/               backfills, factor seed, recompute CLI
```

**Modified**
```
server/src/screen.js     SKU recognition block; existing verdict semantics
                         and null-on-failure behaviour unchanged
server/src/decide.js     unchanged in behaviour — verify by test (EPR-27)
server/src/index.js      new routes with requireAuth + requireOrgRole
server/src/auth.js       requireOrgRole, requireProducer
firestore.rules          new collections; membership isolation; append-only
                         enforcement; disposals allowlist unchanged
firestore.indexes.json   EPR-8 indexes
lib/models/disposal_model.dart   server-only attribution fields (read-only)
```

**New tests**
```
rules_test/         organizations, membership isolation, sku ownership,
                    attribution denial, audit append-only, allowlist regression
test/               mass_math, epr_period, carbon_math, producer_sdg,
                    passport golden (bn + en), report determinism,
                    claim-boundary traceability
server/test/        attribution idempotency, shortlist, rollup vs recompute,
                    declaration versioning, passport supersession,
                    recognition-failure degradation
```

---

## Appendix C — Sources

Regulatory:

- "Bangladesh enforces 2026 EPR guidelines, divides plastic products into 5
  categories", *The Financial Express*, August 2026.
  https://thefinancialexpress.com.bd/home/bangladesh-enforces-2026-epr-guidelines-divides-plastic-products-into-5-categories
- "Producers now responsible for plastic waste management", *The Daily Star*,
  August 2026.
  https://www.thedailystar.net/business/economy/news/producers-now-responsible-plastic-waste-management-4252936
- "Govt issues EPR guidelines on plastic waste management", *The Business
  Standard*, August 2026.
  https://www.tbsnews.net/bangladesh/environment/govt-issues-epr-guidelines-plastic-waste-management-1520431
- "Plastic producers must clean up their own mess" (editorial), *The Daily
  Star*, August 2026.
  https://www.thedailystar.net/opinion/editorial/news/plastic-producers-must-clean-their-own-mess-4254051
- Waste Concern, "Guidelines for Extended Producer Responsibility (EPR)
  Implementation for Plastics in Bangladesh".
  https://wasteconcern.org/guidelines-for-extended-producer-responsibility-epr-implementation-for-plastics-in-bangladesh-under-the-project-entitled-integrated-approach-toward-sustainable-plastics-use-and-mar/

Emission factors:

- Turner, D. A., Williams, I. D., & Kemp, S. (2015). Greenhouse gas emission
  factors for recycling of source-segregated waste materials. *Resources,
  Conservation and Recycling*, 105, 186–197.
  https://doi.org/10.1016/j.resconrec.2015.10.026
  — mixed plastics −1,024 kg CO₂e per tonne collected for recycling; mixed glass
  −314; aluminium cans −8,143. Open access (CC BY-NC-ND). No editorial notices
  as of 8 September 2026.
- Almeida, C., Loubet, P., & da Costa, T. P. et al. (2021). Packaging
  environmental impact on seafood supply chains: A review of life cycle
  assessment studies. *Journal of Industrial Ecology*, 26(6), 1961–1978.
  https://doi.org/10.1111/jiec.13189
  — corroborates the Turner et al. factors as used in the LCA literature, and
  the caveat that recycling benefits depend on virgin production actually being
  displaced.

Internal (repository, commit `561a298`, 8 September 2026):
`Chokro_Mobile_Project_Brief v3.md`, `README.md`,
`INTEGRATION_NOTES_SDG_DASHBOARD.md`, `GROQ_SCREENING_INTEGRATION_FINAL.md`,
`firestore.rules`, `AUDIT_2026-08-30.md`, `UX_AUDIT_OUTSTANDING.md`.

---

*End of specification. Comments should cite requirement identifiers
(`EPR-n`, `SEC-n`, `QA-n`, `NFR-E-n`) or the open-decision number.*
