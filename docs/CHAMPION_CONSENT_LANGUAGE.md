# Champion consent language — draft for legal review

**Status: DRAFT. Not reviewed by counsel. Not in the product.** Nothing here
should be shipped, shown to a user, or relied on as consent until a lawyer
qualified in Bangladesh's Personal Data Protection Act has been through it.

**Requirement:** SEC-13 — *"updated consent language for Champions that says
their disposal activity contributes to aggregate producer reporting."*

**Why a draft is useful anyway.** Counsel reviewing a draft that is accurate
about what the system does is faster and cheaper than counsel writing from a
description. Every factual claim below is checked against the code and
cross-referenced to [DATA_FLOW_MAP.md](DATA_FLOW_MAP.md). The legal
sufficiency of the wording is entirely the reviewer's.

---

## 1. Two findings that come before the wording

### 1.1 There is no consent surface to update

`lib/` contains no privacy policy, no terms screen and no consent checkbox.
SEC-13 says "updated consent language", which presumes something to update.
Registration (`lib/views/auth/register_view.dart`) collects an account and
nothing else.

So this is not a copy change. It is a screen, a stored record of what was
agreed and when, and a re-consent path for existing Champions. Scoped in §5.

### 1.2 The app is English-only, and its users are not

Bengali appears in `lib/` in exactly two places — the PDF font machinery and a
locale selector — and nowhere in the interface. The certificate renderer is
bilingual; **the app is not.**

Consent obtained in a language the person does not read is not informed
consent, whatever it says. A Bengali translation is a precondition of this text
meaning anything, not a nicety to follow. Both versions are below; the Bengali
is a working translation and needs a native reviewer as well as a legal one.

---

## 2. The drafted text

Intended for a consent screen shown at registration and, once, to every
existing Champion.

> ### How your disposals are used
>
> When you dispose of packaging at a Chokro bin, we work out what the packaging
> was — the brand, the material, and roughly what it weighed.
>
> **We add that up and report it to the companies that made the packaging.**
> Bangladesh requires those companies to show how much of their packaging is
> collected and recycled. Your disposals are part of how that gets proved.
>
> **They never find out it was you.** Companies do not receive your name, your
> email address, your account, your points, or your photographs. Not now, and
> not on request.
>
> **What they do receive** is the packaging: what it was, what it weighed, the
> district, the bin, and the date. Nothing in that list names you, but a bin
> and a date together are specific, so we tell you plainly that they are
> included.
>
> **Your photographs stay with us.** We use them to check that a disposal
> really happened. Location and device information is removed from every photo
> the moment you take it, before it leaves your phone. No company ever sees a
> photograph.
>
> **We keep the records.** Once a company has been given a certificate based
> partly on your disposals, we have to be able to prove that certificate was
> right, so those records are kept for as long as the regulator may ask about
> them.
>
> **You can ask us to delete your account at any time.** Email us at
> **[DELETION_REQUEST_ADDRESS]** and we will remove your name, your email
> address and your profile.
>
> **Your disposal records stay.** Once packaging you disposed of has counted
> towards a company's certificate, that record is the proof the certificate is
> honest, and we keep it. It holds no name, no email and no account — only what
> the packaging was, where and when. If the Department of Environment formally
> asks us to, and only then, we can connect a record back to an account, and we
> write down every time we do.
>
> [ ] I understand and agree.

### 2.1 Bengali — working translation, needs a native reviewer

> ### আপনার ফেলা প্যাকেজিং কীভাবে ব্যবহার করা হয়
>
> আপনি যখন চক্র বিনে প্যাকেজিং ফেলেন, আমরা বের করি সেটি কী ছিল — কোন ব্র্যান্ড,
> কোন উপাদান, আর আনুমানিক কত ওজন।
>
> **আমরা সেগুলো যোগ করে সেই কোম্পানিগুলোকে জানাই, যারা প্যাকেজিংটি তৈরি
> করেছে।** বাংলাদেশে এই কোম্পানিগুলোকে দেখাতে হয় তাদের প্যাকেজিংয়ের কতটুকু
> সংগ্রহ ও পুনর্ব্যবহার হয়েছে। আপনার ফেলা প্যাকেজিং সেই প্রমাণেরই অংশ।
>
> **তারা কখনও জানতে পারে না এটি আপনি ছিলেন।** কোম্পানিগুলো আপনার নাম, ইমেইল,
> অ্যাকাউন্ট, পয়েন্ট বা ছবি — কিছুই পায় না। এখনও নয়, চাইলেও নয়।
>
> **তারা যা পায়** তা হলো প্যাকেজিংটি: সেটি কী ছিল, কত ওজন, কোন জেলা, কোন বিন,
> আর কোন তারিখ। এর কোনোটিতেই আপনার নাম থাকে না, তবে বিন আর তারিখ একসঙ্গে
> নির্দিষ্ট তথ্য — তাই আমরা স্পষ্ট করেই জানাচ্ছি যে এগুলো অন্তর্ভুক্ত থাকে।
>
> **আপনার ছবি আমাদের কাছেই থাকে।** আমরা সেগুলো দিয়ে যাচাই করি যে ফেলার ঘটনাটি
> সত্যিই ঘটেছে। ছবি তোলার সঙ্গে সঙ্গেই, আপনার ফোন থেকে বের হওয়ার আগেই, অবস্থান
> ও ডিভাইসের তথ্য মুছে ফেলা হয়। কোনো কোম্পানি কখনও কোনো ছবি দেখে না।
>
> **আমরা রেকর্ড রাখি।** কোনো কোম্পানিকে একবার সার্টিফিকেট দেওয়া হলে — যার
> পেছনে আপনার ফেলা প্যাকেজিংও আছে — আমাদের প্রমাণ করতে হয় সেই সার্টিফিকেট সঠিক
> ছিল। তাই নিয়ন্ত্রক সংস্থা যতদিন জানতে চাইতে পারে, ততদিন সেই রেকর্ড রাখা হয়।
>
> **আপনি যেকোনো সময় অ্যাকাউন্ট মুছে ফেলতে বলতে পারেন।**
> **[DELETION_REQUEST_ADDRESS]** ঠিকানায় আমাদের ইমেইল করুন — আমরা আপনার নাম,
> ইমেইল ঠিকানা ও প্রোফাইল সরিয়ে ফেলব।
>
> **আপনার ফেলার রেকর্ড থেকে যাবে।** আপনার ফেলা প্যাকেজিং একবার কোনো কোম্পানির
> সার্টিফিকেটে গণনা হয়ে গেলে, সেই রেকর্ডই প্রমাণ করে সার্টিফিকেটটি সঠিক — তাই
> আমরা তা রেখে দিই। তাতে কোনো নাম, ইমেইল বা অ্যাকাউন্ট থাকে না — শুধু থাকে
> প্যাকেজিংটি কী ছিল, কোথায় আর কখন। পরিবেশ অধিদপ্তর আনুষ্ঠানিকভাবে চাইলে, এবং
> কেবল তখনই, আমরা কোনো রেকর্ডকে অ্যাকাউন্টের সঙ্গে মেলাতে পারি — এবং প্রতিবার
> তা লিখে রাখি।
>
> [ ] আমি বুঝেছি এবং সম্মত আছি।

---

## 3. Where each claim comes from

| Claim | Basis | Accurate? |
|---|---|---|
| "add that up and report it" | EPR-33 report suite | Yes |
| "never receive your name, email, account, points, photographs" | SEC-3; `projectForProducer` allowlist; no image path in `passportPdf.js` | Yes |
| "not now, and not on request" | No producer route exposes a Champion identifier under any parameter | Yes |
| "what it was, what it weighed, the district, the bin, the date" | `chainOfCustody` columns | Yes — **see §4.1** |
| "a bin and a date together are specific, so we tell you plainly" | No floor on the row-level export — stated rather than claimed away | Yes — **§4.1** |
| "removed the moment you take it, before it leaves your phone" | `keepExif: false` at every capture path | Yes |
| "kept for as long as the regulator may ask" | NFR-E-8 | Deliberately vague — §4.2 |
| "holds no name, no email and no account" | Attributions hold no uid — verified | Yes |
| "only then... and we write down every time" | `disclosure.js`; refused without a DoE reference; audited before it runs | Yes |
| "your disposal records stay" | Chokro's proposed position | **Pending counsel — §4.3** |
| "we will remove your name, your email address and your profile" | `accountDeletion.js` — does exactly this | Yes |
| "email us at …" | The only request route, by decision. **Address not yet set** | **Blocked on §5.5** |

---

## 4. Three places the draft is ahead of the code

These are the review-critical items. Each is a sentence that is currently
*aspirational*, and each must either become true or come out.

### 4.1 The location promise was removed, because the protection was declined

The draft originally said *"where very few people have used a bin, we hide the
location details so that no single person can be picked out."*

That was only partly true. The k-anonymity floor suppresses the **district
breakdown** in aggregate figures; it does **not** apply to the chain-of-custody
export, which hands a producer one row per attribution carrying `binId` and
`date` with no floor at all — the exact "single bin, single day" shape SEC-3
names as isolating an individual ([DATA_FLOW_MAP.md §6.1](DATA_FLOW_MAP.md)).

**Decision, 16 September 2026: the floor will not be extended to the row-level
export.** So the promise came out rather than the gap being closed, in both
languages. The consent now states that bin and date are included and claims no
protection over them.

This is the honest option of the two available, and it is the weaker one. A
reviewer should know what was traded: the residual re-identification risk in
§6.1 of the map is **accepted, not mitigated**, and the controls that remain
are `orgOwner`-only access, export quotas and audit logging (SEC-6, SEC-11),
the per-organisation pseudonym on the disposal reference, and reduction of the
timestamp to a date. Those bound who receives the export and how often. They do
not bound what it discloses.

**This is the sharpest question for the reviewer**, and §6 repeats it: is
telling a Champion plainly that their bin and date are shared with a commercial
third party sufficient under the PDPA, or does the Act require the
minimisation itself?

### 4.2 "as long as the regulator may ask" — vague because the number is unknown

Deliberately imprecise, because the duration is open decision 9 and no number
exists yet ([RETENTION_SCHEDULE.md](RETENTION_SCHEDULE.md)). Counsel should say
whether the PDPA permits a duration stated by reference to a regulatory horizon
rather than in years. If it does not, this sentence cannot be finalised until
Q3 is answered — and this consent screen is then blocked on it.

### 4.3 "Your disposal records stay" — Chokro's position, not yet counsel's

The draft used to say the retained measurements had *"nothing left in them that
points to you"*, which described severing — an option that was never chosen.

Chokro's position, recorded 16 September 2026 and set out in full at
[DATA_FLOW_MAP.md §5.1](DATA_FLOW_MAP.md): **erasure of a disposal record is
refused**, on the ground that the record is the transparency the scheme rests
on. Account data — name, email, profile — remains erasable.

The draft now says that plainly rather than implying the comfortable version.
Two things a reviewer must weigh:

- **It is less comfortable to agree to.** A Champion is being asked to accept
  that one category of their data is permanent. That is the honest description
  of what the system does, and a consent that described the pleasant
  alternative would not be consent to this system.
- **The right to erasure is not absolute, but it is not Chokro's to
  disapply.** A legal-obligation exemption is standard and this position may
  well hold. But a company may *rely on an exemption*; it may not *declare a
  right inapplicable*. If the exemption does not reach this data, having
  already told Champions they cannot delete makes the position worse, not
  better. **This is the single most important thing for the reviewer to
  confirm or reject.**

The disclosure half is built and behaves as described: `disclosure.js` is
Admin-only, refuses without a recorded regulator reference, writes to the audit
chain before resolving anything, and treats naming a person as a separate act
from producing evidence.

---

## 5. What shipping this would require

Not a copy change:

1. **A consent screen** at registration, before the first disposal is possible.
2. **A stored consent record** — version, timestamp, locale the Champion
   actually read it in. Without the version, a later change to this text leaves
   no way to say what any given Champion agreed to.
3. **A re-consent path** for existing Champions, shown once. SEC-13 says
   "updated", which means people have already used the app under a basis that
   did not mention producer reporting.
4. **Bengali in the app**, at least on this screen — §1.2.
5. **An account-deletion path.** ~~There is no such path today.~~ **Built and
   operable.** `server/src/accountDeletion.js` erases the half all four answers
   to decision 9 agree on — name, email, photograph, sign-in, push tokens,
   cart — and touches nothing they disagree about. An Admin runs it from the
   accounts screen; the dialog shows the retained list *before* offering the
   button, marks contested entries as Chokro's position rather than settled
   law, and never renders a partial deletion as a clean one.

   **Decision, 16 September 2026: requests stay by email. No self-service
   request flow.** Recorded as a decision rather than left as a gap.

   That is a defensible scope — a human reading each request catches the ones
   that are really something else, and the volume does not yet justify a flow.
   But it makes one thing release-blocking that was not before: **the app
   contains no contact address anywhere.** No support screen, no `mailto`, no
   published email. The only "contact" string in the product tells a suspended
   user to *"Contact a 3ZERO Admin"* without saying how.

   A right whose only door is unmarked is not a right anyone can exercise. So
   the consent text now names the address, and **`[DELETION_REQUEST_ADDRESS]`
   is a placeholder that must be replaced before this ships.** A monitored
   inbox, not a personal one — it becomes the data-protection contact of
   record.

6. ~~A decision on §4.1~~ — taken. The sentence was removed; no work
   outstanding.

Items 1–3 are ordinary work. Item 5 runs end to end for an Admin; what is
left is publishing an address a Champion can write to.

---

## 6. For the reviewer

Specific questions, beyond "is this adequate":

1. Is consent the right lawful basis here at all, or is this a legitimate-
   interest or legal-obligation processing that should be **notified** rather
   than **consented to**? A consent that cannot meaningfully be withheld —
   disposal is the app's core function — may be the wrong instrument, and
   presenting it as a choice when it is not may be worse than a clear notice.
2. Does §4.2's wording ("as long as the regulator may ask") satisfy the PDPA's
   specificity requirement for retention?
3. Does the Champion need to be told **which** producers receive data derived
   from their activity, or does "the companies that made the packaging"
   suffice?
4. Is a single combined consent acceptable, or must producer reporting be
   separable from the disposal-photograph processing it depends on?
5. **§4.3 — the priority.** May Chokro refuse erasure of disposal records
   under a legal-obligation exemption while honouring account deletion? A no
   means this consent cannot ship as drafted.
6. **§5.5.** Erasure requests are email-only by decision. Does the PDPA require
   the request route to be as accessible as the one used to collect the data —
   which here was two taps inside the app? If it does, email alone will not
   hold and a self-service flow becomes mandatory rather than optional.
7. **§4.1.** Is disclosing that bin and date are shared sufficient, or does
   the PDPA require the minimisation regardless of what the consent says?
   Chokro has chosen disclosure over suppression; this is the decision
   most likely to need revisiting.
8. Children. The draft assumes an adult reader. Chokro has no age gate.
9. Does the re-consent in §5.3 need to block app use until answered, or may it
   be dismissible?

---

Drafted against commit `1a5f419`, 16 September 2026. Companion documents:
[DATA_FLOW_MAP.md](DATA_FLOW_MAP.md), [RETENTION_SCHEDULE.md](RETENTION_SCHEDULE.md).
