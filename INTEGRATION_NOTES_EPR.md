# EPR Producer Portal — Integration Notes

Implementation record for `EPR_PRODUCER_PORTAL_SPEC.md` v1.0. Written as the
work lands, phase by phase, in the established style of
`INTEGRATION_NOTES_SDG_DASHBOARD.md`.

Requirement identifiers (`EPR-n`, `SEC-n`, `QA-n`, `NFR-E-n`) refer to that
specification.

---

## Status

| Phase | Scope | State |
|---|---|---|
| **A** | Tenancy and identity | **Delivered** |
| **B** | Product registry and verified mass | **Delivered** |
| **C** | Attribution | **Delivered**, behind `EPR_ATTRIBUTION_ENABLED` |
| D | Declarations, reporting and the passport | Not started |
| E | Oversight, hardening and audit readiness | Not started |

Nothing in Phase A computes, stores or displays a kilogram, a percentage or a
compliance figure. That is not an omission to be filled in later by inference —
§6.7 forbids a figure whose inputs do not exist, so the workspace states which
inputs are outstanding, in the words they will be stated in when they arrive.

---

## Phase A — Tenancy and identity

### Product shape

Four new client surfaces:

- `/producer` — the workspace. Company identity, this person's capability in it,
  what can and cannot yet be reported, and the §6.7 boundary statements on the
  screen rather than in a footnote.
- `/producer/members` — who has access. Invitations, capability changes,
  revocation.
- `/producer/activity` — the organisation's own append-only trail.
- `/join?token=…` — invitation redemption. Reachable while signed out.

One new Admin surface:

- `/admin/producers` — the producer directory, the onboarding review queue with
  blocking brand-collision flags, suspension and reinstatement, per-company
  activity timeline and audit-chain verification.

`/admin/producers` is reached from the Admin home action grid, **not** from the
navigation bar. The tested five-item mobile Admin navigation is unchanged
(NFR-E-1); a sixth destination does not fit a phone in landscape, which is the
same constraint `railMinHeight` already documents.

### `producer` is a disjoint role, and the compiler was asked to prove it

`AppConstants.roleProducer` joins `admin`/`seller`/`buyer` as a stored wire
value, with the label **EPR Producer**. It does **not** join their inclusive
hierarchy (EPR-1).

Adding a fourth `AccountProfile` case turned three implicit assumptions into
compile errors, which is exactly what §4.1 asked for — the disjointness is now
stated in each place rather than emerging from a role string failing to match:

| Site | What it assumed | What it says now |
|---|---|---|
| `accountProfilesForRole` | `_ =>` fell through to `[champion]` | an explicit `roleProducer` case returning `[producer]` |
| `UserModel.isChampion` | `=> true` | `=> !isProducer` |
| `UserModel.isGreenpreneur` | `seller \|\| admin` | the same, `&& !isProducer` |
| `app_shell.dart` destinations | three profiles | a fourth set with nothing citizen-facing in it |
| `home_view.dart` action grids | three profiles | a producer branch that offers only the workspace |
| `profile_view.dart` | donate button for everyone | gated on `isChampion` |

`firestore.rules` states the same exclusion twice. `isProducerWith(u)` names the
role; `isActiveCitizen()` combines it with the existing activity check in one
`userData()` read, and replaces `isActive()` on the four client create paths a
producer would otherwise have passed — `disposals`, `claims`,
`sellerApplications` and `carts`. A producer account is a perfectly ordinary
*active* account, so a rule gated only on activity accepted one. The conflict
that closes: the party whose collected kilograms Chokro certifies also
submitting the disposals that produce them.

### How a producer account comes into existence

There is no self-registration (EPR-4), and no client write path that grants the
role:

1. An Admin opens a company record. It starts `pendingReview`.
2. An Admin reviews it against evidence and approves, setting `sizeClass` and
   `obligationStartDate` — which together decide which gazette target applies
   and from when. Both are mandatory on approval and refused to clients
   entirely; a company that could set its own would be choosing how it is
   measured.
3. An Admin (or, afterwards, an `orgOwner`) invites a work email address.
4. The invited person redeems the link, which creates the Firebase Auth account,
   the `users` document with `role: 'producer'`, and the membership — in one
   commit.

`validUser` in `firestore.rules` accepts `'producer'` so that a producer's
document is a *valid* document (otherwise a producer could not edit their own
name and an Admin could not suspend them), while the Admin update branch refuses
to move a role **into or out of** `'producer'`:

```
(request.resource.data.role == 'producer') == (resource.data.role == 'producer')
```

An equality rather than two comparisons, so suspension and reinstatement of an
existing producer still work — the platform control EPR-47 leans on.

### Why membership documents are created at redemption, not at invitation

§5.1 lists `invited` among `organizationMembers.status` values. The model, the
rules and the tests all honour it — an `invited` membership grants nothing — but
in practice no such document is written, and it cannot be: the document id is
`{orgId}_{uid}` and there is no uid until the account exists. An invitation is
therefore tracked in its own collection until it is redeemed, which is also the
honest shape. An invitation is not a membership; if a pending one granted read
access, the invited address alone would be access and the single-use token in
SEC-8 would be decorative.

### Security contract

| Requirement | How it is met | Failure mode it closes |
|---|---|---|
| **SEC-1** tenant isolation | `organizationMembers/{orgId}_{uid}` resolved by a single `get()` on a path the rules compose themselves. Re-applied in `requireOrgRole`. Never a client-supplied `orgId`. | One company reading another's compliance position |
| **SEC-2** claims are a cache | No rule and no route reads `request.auth.token.orgId`/`orgRole`. The stored document is re-read every request, so revocation is immediate rather than token-expiry-bound. | A dismissed employee exporting on the way out |
| **SEC-4** no client compliance write | `organizations`, `organizationMembers`, `producerAuditLog`, `orgInvitations` and `producerAuditHeads` deny every client write, administrators included. Proven per denial. | The evidentiary value of the system evaporating |
| **SEC-5** server-side authorisation | `requireProducer`, `requireVerifiedEmail`, `requireFreshAuth(maxAge)`, `requireOrgRole(minRole)`. The organisation comes from the route parameter or the caller's own membership — never from `req.body`. An Admin does **not** pass `requireOrgRole`. | An `orgViewer` submitting a legal declaration |
| **SEC-8** invitations | 256-bit `randomBytes`, single-use, 72-hour expiry, bound to one lowercased address, revocable, one live invitation per address, 20 per organisation. The **token is never stored** — its SHA-256 digest is the document id — so a dump of the collection yields nothing redeemable. | A replayed link minting workspace access |
| **SEC-9** session handling | `requireFreshAuth(30 min)` on every privileged action: inviting, revoking, role changes, removal, onboarding review, status changes. Read from the token's `auth_time`, and fail-closed when absent. | An unattended office desktop |
| **SEC-10** App Check | `server/src/appCheck.js`, registered globally above every route. A no-op until `APP_CHECK_ENFORCED=true`; once on, a missing or unverifiable attestation is a refusal, never a warning. Three named exemptions. | Automated scraping of a corporate dataset |
| **SEC-12** audit integrity | `producerAuditLog` is append-only in the rules for every principal. Entries are SHA-256 chained per organisation and carry a monotonic sequence, so an edit, a mid-log deletion, a truncation and a full wipe are four *distinguishable* findings. | An insider editing history |

**SEC-3** (producers never see a Champion's identity) has nothing to enforce
yet: Phase A exposes no disposal, no attribution and no per-person data to a
producer at all. It becomes live in Phase C and is where the pseudonymous
disposal reference and the k-anonymity floor land.

### The audit chain, and what it actually buys

`firestore.rules` can refuse a client's update and delete, and does. What it
cannot refuse is this service — the Admin SDK bypasses rules by definition,
which is the entire reason the service exists — and the adversary SEC-12 names
is an insider on that side of the boundary.

So the chain does not *prevent* tampering; it makes it detectable by anyone
holding the log, including the producer whose history it is:

- Each entry digests the previous entry's digest plus its own fields, over a
  fixed field order joined by U+001F. An explicit field list rather than
  `JSON.stringify`, because stringified key order is insertion order and a
  refactor that reordered two assignments would silently invalidate every chain
  ever written. A separator no value can contain, so no boundary can be shifted
  to forge a match.
- `producerAuditHeads/{orgId}` holds the latest sequence and digest. It is a
  mutable pointer and not evidence — rewriting it cannot forge a chain, only
  make the next entry link to the wrong place — but it is what makes a
  *truncated* log detectable, which a digest chain alone cannot do.
- Before/after states are stored as digests, not content. The log is readable by
  the organisation's own members, and a before-image of a membership document
  would carry a colleague's details onto a screen with no business showing them.
- `verifyChain` never reports `intact: true` over a log longer than its read
  limit. "The first 500 entries are intact" is a different claim from "the log
  is intact", and the console does not present one as the other.

Audit writes **throw**, deliberately, and roll back the transaction that would
have recorded the action. This is the opposite of `screen.js`'s discipline, and
the asymmetry is the point: a missing screen degrades a payout decision to human
review, while a missing audit entry silently destroys the evidence for something
that did happen. The same rule applies to EPR-46's read-only view — if the entry
cannot be written, the view does not open.

### Reporting contract

Phase A displays no figure, and the reasons are stated on the screen:

| Surface | What is shown | Required interpretation |
|---|---|---|
| Obligated categories | The gazette categories an Admin set at review | Set by Chokro from the products the company places on the market; absent until reviewed, and said to be absent |
| Obligation year | Derived from `obligationStartDate` by anniversary | Null when no start date is recorded. Not defaulted to 1 — year 1 carries the 15% target and year 3 carries 30%, so a guess prints the wrong law beside a producer's figure |
| Applicable collection target | 15% (years 1–2) or 30% (year 3+), from the gazette | Chokro states the target beside a figure. Whether it is met is the DoE's finding, not this system's |
| Collected mass | Nothing | No SKU has a Chokro-verified unit mass yet, so there is no defensible kilogram. Stated, not shown as zero |
| Collection percentage | Nothing | Needs a submitted put-on-market declaration as its denominator (EPR-24) |
| Recycling | Nothing, ever, in v1 | A geofenced disposal into a registered bin is a collection event. Nothing in this system observes material arriving at a recycler (EPR-25) |

`GazetteTargets` lives in `lib/core/epr_categories.dart` rather than in
`config/eprPolicy` — unlike every threshold Chokro chose — because these are the
gazette's numbers and Chokro revising them unilaterally would be revising what
the law says. It carries `reviewDueAfterYears = 3`, since the guidelines make
the targets themselves reviewable.

### Data and failure behaviour

- Every parser fails closed on an authorisation-bearing enum. An unrecognised
  `organizations.status` reads as `pendingReview`; an unrecognised `orgRole`
  reads as `orgViewer`; an unrecognised member `status` reads as `removed`; an
  unrecognised `sizeClass` reads as **null**, so no gazette target is printed
  beside a figure on a guess.
- `producerAuditLog` actions are the *opposite*: an action this build does not
  recognise is displayed with its raw string rather than hidden. An audit trail
  that silently omits what it cannot label is worse than one that admits the
  gap.
- Invitation expiry is resolved **lazily at read time**, in the pattern of
  `UserModel.isActiveAt`. Nothing runs on a timer (§3.3, NFR-E-2), so the stored
  status stays `pending` and every reader decides for itself.
- An organisation must keep at least one active owner. Demotion and removal both
  re-read the owner count inside the same transaction; the client greys the
  control and says why, so the action is not offered and then refused a second
  later.
- Redemption creates the Firebase Auth account before the Firestore transaction,
  because Auth is not transactional with Firestore. A failed transaction deletes
  the auth account as a compensating action, so the residue of a failure is at
  worst an unusable auth account — never a redeemed invitation with no
  membership behind it.
- An address that already has a Chokro account is **refused**, not converted. A
  Champion with a wallet and a disposal history must not become a producer.
- Every unusable invitation — unknown, revoked, expired, already redeemed,
  closed organisation — returns one message and one status. Distinguishing them
  tells somebody holding a stolen link which organisations exist and which
  addresses have been invited.
- The membership-lookup outage in `requireOrgRole` is a retryable 503, not a
  403. A 403 would tell a legitimate member their access had been revoked.
- Reads return typed failures; writes throw `OrgActionException` carrying the
  server's own sentence. `needsReauthentication` is a named flag rather than a
  string comparison at three call sites.

### Invitation delivery is manual, and that is disclosed

Chokro has no mail service — push runs through FCM, which sends nothing to an
inbox, and a transactional email provider is a billing decision that has not
been taken. So the invitation link is shown **once** to the person who issued
it, to send however their company already sends things.

This has one genuine advantage — the token never passes through Chokro's
outbound mail — and one real cost: an invitation cannot be re-sent, because the
token is not stored. The dialog says so at the moment it matters, and cannot be
dismissed by accident. Email *verification* does not have this problem: Firebase
sends those itself, and `requireVerifiedEmail` gates every producer write on it.

### Main implementation files

**New Flutter**

```
lib/core/epr_categories.dart               gazette taxonomy, polymers, targets
lib/models/organization_model.dart         the obligated entity, obligation year
lib/models/org_member_model.dart           membership and capability
lib/models/producer_audit_model.dart       the activity trail
lib/services/organization_service.dart     the portal's read/write path
lib/controllers/producer_workspace_controller.dart
lib/controllers/admin_producers_controller.dart
lib/views/producer/producer_dashboard_view.dart
lib/views/producer/producer_members_view.dart
lib/views/producer/producer_activity_view.dart
lib/views/producer/invitation_redeem_view.dart
lib/views/admin/admin_producers_view.dart
```

**New server**

```
server/src/organizations.js    onboarding, membership, invitations, redemption
server/src/producerAudit.js    append-only hash-chained log and verification
server/src/passwordPolicy.js   the server-side password policy (EPR-5)
server/src/appCheck.js         App Check enforcement (SEC-10)
```

**Modified**

```
lib/core/constants.dart            roleProducer, OrgRoles, OrgStatus,
                                   OrgSizeClass, ComplianceRoute, read caps
lib/core/account_profile.dart      the disjoint producer profile
lib/models/user_model.dart         isProducer; isChampion/isGreenpreneur narrowed
lib/routing/router.dart            /producer/*, /join, /admin/producers,
                                   canAccessProducerRoutes, homeFor,
                                   producerHomeRedirect
lib/views/shared/app_shell.dart    producer destination set
lib/views/shared/account_profile_switcher.dart   producer icon
lib/views/home/home_view.dart      producer branch; EPR producers admin card
lib/views/profile/profile_view.dart   donate gated on isChampion
server/src/auth.js                 requireProducer, requireVerifiedEmail,
                                   requireFreshAuth, requireOrgRole; authTime
                                   and emailVerified on req.user
server/src/index.js                the /epr routes; App Check; two new limiters
firestore.rules                    five new collections; isActiveCitizen on the
                                   four citizen create paths; validUser accepts
                                   'producer' without granting it
firestore.indexes.json             10 Phase A indexes
```

The remaining EPR-8 indexes — `attributions`, `producerSkus`,
`plasticPassports` — land with the phases that query them. An index for a
collection nothing reads is a deploy cost with no reader.

### Verification

| Gate | Result |
|---|---|
| `flutter analyze lib test` | clean, no new suppressions |
| `flutter test` | **767** passing (687 before this work) |
| `npm test --prefix server` | **402** passing (308 before) |
| `rules_test` on the emulator | **270** passing (233 before) |
| `firebase deploy --only firestore:rules --dry-run` | compiles, no warnings |
| `firebase deploy --only firestore:indexes --dry-run` | passes |

New suites and what they prove:

- `rules_test/epr_tenancy.rules.test.js` — cross-tenant read and write denial in
  both directions; a suspended, invited and removed member each denied; Admin
  write denial on all five collections; append-only enforcement including for
  Admins; the four citizen create paths denied to a producer **and still open to
  a Champion**; the producer role ungrantable and unremovable by any client
  while suspension still works.
- `test/producer_role_disjoint_test.dart` — the disjointness, from both
  directions, plus that a malformed role document does not become a producer.
- `test/producer_route_gate_test.dart` — the route policies, including that a
  producer is not sent to the seller application form and that `/join` keeps its
  token through restoration.
- `test/models/organization_model_test.dart` — obligation-year anniversaries
  including a leap-year boundary; targets absent when their inputs are; category
  order and unknown-value dropping; the application payload carrying no
  server-owned key.
- `test/models/org_member_model_test.dart` — capability by role and by status.
- `server/test/producerAudit.test.js` — digest stability and field-boundary
  resistance; edit, mid-deletion, truncation and full-wipe all detected.
- `server/test/organizations.test.js` — review, suspension and the full
  invitation lifecycle including the ceiling, the duplicate-address refusal and
  cross-tenant revocation.
- `server/test/eprAuth.test.js` — `requireOrgRole` ignoring the request body,
  refusing Admins, and returning 503 rather than 403 on an outage.
- `server/test/appCheck.test.js` — refusal rather than warning when enforced.
- `server/test/passwordPolicy.test.js` — including that punctuation does not
  defeat the company-name check.

### Deployment, before a real producer is onboarded

Release-blocking (NFR-E-9), not follow-ups:

1. `APP_CHECK_ENFORCED=true` on the service, with App Check provisioned for the
   web, Android and iOS clients. Until then any client with a valid ID token is
   accepted.
2. The portal origin in `ALLOWED_ORIGINS`. `ALLOW_LOOPBACK_ORIGINS` must not be
   set.
3. `firebase deploy --only firestore:rules,firestore:indexes`.
4. The open decisions in §15 that gate Phase A: **username login** (§4.3 —
   implemented as email invitations only, per the recommendation) and **MFA /
   Identity Platform** (§4.4 — not enabled; mandatory email verification, a
   server-side password policy and 30-minute re-authentication stand in its
   place, and TOTP remains a configuration change rather than a
   re-architecture).

---

## Phase B — Product registry and verified mass

### Product shape

Two new producer surfaces and one new Admin surface:

- `/producer/skus` — the registry. Leads with **verified-mass coverage**, not a
  product count: a catalogue of forty products with three verified masses can
  report on three, and a screen that led with the forty would tell a compliance
  officer they are twelve times better covered than they are. Each card shows
  the declared and the verified mass side by side and labelled, which is §6.2 on
  one line.
- `/producer/skus/import` — CSV import with an all-or-nothing preview.
- `/admin/mass-queue` — the mass-verification queue, oldest first.

`/admin/mass-queue` is reached from the Admin home grid, like `/admin/producers`.
The five-item mobile Admin navigation is still unchanged (NFR-E-1); the producer
navigation gained a fourth destination ("Products").

### The arithmetic

`lib/core/mass_math.dart` holds it, and it is integer milligrams end to end
(EPR-20). `units × unitMassMg` is exact integer multiplication; a sum of such
products is an exact integer sum; there is no rounding to accumulate. Rounding
happens **once**, at display or export, to three significant figures.

Milligrams rather than grams because components are declared to a tenth of a
gram and a label sleeve weighs 0.5 g — tenths as integers leave no headroom, and
tenths as doubles put a float back in the chain.

`formatGramsExact` exists alongside the rounding formatters and is deliberately
never used for a reported figure. It renders a *discrepancy*: three significant
figures turned a one-milligram component mismatch into "The parts add up to 10 g,
but the unit mass is 10 g", an error telling the producer that two numbers which
differ are equal.

### The mass chain

| Step | Where | What holds |
|---|---|---|
| Declare | `POST /epr/skus` | Components must sum to the declared unit mass, **exactly**, on integers. Both sides are figures the producer typed, so a mismatch is an arithmetic error — not the measurement disagreement EPR-11's tolerance is for |
| Submit | `POST /epr/skus/:id/submit` | The stricter EPR-9 requirements land here, not on save, so a draft can be written over several sittings. The product locks while Chokro holds it |
| Weigh | `POST /epr/admin/skus/:id/audit` | Sample size, measured mean, standard deviation, weighing location, scale photograph, operator, and the tolerance **in force at the time**, stored on the record |
| Verify | same transaction | A revision opens, the standing one closes. Never edited in place |
| Re-verify | lazily, at read time | Older than the policy interval → queued. Nothing runs on a timer (NFR-E-2) |

**The measured mean is always adopted, and the specification is ambiguous about
this.** EPR-11 reads as though a declaration inside the ±10% tolerance is kept.
Appendix A step 3 does the opposite: a five-unit mean of 9.8 g against a declared
10.0 g is "within the ± 10% tolerance", and the example records
`verifiedUnitMassG: 9.8` and states in bold that "Reporting uses 9.8, not the
declared 10.0."

Appendix A is right, and the reason is the incentive structure §6.2 opens with.
Keeping the declaration whenever it sits inside the tolerance makes the tolerance
a licence: declare 10.0 g, let the true mass be light-weighted to 9.1 g, Chokro
weighs 9.1 g, finds it within ±10%, and certifies 10.0 g — a systematic 9%
overstatement in the producer's favour, sanctioned by the control meant to
prevent it, and repeatable across a whole catalogue. A five-unit mean carries
sampling error, but that error is unbiased. **This needs the author's
confirmation and an EPR-11 wording fix.**

The tolerance verdict survives as a finding about the declaration, stored on the
audit record for the audit pack and the anomaly queue (EPR-45).

### `producerSkus` is *not* a client write path — a deliberate divergence from §5.1

§5.1 calls it "the one collection with a real client write path", on the test
this codebase applies throughout: keep the write in the rules when the governing
constraint is expressible where it is enforced.

**That test fails here, on the constraint that matters.** EPR-9's governing
constraint is that the component masses *sum to* the declared unit mass.
Firestore rules have no fold, no reduce and no way to iterate a variable-length
list, so the sum cannot be written in that language at all. A create rule could
check that `components` is a list of one to twelve things and nothing whatsoever
about what is in them — which means it would accept a 5 kg declared unit mass
alongside a single 0.1 g body, and that 5 kg would become the baseline for every
verification and every attributed kilogram.

Two further things a client write cannot do, both required elsewhere:

- **EPR-44** requires every change to a producer's record to land in
  `producerAuditLog`. Rules cannot append to it — correctly, since an entry a
  client could author is an entry an attacker could author — so a client-written
  SKU would be a change with no audit entry.
- **EPR-12** requires an edit that changes what was weighed to invalidate the
  verification *and* close the standing revision: a multi-document transaction
  conditional on a comparison with the stored document. Rules can refuse a
  write; they cannot perform the other half of one.

So the write goes where those checks can run, exactly as a wallet balance does.
Reads stay in the rules, scoped to the owning organisation.

### Editing after verification invalidates it

A producer that edits what was weighed loses the verification, and the standing
revision closes with `declarationChanged` rather than being deleted — so a report
issued against it stays reproducible, because every attribution stored the
revision and the mass it used.

"What was weighed" is the physical description: declared mass, components,
polymer, gazette category, volume, GTIN. A typo fix in the name or a new sample
photograph does not invalidate a weighing, and a reordered component array is not
a changed product.

### CSV import

Strict template, all-or-nothing, and no server-owned column accepted — each
forbidden column refused *by name with the reason*, so a producer is not left
hunting for a misspelling. Component syntax is `part:polymer:grams` separated by
`|`, and a failed component names its actual cause rather than blaming the
syntax.

A component may weigh less than a whole unit may: `minComponentMassMg` is 1 mg
against a unit floor of 0.1 g. Applying the unit floor to each part made a bottle
with a 0.05 g tamper ring unregisterable — the producer's only options were to
drop the part, losing grams from the polymer breakdown a DoE audit reads, or fold
its mass onto another part, putting those grams on the wrong polymer line.

Imported products arrive as **unverified drafts**: sample photographs cannot
travel in a spreadsheet, so they cannot be submitted for verification until
somebody adds them in the app. The import summary says so.

### Main implementation files

**New Flutter**

```
lib/core/mass_math.dart              integer-milligram arithmetic, rounding
lib/core/sku_csv.dart                bulk import parser
lib/core/epr_claims.dart             the §6.7 statements, once
lib/models/producer_sku_model.dart   the registry entry
lib/models/sku_revision_model.dart   revisions and mass audits
lib/services/producer_sku_service.dart
lib/controllers/sku_controller.dart
lib/views/producer/producer_skus_view.dart
lib/views/producer/sku_editor_dialog.dart
lib/views/producer/sku_import_view.dart
lib/views/admin/admin_mass_queue_view.dart
```

**New server**

```
server/src/producerSkus.js   registry, verification, revisions, audits
server/src/eprPolicy.js      config/eprPolicy with documented defaults
```

`GazetteTargets` stays a compile-time constant and is deliberately *not* in
`config/eprPolicy`: every threshold there is one Chokro chose and may revise,
and these are the gazette's. An editable copy would let an operator change what
the regulation says.

---

## What an adversarial audit found, and what changed

A nine-dimension review with three-way adversarial verification was run against
Phases A and B. It hit a session limit partway, completing nine of its reviewer
agents before the verification stage; the findings below were confirmed by hand
rather than by the workflow's own verifiers.

### Fixed

| Severity | Finding | Fix |
|---|---|---|
| **Critical** | Four transactions read after writing. Firestore's Admin SDK throws unconditionally, so **every** mass verification and **every** organisation creation would have failed on the first real request — while the suite stayed green, because a hand-written fake transaction does not enforce the rule | `producerAudit.appendInTransaction` split into `readChainHead` + `appendWithHead`, so a caller that must write first reads the head at the top and passes it down. The ordering is now a property of the signature rather than a convention. **All three test fakes now throw on a read after a write**, which is what makes this unrepeatable |
| **Critical** | The server's `milligramsFromGrams` used `Number.parseFloat`, which prefix-parses. `'1,250'` → 1 g against a 1250 g declaration; `'8.2g'` and `'8.2.5'` accepted silently. Dart rejects all three | Strict whole-string numeric parse. Both copies are now asserted against the same inputs under the same test names, so the *pair* is pinned rather than each copy pinned to itself |
| **Critical** | A reporter could rewrite a verified SKU's declaration through the server route — turning a verified 19.5 g bottle into a 1.3 g cap while `verifiedUnitMassMg: 19500` stayed attached, so every recognised cap would be attributed 19.5 g. No Admin involved | Changing what was weighed invalidates the verification and closes the standing revision |
| **Critical** | The `producerSkus` update rule had no `affectedKeys()` guard, so one `deleteField()` write could remove `revision` — and the next verification would then compute revision 1 and **overwrite** `skuRevisions/{id}_1`, destroying the row a passport was built on | Client writes to `producerSkus` closed entirely, for the reasons above |
| **High** | `requireOrgRole` never read the `organizations` document, so a **suspended** organisation's members kept full write access with an already-issued token — EPR-47's read-only is not read-only | `resolveMembership` resolves both documents and returns `orgWritable`; a new `requireActiveOrganization` middleware gates all eight producer write routes |
| **High** | The audit chain was an unkeyed SHA-256 over stored fields. An insider with Admin SDK access — the adversary SEC-12 names — could rewrite an entry, recompute its digest with the same public function, recompute the suffix, and `verifyChain` would report intact | HMAC under `AUDIT_CHAIN_KEY`, which must be independent of the Firestore credential: a key derived from the service account would be in the same hands as the ability to forge. `verifyChain` reports `keyed`, so a console cannot print "intact" while overstating the control |
| **High** | `actorName`, `actorRole`, `ip`, `userAgent` and the server `timestamp` were stored and **not hashed**, so an entry's identity could be rewritten to "System (automated)" with no finding, and its `timestamp` altered to reorder the timeline | All four are in the digest. `timestamp` cannot be (it is a sentinel with no value at write time), so it is compared against the hashed `timestampIso` and drift is a finding — and the timeline is ordered by `sequence`, which *is* hashed |
| **High** | Deleting every entry for an organisation **and** its head made `verifyChain` return `intact: true` over an empty log: the truncation check was guarded on the head being present | A missing head is a finding. Every organisation that exists has one, because `createOrganization` writes its first entry in the same transaction as the record |
| **High** | The invitation ceiling and the one-live-invitation-per-address check sampled 21 documents `where status == 'pending'`, and expiry is lazy — so once 21 stale rows accumulated, the page was entirely stale, `live` came back empty, and **neither check fired**. Unlimited concurrent tokens for one address | The expiry bound is in the query. Costs one composite index |
| **High** | A component mismatch message rounded both figures to three significant figures, producing "The parts add up to 10 g, but the unit mass is 10 g" | `formatGramsExact`, and the shortfall named so the producer does not have to subtract |
| **High** | The 0.1 g unit floor was applied to every component, making a bottle with a 0.05 g tamper ring unregisterable — with an error naming the wrong cause | A separate 1 mg component floor, mirrored on both sides, and per-component error reasons |

### Reviewed and deliberately deferred

These are recorded rather than silently dropped. None is reachable by a client
in the current build, and each depends on work that has not landed:

- **`verifyChain`'s 500-entry limit** means a long log is verified in one pass or
  not at all. It never reports `intact` over a partial log, so the honest answer
  is available; resumable verification belongs with the Phase E reconciliation
  console (EPR-48).
- **The `/epr/skus/import` loop writes one SKU at a time**, so a failure partway
  leaves the earlier rows written. It says so plainly rather than reporting a
  clean failure. A batched write belongs with the Phase E migration tooling
  (QA-7).
- **Invitation redemption creates the Firebase Auth account before the Firestore
  transaction** and deletes it on failure. Auth is not transactional with
  Firestore and cannot be made so; the residue of a failure is an unusable auth
  account, never a redeemed invitation with no membership.
- **SEC-3** (producers never see a Champion's identity) has nothing to enforce
  yet. Phases A and B expose no disposal and no per-person data to a producer.
  The pseudonymous disposal reference and the k-anonymity floor land in Phase C
  with attribution.

### Verification

| Gate | Result |
|---|---|
| `flutter analyze lib test` | clean, no new suppressions |
| `flutter test` | **878** passing (687 before this work) |
| `npm test --prefix server` | **497** passing (308 before) |
| `rules_test` on the emulator | **290** passing (233 before) |
| `firebase deploy --only firestore:rules --dry-run` | compiles, no warnings |
| `firebase deploy --only firestore:indexes --dry-run` | passes, 36 indexes |

New suites since Phase A:

- `test/core/mass_math_test.dart` — integer accumulation over 412,000 rows and
  over 100,000 tenth-gram rows with no drift; rounding at three significant
  figures across magnitudes; the exact-discrepancy formatter; the component
  floor; and the Dart half of the cross-language parsing parity.
- `test/core/sku_csv_test.dart` — the strict template, every forbidden column
  refused by name, all-or-nothing, line numbers matching the spreadsheet, CRLF
  and CR files, and the sub-0.1 g component case.
- `test/models/producer_sku_model_test.dart` — `reportableUnitMassMg` null for
  every non-verified status, effective-date windows including the Appendix A
  November re-weighing, and `copyWith` unable to reach a server-owned field.
- `test/epr_claim_boundaries_test.dart` — the §6.7 statements as data, and
  `findProhibitedClaims` distinguishing an asserted claim from a disclaimer that
  denies it. The first version of this test flagged the correct disclaimer as a
  violation, which is why the statements are now constants rather than strings
  typed into a widget.
- `server/test/producerSkus.test.js` — the Appendix A worked example, the
  tolerance-as-licence case, effective dating, verification invalidation, and
  the parsing parity.
- `server/test/eprPolicy.test.js` — defaults matching the §15 recommendations,
  clamping, and the tolerance taken from the caller rather than current policy.
- `rules_test/epr_skus.rules.test.js` — every client write denied, including the
  `deleteField()` attack and a declaration whose parts do not sum.

### Deployment, added to Phase A's list

5. `AUDIT_CHAIN_KEY` set to a value the database operator cannot read. Without
   it the audit chain is tamper-evident against outsiders and **not** evidence
   against an insider. The service warns at boot.

### Open decisions this phase touched

- **§15 decision 3** (tolerance and sample size) is answered in
  `config/eprPolicy` as ±10% and n ≥ 5, per the recommendation. It still wants
  the documented method note the decision asks for.
- **EPR-11's wording** contradicts Appendix A on whether a within-tolerance
  declaration is adopted. Implemented per Appendix A; needs the author's
  confirmation.

---

## Phase C — Attribution

Phase C is the only phase that touches the existing disposal decision path, and
§14's sequencing note asks for three things: a feature flag, proof that
attribution failure never affects a disposal outcome, and a disproportionate
share of review time. All three are below.

### The shape, and the one decision everything else follows from

**Attribution runs after the decision commits, in its own transaction, and
every failure is swallowed.**

`award.js` already establishes the pattern for the push notification: "AFTER the
commit, never inside it. Firestore retries a transaction body on contention, so
a send inside one fires once per attempt." The same reasoning applies with more
force here. Inside the decision transaction, a registry read failing or a mass
being unverifiable would roll back a Champion's points — a payout undone because
a producer's paperwork was incomplete. EPR-16's sentence is that a screening
outage must degrade attribution, not disposal, and this is where that holds.

So the flow is:

```
verifyDisposal → screen (one call, extended with the SKU shortlist)
               → store skuMatches as server-only evidence
               → decide → approveDisposal (commits points, ledger, caps)
                        → [after the commit] attributeDisposal
                                            → attributions + eprPeriods, one txn
```

**There is no second model call.** NFR-E-7 allows "one model call per approved
disposal (or extends the existing one)", and extending it is the cheaper half —
and the only half that works for a manual approval. A disposal routed to review
carries its recognition evidence forward, so an Admin approving three days later
attributes against what was screened at the time rather than re-screening a bin
that has since been emptied.

### EPR-27: mass stays out of the points path

§6.8 asks the architect to read the warning twice, and `server/test/attributePointsIsolation.test.js`
is the "verify by test" it demands. Sixteen assertions, of which the load-bearing
ones are:

- `decide()` returns an **identical** result whether the screening verdict
  carries a high-confidence match, an empty match list, or nothing at all. If it
  read `skuMatches` even incidentally, a producer registering a product would
  change what a Champion is paid.
- The flag vocabulary gained nothing. A new flag would be a new reason a
  disposal could be routed to review, and attribution must never be one.
- `attribute.js` names none of `wallets`, `transactions`, `dailyCaps`,
  `lockouts` or `stats`, and requires neither `award.js` nor `decide.js` nor
  `pointsPolicy.js`.
- The disposal update names only EPR-6's four server-owned fields and nothing
  that could move a payout or resurrect a rejected disposal.
- `attributeDisposal` cannot throw into its caller — proven by calling it with
  Firestore unreachable, the harshest failure available.
- Nothing the hook returns is read. A caller of `approveDisposal` gets the same
  shape it always did.

Those source-level assertions strip comments before scanning. The first version
did not, and matched the very prose explaining why a field is absent — the same
trap as the claim-boundary test in Phase B.

### The tier ladder, and what each tier costs

| Tier | Threshold | Outcome |
|---|---|---|
| `high` | ≥ 0.85 | Attributed |
| `medium` | 0.60–0.85 | Attributed, **and counted into `uncertainMassMg`** so the producer sees its own uncertainty (EPR-37), and queued for sampling |
| `low` | < 0.60 | **Not attributed.** Queued for human confirmation |
| barcode | n/a | `high`, with `confidence: null` |

A barcode carries **null** confidence rather than 1.0. A read barcode is not a
probabilistic judgement, and a fabricated certainty would pollute the accuracy
statistics EPR-17 requires be published.

Anything unreadable — a missing confidence, a non-numeric one, one out of range
— is `low`, and `low` attributes nothing. Defaulting to `high` would
auto-attribute an unrated guess.

### Null and empty are different facts (EPR-19)

This distinction runs through the whole phase and is the reason
`parseSkuMatches` returns `null` rather than `[]` on failure:

- `skuMatches: null` — recognition did not run, or could not be read. The
  disposal stays `pending`, so a backfill can attribute it later. **It is not
  counted into the unattributed pool**, because counting it would claim it had
  been checked.
- `skuMatches: []` — recognition ran and recognised nothing. *This* is
  `unattributable`, and it increments the pool that is reported as its own line.

Collapsing the two would either lose real attributions or invent an empty pool.

The pool is counted on a `__platform` rollup and **not** per organisation: an
unrecognised item belongs to nobody by definition, so attributing its absence to
a producer would invent the very thing EPR-19 forbids. That document is
Admin-read-only, because a producer reading it would learn how much of every
other company's packaging goes unrecognised.

### The mass that applied at the time (EPR-12)

`revisionActiveAt({skuId, moment})` is the function that makes a past period
reproducible. An attribution multiplies by the verified mass that applied on the
day the disposal was decided, and stores both the revision number and the
`unitMassMgUsed` it actually used.

Appendix A step 11 is the case: a November re-weighing finds the bottle
light-weighted to 9.1 g, and September's figure stays 19.6 g because September's
rows say 9.8 g. Reading `producerSkus.verifiedUnitMassMg` instead would silently
rewrite every past report every time a product was re-weighed.

A revision now also **freezes its component breakdown**, which Phase B did not.
Per-polymer reporting is computed from those masses, so reproducing a past
period needs the breakdown as it was — and while editing components already
invalidates a verification, a *closed* revision's split must stay its own.

### The polymer split sums exactly

`polymerSplitFor` applies the component proportions to the verified mass on
integers, floors each share, and gives the remainder to the heaviest part. The
lines therefore add up to the attributed mass **exactly**, for every mass —
tested across six magnitudes.

Two things this avoids. Adding component masses directly would report polymer
lines totalling more than the product's own mass whenever the verified figure
came in lighter than the declaration. And flooring without a remainder would
leave a report whose breakdown does not add up to its own total, which is
precisely what a regulator notices — and "rounding" is not an answer when both
figures are integers.

No components means **no split**, deliberately empty rather than assigning the
whole mass to the dominant polymer, because that would be a guess (§6.7).

### The shortlist is an accuracy control, not only a cost control (EPR-15)

Sending a national catalogue in a prompt is neither affordable nor accurate.
Not affordable on a metered quota; not accurate because a model asked to pick
from hundreds of near-identical bottles will pick one, confidently — and a
confident wrong brand attributes one company's kilograms to another.

So candidates are narrowed by three facts that are not the model's guess: the
declared item type, the bin's district, and what has actually been recognised at
that bin before. Ranking is by local history (worth most, because it is observed
rather than assumed), then district, then whether a GTIN is on file. Ties break
on `skuId`, so the same disposal produces the same shortlist twice — an unstable
order would make the accuracy audit measure the shortlist rather than the model.

**Only products with a verified mass are candidates**, which is a correctness
filter before an efficiency one: a match against an unverified product could not
become a defensible kilogram anyway.

**Every returned `skuId` is checked against the shortlist that was sent.** A
model returning an id it was not offered has hallucinated or echoed training
data, and accepting it would attribute mass to whichever organisation owns that
id. This is the single most important line in `parseSkuMatches`.

**The model is never told what anything weighs.** It returns counts; the mass is
applied afterwards from the verified revision. A model that knew the masses could
be nudged toward the heavier option, and a compromised prompt could not inflate a
kilogram.

### The barcode path (EPR-18, NFR-E-6)

Two constraints meet on one field, and both are honoured:

- **EPR-6** forbids the `disposals` client create allowlist growing "by a single
  key". So the scanned digits never enter the create payload. They travel with
  the *verification* request, and the server validates and writes them as a
  server-owned field.
- **NFR-E-6** forbids the barcode making the flow require another live round
  trip: "a disposal that fails at the bin because a barcode lookup timed out is
  a worse product than no barcode path at all". So nothing is looked up while
  the person is standing at the bin. The sheet reads digits and closes; the GTIN
  is resolved server-side afterwards.

The sheet does not tell the person whether the product is registered, because
finding out means a network call — and the answer is "no" for almost every
barcode, which helps nobody and costs a spinner. It is presented as optional in
its own words, because a Champion's points do not depend on it at all (EPR-27)
and implying otherwise would send people hunting for a barcode that is not there.

A misread is ignored rather than raised. A misread barcode is a common, harmless
event at a bin; blocking the flow for one would make scanning riskier than not
scanning. The check digit is deliberately not verified — an invalid GTIN simply
does not resolve, so it costs nothing, whereas a check-digit implementation
disagreement would cost an accurate attribution.

Two registered products sharing one GTIN is refused rather than resolved.
Picking either would attribute one company's mass on a coin flip.

### Reconciliation (EPR-22, EPR-48, QA-3)

The rollup is incremented transactionally, which makes it a derived figure that
can drift. §3.3 means there is no scheduler to reconcile it nightly, so an Admin
triggers a rebuild and **the result records whether the rebuilt total matched**.

A mismatch is **surfaced, never silently corrected**. The recomputed figure is
stored *beside* the incremented one, and the incremented one is not overwritten —
it is what every report issued so far was built from, so replacing it would make
a past passport unreproducible in order to tidy a discrepancy.

The walk is resumable in 500-row batches with a cursor (NFR-E-3), and an
incomplete pass writes nothing: a partial rebuild compared against a complete
increment would report a mismatch that is an artefact of paging.

A reversal (EPR-21) marks the row and decrements the rollup in one transaction,
and `accumulate` skips reversed rows — so the two halves line up and a reversal
does not show up as a reconciliation mismatch.

### Periods are Asia/Dhaka (EPR-23)

A fixed +6 offset, and the reasoning is recorded rather than assumed: Bangladesh
has observed DST exactly once, June to December 2009, at UTC+7. Every timestamp
in scope is 2026 or later. If that changes, one constant moves and historical
periods must be *recomputed* rather than reinterpreted — which is what
`recomputedAt` is for.

Both copies are pinned to the same boundary cases. The one that matters: a
disposal decided at 20:00 UTC on 30 September is 02:00 on 1 October in Dhaka, and
filing it in September would make one reported month short and the next long,
with nothing in either document that looks wrong.

### What a producer can see, and what it cannot (SEC-3)

The workspace reads `eprPeriods`, **not** `attributions`, and both halves of
that sentence are now enforced rather than merely true of the current screens.

**A producer cannot read attribution rows at all.** An earlier version of this
phase granted a producer's members read on their own rows, with a comment
conceding that no screen rendered them and that pseudonymisation would arrive in
Phase D. **That reasoning was wrong**, and the way it was wrong is worth
recording: *"no screen renders it" is a statement about the product, not a
control.* A producer holds its own Firebase credentials,
`attributions(orgId, periodId, createdAt)` is a shipped composite index, and the
Firestore SDK is a public API — so a member could query the rows directly and
get, per row, `binId`, `disposalDecidedAt` at second precision, and the real
`disposalId`. `bins` is readable by any signed-in account and carries lat/lng,
because the app must resolve a scanned code. Joining the two reconstructs
exactly what SEC-3 names as its failure mode: "a map of who throws what where,
to a commercial party, in a jurisdiction now legislating on personal data."

The grant is Admin-only until the pseudonymised chain-of-custody export exists.
It costs nothing today, and the rules test now pins the **denial** rather than
the leak.

**The period response is projected through an explicit allowlist.**
`listPeriods` used to return the stored document verbatim, which shipped two
things a producer must never receive:

- `lastAttributionAt`, a server timestamp at second precision. On a period with
  one disposal that is the exact moment one identifiable person threw something
  into a named district. The period is the resolution a producer reports at.
- `recomputedBy`, the Firebase uid of the Chokro employee who ran the
  reconciliation. A producer needs to know *whether* its period reconciled; it
  has no business knowing which member of staff touched its figures, and a staff
  identifier is a target.

An allowlist rather than a deletion list, because a deletion list would have
missed both again the next time the rollup gained a field. A new field is now
invisible to producers until somebody decides it should not be.

**The k-anonymity floor exists** (`config/eprPolicy.kAnonymityFloor`, default 5).
It did not before, and SEC-3 requires it: "any producer-facing aggregate broken
down finely enough to isolate individuals (a single bin, a single day) is
suppressed below a policy k-anonymity floor".

The floor applies to **geography and only geography**. District is the
identifying dimension SEC-3 names; category and polymer are properties of the
*packaging* — 21 g of rigid PET tells you about a bottle, not about a person —
and the total is the figure the producer is certified on, so suppressing it would
make the workspace useless rather than private.

Suppression is **stated, never silent**. `districtSuppressed` and the floor
travel with the response, and the card says how many disposals a period needs
before its geography appears. An empty district map with the flag false means
"no geography recorded"; with it true it means "recorded and withheld". Those
are different facts, and rendering the second as the first would be a false
claim about Chokro's own evidence.

Proven by test: a producer cannot read an attribution row, a `disposals`
document, a `users` document or a `wallets` document; the projection drops both
leaked fields and refuses a field added later; and geography is withheld at four
disposals and shown at five.

### Main implementation files

**New Flutter**

```
lib/core/epr_period.dart                    Asia/Dhaka period resolution
lib/models/attribution_model.dart           the atomic evidence record
lib/models/epr_period_model.dart            the rollup, with derived totals
lib/services/attribution_read_service.dart
lib/controllers/attribution_controller.dart
lib/views/producer/collected_mass_card.dart
lib/views/disposal/barcode_scan_sheet.dart
```

**New server**

```
server/src/eprPeriod.js      the authoritative period derivation
server/src/skuShortlist.js   candidate selection, ranking, GTIN resolution
server/src/attribute.js      recognition to attribution to rollup
server/src/eprPeriods.js     recompute, reversal, period reads
```

**Modified**

```
server/src/screen.js       the SKU recognition block; existing verdict
                           semantics and null-on-failure unchanged, and the
                           prompt is byte-identical when no shortlist is sent
server/src/verify.js       shortlist build, skuMatches storage, GTIN validation
server/src/award.js        the post-commit attribution hook
server/src/producerSkus.js revisionActiveAt; components frozen onto revisions
lib/controllers/disposal_controller.dart  scannedGtin on the draft
lib/services/verification_service.dart    carries the scan
lib/views/disposal/declare_view.dart      the optional barcode row
firestore.rules            attributions, eprPeriods, attributionConfirmations,
                           binSkuFrequency; disposals allowlist UNCHANGED
firestore.indexes.json     8 more indexes
```

### Verification

| Gate | Result |
|---|---|
| `flutter analyze lib test` | clean |
| `flutter test` | **949** passing (878 after Phase B) |
| `npm test --prefix server` | **587** passing (497) |
| `rules_test` on the emulator | **312** passing (290) |
| `firebase deploy --only firestore:rules --dry-run` | compiles, no warnings |
| `firebase deploy --only firestore:indexes --dry-run` | passes, 44 indexes |

Notable new suites:

- `server/test/attributePointsIsolation.test.js` — EPR-27, described above.
- `server/test/attribute.test.js` — the Appendix A worked example end to end;
  idempotence; only-terminal-approved; the tier ladder; null-versus-empty; the
  November re-weighing not changing September; the barcode path; the Dhaka
  boundary; and every failure returning an outcome rather than throwing. Its
  fake transaction enforces read-before-write, as Phase B's now do.
- `server/test/eprPeriods.test.js` — a mismatch surfaced and the incremented
  figure left intact; reversal decrementing and a later recompute agreeing;
  paging writing nothing.
- `rules_test/epr_attribution.rules.test.js` — every client write denied
  including an Admin's; the platform pool Admin-only; and the QA-2 regression
  that **the `disposals` client create allowlist has not grown**, asserted field
  by field against every attribution key.
- `test/core/epr_period_test.dart` — the boundaries, including that the two
  definitions of "which period" agree at every edge.

### Two more the review caught, both silent

**The district key disagreed in three places.** The attribution path sanitised
it — a dot in a Firestore map key is read as a nested field path — and the
recompute and the reversal did not. The reversal was the worse half: it
decremented a key that had never been written, creating a **negative district
total in a compliance rollup**. The recompute rebuilt the period under the raw
name, so every period with a punctuated district reported a reconciliation
mismatch that was two spellings rather than a discrepancy — exactly the noise
that makes a real mismatch easy to dismiss. `sanitizeMapKey` now lives in
`eprPeriod.js`, the module all three already import, and each calls it.

**`uniqueSkuCount` was never incremented.** It was declared on the model,
rebuilt by the reconciliation, and set nowhere — so it read 0 for every period,
and a passport would have printed "0 distinct products" beside a real mass.

A counter could not have fixed it: `FieldValue.increment(1)` on every
attribution counts rows rather than products, and nothing inside an increment
can ask whether a product has been seen before. The rollup now stores
`skuIds` via `FieldValue.arrayUnion`, which adds only what is absent — exactly a
set, and idempotent under the retries `increment` would double-count. The count
is derived from the set's length rather than stored beside it, so the two cannot
drift.

A reversal deliberately leaves the set alone: whether a product still belongs
depends on whether any other row for it survives, which one row cannot answer.
`arrayRemove` would drop a product still attributed elsewhere in the period.
Overstating variety is the smaller error — it never overstates mass — and a
recompute corrects it exactly.

### Two bugs this phase's own tests caught

Worth recording because both were silent.

**The confirmation queue was never written on the unattributable path.** A
low-confidence match was deferred, `deferredCount` was reported, and nothing was
queued — EPR-17's "queued for human confirmation" satisfied on paper and nowhere
else, in exactly the case where a deferred match is the only remaining chance of
a real attribution.

**The accuracy sample selected nothing.** A polynomial hash mapped a family of
ids sharing a prefix into a narrow band, so `disposal_0` through `disposal_3999`
were either all sampled or none — zero at a 2% fraction. Firestore's real
auto-ids are random, which would have hidden this in production and left the
published accuracy figure resting on whichever ids happened to fall in the band.
Now a SHA-256 digest, uniform over any input family.

### Deployment, added to the list

6. `EPR_ATTRIBUTION_ENABLED=true` on the service. **Off by default**, and while
   it is off the disposal path is observably unchanged: the shortlist is not
   built, so the screening prompt is byte-identical to the pre-Phase-C one, and
   `attributeDisposal` returns `{outcome: 'disabled'}` without a read. Turn it on
   after the registry has verified masses in it, or every disposal will be
   correctly recorded as `unattributable`.

### Open decisions this phase touched

- **§15 decision 4** (category-average estimates for unmatched mass) is
  answered as the recommendation states: not in v1.
  `config/eprPolicy.estimateUnmatchedMass` is `false`, and
  `AttributionMethod.reportable` is the list an estimating method would have to
  be added to — visible in review rather than able to join a headline total
  quietly.
- **§15 decision 5** (branded-item incentive) is answered as recommended: no
  points effect, enforced by test rather than by convention.
