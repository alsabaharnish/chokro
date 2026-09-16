# Retention schedule

**Status:** the *shape* of a schedule, with every duration deliberately unset.
Engineering cannot fill these in. Not legal advice.

**Requirement:** SEC-13 — *"a retention schedule per collection (attributions
and audit entries have a compliance-driven retention that is longer than a
Champion's right-to-erasure expectation — that tension needs a lawyer's answer,
not an engineer's)"*. Supporting: NFR-E-8 (reproducibility), open decision 9.

**Source of truth:** [`server/src/retention.js`](../server/src/retention.js).
This document describes it; the module *is* it, and the table below is
generated from it. `server/test/retention.test.js` asserts the schedule stays
complete — a new collection added to the server without a retention
classification fails that test.

---

## 1. Why the durations are blank

They are blank by construction, not by oversight. `retention.js` has no default
durations and the module throws on an unconfigured collection, which inverts
the rule every other policy module in this codebase follows.

`eprPolicy.js` tolerates absence: a missing threshold falls back to a
documented default, because a mass verification that fails when nobody has
opened the policy screen is worse than one using a sensible number.

Retention is not like that. A wrong duration fails in one of two directions and
both are the harm the schedule exists to prevent:

- **Too short** — evidence behind an issued certificate is destroyed before the
  DoE's audit horizon closes. NFR-E-8 requires every report ever issued to
  remain reproducible from retained inputs for that whole period.
- **Too long** — personal data is kept past its lawful basis, which is
  precisely the exposure SEC-13 says this feature "materially increases" by
  introducing commercial third-party recipients.

A default would be an engineer's answer wearing a lawyer's clothes.

## 2. The starting number, and what it is not

NFR-E-8 proposes **three-year registration cycle plus margin**, and says
"confirm with counsel per SEC-13". That is a number for counsel to confirm or
replace. It is written nowhere in the code, because a number in code is a
number in force.

## 3. The tension is narrower than it looks

The fact that reframes the question, set out in full in
[DATA_FLOW_MAP.md §5](DATA_FLOW_MAP.md):

**An attribution holds no Champion identifier.** It holds `disposalId`, a
foreign key into `disposals`; `disposals` holds the uid, the photograph and the
capture geolocation. So the compliance record Chokro must retain is about
*packaging* — "21 g of rigid PET, SKU X, Dhaka, 3 March" — and is personal only
by way of a link that can be cut.

This makes a third option available that SEC-13's framing does not consider:

| Option | Erasure satisfied? | Figures reproducible? | Evidence re-derivable? |
|---|---|---|---|
| Purge `disposals` and `attributions` | Yes | **No** — breaks NFR-E-8 | No |
| Retain both | **No** | Yes | Yes |
| **Sever** — purge `disposals`, keep `attributions` with a tombstoned link | Yes | **Yes** | **No** |

Severing is why `attributions` and `attributionConfirmations` carry the
disposition `sever` rather than `purge`. Whether it is *lawful* is counsel Q1;
whether it is *sufficient for the DoE* is Q2.

## 3.1 Chokro's proposed answer (16 September 2026) — *pending counsel*

Recorded as proposed, not decided. Full statement at
[DATA_FLOW_MAP.md §5.1](DATA_FLOW_MAP.md).

**Neither of the three options above, but a fourth: refuse.** Chokro's position
is that a disposal record may not be erased at all, because it is the
transparency the scheme rests on — while account data (name, email, profile)
remains erasable, and the pseudonymous mapping is retained solely for lawful
disclosure to the DoE.

| | Erasure satisfied? | Figures reproducible? | Evidence re-derivable? |
|---|---|---|---|
| Purge both | Yes | No | No |
| Retain both | No | Yes | Yes |
| Sever | Yes | Yes | No |
| **Refuse (proposed)** | **Account only** | **Yes** | **Yes** |

What it changes for this schedule, if counsel accepts it:

- **`disposals` stops being contested and becomes `retain`.** It is currently
  the row that decides the schedule, and this answer decides it.
- **`attributions` keeps its `sever` disposition anyway**, as the fallback if
  counsel rejects the position. A schedule that recorded only the preferred
  answer would have to be rebuilt rather than reconfigured if the answer came
  back no.
- **`users` stays `purge`.** Account deletion is still honoured, and under this
  position it is the *only* thing erasure reaches.

**The schedule has not been changed to match.** The position is Chokro's, the
determination is counsel's, and writing the preferred answer into the
dispositions before it is confirmed would be exactly the substitution this
module exists to prevent.

## 4. The schedule

`class` — what the record is. `disposition` — what expiry does. `erasure` —
what a Champion's erasure request does.

| Collection | Class | Duration | Clock runs from | On expiry | On erasure |
|---|---|---|---|---|---|
| `attributions` | compliance | **unset** | createdAt | sever | sever |
| `eprPeriods` | derived | n/a — never expires | periodId | retain | none |
| `plasticPassports` | compliance | n/a — never expires | issuedAt | retain | none |
| `putOnMarketDeclarations` | compliance | n/a — never expires | periodId | retain | none |
| `putOnMarketVersions` | compliance | n/a — never expires | createdAt | retain | none |
| `producerAuditLog` | compliance | n/a — never expires | timestampIso | retain | none |
| `producerAuditHeads` | compliance | n/a — never expires | updatedAt | retain | none |
| `skuMassAudits` | compliance | n/a — never expires | createdAt | retain | none |
| `producerSkus` | compliance | n/a — never expires | updatedAt | retain | none |
| `skuRevisions` | compliance | n/a — never expires | createdAt | retain | none |
| `organizations` | compliance | n/a — never expires | createdAt | retain | none |
| `organizationMembers` | personal | **unset** | joinedAt | purge | purge |
| `orgInvitations` | personal | **unset** | createdAt | purge | purge |
| `eprAnomalies` | derived | **unset** | detectedAt | purge | none |
| `attributionConfirmations` | derived | **unset** | createdAt | sever | sever |
| `reportJobs` | derived | **unset** | createdAt | purge | none |
| `binSkuFrequency` | derived | **unset** | updatedAt | purge | none |
| `users` | personal | **unset** | createdAt | purge | purge |
| `disposals` | personal | **unset** | createdAt | purge | contested |
| `claims` | personal | **unset** | createdAt | purge | purge |
| `devices` | personal | **unset** | updatedAt | purge | purge |
| `points` | personal | **unset** | createdAt | purge | purge |
| `wallets` | personal | **unset** | updatedAt | purge | contested |
| `transactions` | personal | **unset** | createdAt | purge | contested |
| `orders` | personal | **unset** | createdAt | purge | contested |
| `carts` | personal | **unset** | updatedAt | purge | purge |
| `products` | personal | **unset** | createdAt | purge | contested |
| `donations` | personal | **unset** | createdAt | purge | contested |
| `lockouts` | operational | **unset** | expiresAt | purge | purge |
| `dailyCaps` | operational | **unset** | date | purge | purge |
| `claimQuotas` | operational | **unset** | date | purge | purge |
| `bins` | operational | n/a — never expires | — | retain | none |

**32 collections. 21 expire and need a duration; 11 never expire.**

### 4.1 The rows that never expire, and why that is not evasion

Five carry a compliance record that has no meaningful expiry:

- **`plasticPassports`** — an issued certificate is a public, content-hashed
  statement of grams. Deleting one erases nobody; it breaks verification for
  whoever holds it (SEC-7).
- **`producerAuditLog`** — HMAC-chained and append-only. **Deleting any entry
  breaks the chain from that point forward** and makes every later entry
  unverifiable. This collection cannot have a retention period in the ordinary
  sense; if one is legally required, the mechanism has to be re-designed, not
  re-configured.
- **`skuMassAudits`** — the physical-sampling evidence behind a verified unit
  mass (EPR-11). Without it a certificate rests on an unexplained number.
- **`putOnMarketVersions`** — superseded versions are the evidence a correction
  happened (EPR-12). Keeping only the current one makes variance review
  unfalsifiable.
- **`skuRevisions`** — an attribution pins the revision it used.

None of these holds a Champion identifier.

### 4.2 The contested rows

Six carry `erasure: contested` — the request reaches them and something pushes
back. Each is a row counsel must rule on.

`disposals`, `wallets`, `transactions`, `orders`, `products`, `donations`.

**`disposals` is the one that matters for EPR**, and it decides the schedule.
Chokro proposes to resolve it by refusing erasure outright — see §3.1.
It holds the uid, the photograph and the capture geolocation, *and* is the
primary evidence behind every attribution citing it. Purging satisfies erasure
and destroys re-derivability. Retaining preserves the audit trail and keeps a
person's photograph past their request.

The other five are **pre-existing PDPA work**, not EPR work — financial and
marketplace records with retention expectations of their own. They are listed
because a schedule that covers only the collections one feature touches is not
a schedule, and because the completeness test found four of them that reading
the spec had not.

## 5. What exists, and what deliberately does not

**Built:**

- The schedule, classified per collection, with a test that keeps it complete.
- Configuration loading, where a malformed value reads as **unset** rather than
  being clamped into range — clamping produces a number nobody chose.
- `assertConfigured()` — throws, naming every collection still missing a
  determination.
- `planExpiry()` — what *would* be due, per collection, with counts and
  cutoffs. An unconfigured collection reports `unconfigured`, **never a count
  of zero**; the two must not render alike.
- `erasureImpact(uid)` — see §6.

**Deliberately not built: an executor.** There is no code path in Chokro that
deletes anything on a retention basis, and `retention.test.js` asserts the
module exports none. Until open decision 9 is answered, `sever` and `purge` are
indistinguishable guesses about the same record — `disposals` is the case in
point. Writing the deleter first would mean choosing, in code, the thing SEC-13
says is not an engineer's to choose.

When the answer arrives, the work is: set the durations in
`config/retentionSchedule`, and write the executor against a schedule that
already says, per collection, what it should do.

## 6. Making the question answerable

`erasureImpact(uid)` is read-only and reports, for one Champion: how many
disposals, how many attributions those became, the total mass contributed, the
periods and organisations reached, and **every issued certificate whose figures
were assembled from a period they contributed to** — with each certificate's
status.

The point is to put numbers on the abstract question. Counsel is not asked to
weigh erasure against compliance retention in general; they are asked about
*this* Champion, whose 340 disposals became 512 attributions contributing 4.1 kg
to eleven certificates held by three producers.

The result always carries `resolution: 'undetermined'`, and a test asserts it.
Reporting a collision is not resolving one.

## 7. Questions for counsel

Repeated from [DATA_FLOW_MAP.md §5](DATA_FLOW_MAP.md), in the order they
unblock work:

1. **Q1** *(reframed by §3.1)* — May Chokro refuse erasure of a disposal under
   a legal-obligation exemption while honouring account deletion? Failing that,
   does severing the `disposalId` link satisfy the request?
2. **Q2** — Does the DoE's audit horizon require re-derivability from primary
   evidence (the photograph), or only reproducibility of the figure?
3. **Q3** — How long is the horizon? NFR-E-8 proposes three years plus margin.
4. **Q4** — Does erasure reach data already exported to a producer under the
   chain-of-custody export? Chokro cannot delete from a producer's downloaded
   file.
5. **Q5** — Is the per-organisation pseudonym sufficient de-identification, or
   is a keyed HMAC of an identifier still personal data?

**Q1 and Q2 together unblock everything else.** Q3 without them sets a duration
for an operation whose meaning is undecided.

---

Written against commit `1a5f419`, 16 September 2026.
