# Data-flow map — what crosses to a producer

**Status:** engineering statement of fact, derived from the code as it stands.
Not legal advice and not a legal opinion. Written to be handed to counsel as
the input to the SEC-13 questions, not as an answer to them.

**Requirement:** SEC-13 — *"Required before launch: a documented data-flow map
showing exactly what crosses to a producer."* Supporting: SEC-3
(no personal data to a producer), EPR-32 (photographs), EPR-33 (report suite).

**Scope.** Every path by which data derived from an individual's activity
reaches a commercial third party (a producer), the public, or a regulator.
Internal Chokro processing is described only where it determines what crosses.

**How to read this.** §3 is the answer to SEC-13's literal question and is
exhaustive for the EPR surface. §5 is the part counsel actually needs: the
linkage chain that decides whether a Champion's erasure request touches a
producer's certificate. §6 lists what I judge to be residual risk — including
one item I recommend changing before launch.

---

## 1. The actors

| Actor | What they are | Trust |
|---|---|---|
| **Champion** | An ordinary person who disposes of packaging and is photographed doing it | Data subject |
| **Chokro** | Operator. Admins hold the only role that sees both sides | Controller |
| **Producer** | A commercial obligated entity (`producer` role, disjoint from `citizen`) | **Third-party recipient** |
| **Public** | Anyone holding a certificate serial | Unauthenticated |
| **Regulator (DoE)** | Receives reports via the producer, not directly from Chokro | Out of band |

The producer is the boundary that matters. A producer is a commercial
organisation with a competitive interest in the data and no relationship with
the Champion whose activity produced it.

---

## 2. What a Champion supplies

Captured at disposal (`disposals`), on the Champion's own device:

| Datum | Personal? | Crosses to a producer? |
|---|---|---|
| `userId` (Firebase uid) | **Yes, directly identifying** | **Never** |
| Photograph of the disposal | **Yes** — bystanders, plates, signage | **Never** (see §4) |
| `binId` | Location of a public bin | **Yes**, row-level (§6.1) |
| Device geolocation at capture | **Yes** | **Never** — geofence check only |
| EXIF (GPS, device, capture time) | **Yes** | **Never** — stripped at capture |
| Timestamp (second precision) | Quasi-identifier with `binId` | **No** — reduced to date |
| Points awarded, wallet balance | Yes | **Never** |

**EXIF (EPR-32).** Stripped on the client before upload, at every capture path,
by explicit parameter rather than by relying on a default —
`lib/controllers/disposal_controller.dart:336` and
`lib/controllers/claim_controller.dart:206` (`keepExif: false`). Cloudinary
strips again on transform (`server/src/cloudinary.js:139`). Belt and braces.
The requirement's stronger clause — *"EXIF is stripped on the served
derivative"* — is satisfied vacuously on the producer path: see §4.

---

## 3. The producer boundary, route by route

Every authenticated producer route. `orgViewer` is the lowest org role;
`orgOwner` the highest. No producer route returns a Champion identifier.

### 3.1 Aggregate figures

| Route | Guard | What crosses |
|---|---|---|
| `GET /epr/periods` | `orgViewer` | Projected period rollups (below) |
| `GET /epr/periods/:periodId` | `orgViewer` | One projected rollup |

Both pass through `eprPeriods.projectForProducer` (`server/src/eprPeriods.js:417`),
which is an **explicit allowlist** — fields are named in, not filtered out, so a
new field added to a period document does not silently reach a producer.

Crosses: mass by category, by polymer, by district; units by category;
attribution and disposal counts; SKU ids; uncertain mass; unattributed disposal
count; reversed count and mass; reconciliation result and timestamp.

Withheld: **district breakdown is suppressed entirely** when the period holds
fewer disposals than the k-anonymity floor (default k = 5, `kAnonymityFloor` in
`config/eprPolicy`). Suppressed wholesale rather than row-by-row, because a
"top districts" list with the thin rows removed still discloses that the
remaining rows are thicker. Suppression is **stated** — `districtSuppressed` and
the floor travel with the response, so the screen says *why* the breakdown is
missing rather than rendering an absence that reads as "no geography recorded".

Also withheld: the identity of whoever ran the reconciliation. A producer is
entitled to know its figures reconciled and by how much they did not (EPR-22);
it is not entitled to the operator.

### 3.2 Reports (EPR-33)

| Report | Min role | Personal-data exposure |
|---|---|---|
| Period collection statement | `orgViewer` | Aggregate only |
| SKU performance | `orgViewer` | Aggregate only |
| Geographic recovery | `orgViewer` | District, **k-floored** identically to §3.1 |
| **Chain-of-custody export** | `orgOwner` | **Row-level — see below** |
| DoE annual progress | `orgOwner` | Aggregate only |
| Reconciliation and variance | `orgOwner` | Aggregate only |
| Audit pack | `orgOwner` | Bundles the above |
| Surplus mass statement | `orgOwner` | Aggregate only |

**Chain-of-custody is the only row-level export.** One row per attribution
(`server/src/reportJobs.js:660`):

- `disposalRef` — **pseudonymous**, not the disposal id. An HMAC keyed
  *per organisation* (`pseudonym`, line 1466), so an auditor can follow one
  disposal across rows of *this* producer's export and two producers who each
  received a fragment of the same bag **cannot** correlate their exports to
  reconstruct one Champion's activity. This is the control that makes row-level
  export defensible at all.
- `date` — **date only, never a timestamp.** Second-precision time plus a bin
  location identifies the person who was standing there.
- `binId`, `district` — **not floored.** See §6.1.
- Packaging facts: SKU id and revision, units, unit mass, total mass, gazette
  category, method, confidence tier, reversal flag.

**Reversible by Chokro, on lawful request only.** `server/src/disclosure.js`
resolves a `disposalRef` back to its evidence for a regulator, and it is the
only path in the service that deliberately re-identifies a person. Five
controls, none of them skippable:

| Control | What it means |
|---|---|
| **Admin only** | `requireAdmin`; a producer cannot reach it at all |
| **Recent proof of the password** | `requireFreshAuth(5 min)` — an unattended signed-in laptop cannot re-identify anybody. The password goes to Firebase, never to this service; the server reads `auth_time` from the token |
| **A regulator reference** | No default. A disclosure without a recorded request is a lookup tool over pseudonymised data |
| **A written reason** | The Admin's own words, a sentence minimum, read back on the register by somebody who was not there |
| **Time, address, device and location** | Recorded with every access. A location the Admin's device refuses is recorded **as a refusal**, never as a blank — a refusal is a fact about the access |

Recorded **twice**: the audit chain (tamper-evident, and the reason it is
evidence) and `disclosureLog` (structured and readable, and the reason anyone
will actually check). The chain entry is written *before* the resolution runs.

The register is readable by any Admin **without** stepping up — oversight has
to be cheaper than the thing it oversees. Reached at *EPR oversight →
Disclosure*.

Naming the Champion is a second endpoint with its own audit action, because
most regulator questions are about whether a collection happened rather than
who performed it.

> **The pseudonym is only as strong as `AUDIT_CHAIN_KEY`.** Unset, the HMAC is
> unkeyed and reversible by anyone who can guess disposal ids. The code says so
> rather than hiding it (line 1462). **This variable is unset in deployment
> config today** and is release-blocking for this reason as well as for the
> audit chain.

### 3.3 The producer's own data

`/epr/me`, `/epr/members`, `/epr/invitations`, `/epr/skus*`,
`/epr/declarations*`, `/epr/passports*`, `/epr/audit`.

These return the producer's **own** submissions and its **own** staff. No
Champion data. One note for completeness: `/epr/audit` returns `actorUid`,
`actorName` and `actorRole` (`server/src/producerAudit.js:467`) — these are the
producer's own org members, personal data of the producer's staff held under
the producer's own relationship with them, not Champion data crossing a
boundary.

### 3.4 The public boundary — certificate verification

`GET /verify/:serial` is **unauthenticated**: anyone holding a certificate can
check it. Rate-limited to 20/minute.

`passports.verifySerial` (`server/src/passports.js:725`) builds its response by
**explicit allowlist**, returning exactly five fields: `found`, `status`,
`tradeName`, `periodId`, `contentHash`, plus `supersededBy` when and only when
the certificate has been replaced.

- **Trade name only** — not the legal name, not the DoE registration number,
  not a contact, **and not a single figure**. A verifier learns that a
  certificate is genuine and current. It does not learn what it certifies.
- An unknown serial returns **200 with `found: false`**, the same shape as a
  revoked one (SEC-7). A 404 for unknown and a 200 for revoked would let an
  enumerator separate real serials from guesses.
- A read failure raises rather than returning not-found, so a database outage
  never tells a holder their genuine certificate is fake.

No Champion data reaches this surface, and no producer figure does either.

---

## 4. Photographs — the largest hazard, and what was actually built

EPR-32 calls disposal photographs *"the largest privacy hazard in this
specification"* and requires a publication gate, EXIF stripping on the served
derivative, per-image Admin approval, and no Champion identifier in document or
metadata.

**No photograph reaches a producer by any path.** Verified by inspection:

- `server/src/passportPdf.js` (~1000 lines, the certificate renderer) contains
  **no image handling at all** — no image call, no photo field, nothing.
- `server/src/passports.js` likewise.
- `server/src/reportJobs.js` emits no photo URL in any of the eight report
  types.

Open decision 11 recommended defaulting to SKU sample images and bin-context
photographs, with individual disposal photographs as an opt-in an Admin can
refuse. What is implemented is the stricter end of that: **no images**. The
publication gate and per-image approval are therefore not yet built, because
there is no path that would use them.

**Consequence for SEC-13:** the EXIF deliverable is satisfied, and satisfied
twice over — stripped at capture, and no derivative is served to a producer to
strip. **If images are ever added to the passport, EPR-32's gate and approval
must be built first, and this section must be rewritten.**

---

## 5. The linkage chain — the question counsel is actually being asked

SEC-13 and open decision 9 pose the retention-versus-erasure tension as though
attributions contain Champion data. **They do not.** The engineering fact that
reframes the question:

```
users/{uid}                      ← the Champion. Identifying.
    ↑ userId
disposals/{disposalId}           ← the act. Photograph, geo, uid, timestamp.
    ↑ disposalId
attributions/{attributionId}     ← packaging facts. NO uid. NO photograph.
    ↓ rolled up into
eprPeriods/{orgId}_{periodId}    ← aggregates. Certified figures.
    ↓ snapshotted into
plasticPassports/{serial}        ← the certificate. Immutable, public serial.
```

An attribution document holds `disposalId`, `orgId`, `skuId`, `skuRevision`,
`binId`, `district`, `units`, `massMg`, polymer split, `method`, `confidence`,
`confidenceTier`, `periodId`, `createdAt` (`server/src/attribute.js:403-423`).
**It holds no Champion identifier of any kind.** The link to a person exists
only as `disposalId`, a foreign key into `disposals`.

So the erasure question is narrower and more tractable than SEC-13 assumes:

1. **A certificate never has to change.** A passport is a snapshot of figures
   (grams of polymer), assembled and content-hashed at issue. Nothing in it is
   about a person. Erasing a Champion does not make an issued certificate false
   and does not require supersession.
2. **The retained compliance record is packaging data, not personal data** —
   once the `disposalId` link is severed. What is retained for the DoE's audit
   horizon is "21 g of rigid PET, SKU X, Dhaka, 3 March", which is about a
   bottle.
3. **The live question is therefore: sever or purge?** Erasure could be
   satisfied by deleting the `disposals` record and its photograph while
   retaining the attribution with a tombstoned `disposalRef`. The attribution
   survives for reproducibility (NFR-E-8); the person becomes unreachable from
   it.
4. **What severing costs.** Reproducibility under NFR-E-8 is "any report ever
   issued must remain reproducible from retained inputs". A severed attribution
   still reproduces every figure. What is lost is the ability to *re-derive*
   the attribution from its evidence — you could no longer show an auditor the
   photograph behind row 4,112. Whether the DoE's audit horizon demands
   re-derivability or only reproducibility is a question for counsel, and it is
   the question that decides this.

### 5.1 Chokro's proposed position (16 September 2026) — *pending counsel*

Recorded as **proposed**, not decided. It is a position to put to a lawyer, and
counsel may reject it.

1. **The compliance record carries no identifiers.** Already true, and now
   permanent by design rather than by accident.
2. **Every disposal carries a unique pseudonymous reference**, per organisation,
   from which a regulator can demand the evidence.
3. **Chokro holds the mapping and discloses it only on lawful request** —
   implemented in `server/src/disclosure.js`, Admin-only, refused without a
   regulator reference, and recorded in the audit chain before it runs.
4. **A producer never sees a person.** Already true, and enforced by a test
   across all 28 producer-facing routes.
5. **Erasure of a disposal is refused**, on the ground that the record is the
   transparency the whole scheme rests on. Account data — name, email, profile
   — would still be erasable.

**What this changes, and what it does not.**

It sharpens the question considerably. It is no longer "sever or purge"; it is:

> May Chokro refuse erasure of disposal records under a legal-obligation
> exemption, while honouring account deletion, and retaining the pseudonymous
> mapping solely for lawful disclosure to the DoE?

That is answerable yes or no, and it separates account deletion (probably
honourable) from disposal retention (proposed refusal).

**It does not make the data non-personal.** If Chokro retains the mapping, the
exported rows are **pseudonymised, not anonymised** — and pseudonymised data
whose key the controller holds is still personal data in most readings. What
the design achieves is that *no personal data reaches a producer*, which is
real, valuable, and separate. Q5 becomes more central under this position, not
less.

**And the right to erasure is not Chokro's to disapply.** It is genuinely not
absolute, and a legal-obligation exemption is a standard one, so the position
may well hold. But relying on an exemption and declaring a right inapplicable
are different things, and only the first is available. If the exemption does
not cover this, having already told Champions they cannot delete compounds the
problem rather than avoiding it.

**Questions for counsel, in the order they unblock work:**

- **Q1.** *(Reframed by §5.1.)* May Chokro refuse erasure of a disposal under
  a legal-obligation exemption, while honouring account deletion? If not, does
  severing the `disposalId` link satisfy the request instead? *(Either answer
  closes this; the first is Chokro's preference.)*
- **Q2.** Does the DoE's audit horizon require re-derivability from primary
  evidence (the photograph), or only reproducibility of the figure? *(Decides
  whether §5.3 severing is available at all.)*
- **Q3.** How long is the horizon? NFR-E-8 proposes *three-year registration
  cycle plus margin* — a starting number for counsel to confirm or replace, not
  one engineering can stand behind.
- **Q4.** Does a Champion's erasure request reach data already exported to a
  producer under the chain-of-custody export? Chokro cannot delete from a
  producer's downloaded file; the contractual term, if one is needed, is a
  legal instrument, not a technical control.
- **Q5.** *(Now central — see §5.1.)* Chokro retains the ability to reverse the
  per-organisation pseudonym, so the exported rows are pseudonymised rather
  than anonymised. Is that sufficient de-identification under the PDPA, or is a
  keyed HMAC of an identifier still personal data? *(A "still personal"
  reading does not break the disclosure design, but it does mean the export
  itself is a transfer of personal data to a third party and needs its own
  basis.)*
- **Q6.** §6.1: the row-level export discloses bin and date with no
  k-anonymity floor. The available mitigation was considered and declined, and
  the Champion consent now discloses the disclosure instead. Does the PDPA
  accept disclosure where minimisation was available? *(A yes closes §6.1. A
  no makes it release-blocking.)*

---

## 6. Residual risks

### 6.1 Bin and date cross row-level with no k-anonymity floor — *risk accepted*

SEC-3 names **"a single bin, a single day"** as precisely the shape that
isolates an individual. `projectForProducer` applies the floor to the aggregate
district breakdown. `chainOfCustody` applies **no floor at all** to its
`binId` + `date` columns.

A producer with a small programme, or one looking at a thin bin, receives rows
that say *"someone disposed of this brand's packaging at this bin on this
day"*. With a handful of rows on one bin-day that is a re-identification
vector, and one a person standing near that bin could resolve by observation.

**Decision, 16 September 2026: not mitigated. The risk is accepted.**

The recommendation was to apply the same k-anonymity floor per (bin, date)
group — suppressing `binId` while keeping `district` below the floor, and
stating the suppression the way `districtSuppressed` states it in the
aggregate. That was declined, on the ground that it changes the contents of a
regulator-facing report (EPR-33). This section records the decision rather than
repeating the recommendation.

What was traded, stated plainly because a data-flow map that recorded only the
controls would be the wrong document:

- **Remaining controls bound WHO receives the export and how often**, not what
  it discloses: `orgOwner` only; export quota and audit logging (SEC-6,
  SEC-11); the disposal reference is pseudonymous per organisation; the
  timestamp is reduced to a date.
- **The Champion consent no longer claims otherwise.** The draft had promised
  that thin bins were hidden. That sentence was removed in both languages
  rather than left standing as a false assurance — see
  [CHAMPION_CONSENT_LANGUAGE.md §4.1](CHAMPION_CONSENT_LANGUAGE.md).
- **Counsel should be told this specifically.** It is now question Q6 in §5:
  whether disclosure satisfies the PDPA where minimisation was available and
  declined is a materially different question from the one a mitigated system
  would ask.

**Revisit if any of these change:** a producer requests an export covering a
period with very few disposals; the PDPA's guidance on minimisation is
published; or a Champion asks what a producer can see about them.

### 6.2 `AUDIT_CHAIN_KEY` unset

Unset today. Two consequences: the audit chain is not evidence against an
insider who can rewrite history and recompute digests, and the chain-of-custody
pseudonym is unkeyed and therefore reversible by disposal-id guessing.
Release-blocking.

### 6.3 Aggregation across periods

Each period is floored independently. A producer holding twelve monthly
exports can sum them. Twelve sparse months of the same district disclose more
than the floor intends to allow in any one of them. Not currently controlled;
raised here rather than solved, because the fix (a floor on cumulative
disclosure) is a policy design question, not a patch.

### 6.4 A producer that is also a Champion

Prevented structurally: `producer` is disjoint from `citizen`, and
`firestore.rules:631` requires `isActiveCitizen()` to create a disposal, so a
producer account cannot manufacture its own attributed kilograms. Noted as
*controlled*, not as residual.

---

## 7. What this map does not cover

- Chokro's non-EPR surfaces (marketplace, donations, wallets) except where an
  EPR path reads them.
- The producer's own onward handling of an export it has downloaded. Outside
  Chokro's technical control; a contractual question (Q4).
- Retention **durations**. Deliberately absent — see
  [RETENTION_SCHEDULE.md](RETENTION_SCHEDULE.md), whose durations are unset by
  construction pending Q1–Q3.

---

## 8. Maintenance

This map is only true of the code it was written against. It must be revisited
when: a new producer-facing route or report type is added; `projectForProducer`
or `verifySerial`'s allowlist changes; any image path into a passport or report
is built (§4); or the chain-of-custody columns change (§6.1).

Verified against commit `1a5f419`, 16 September 2026.
