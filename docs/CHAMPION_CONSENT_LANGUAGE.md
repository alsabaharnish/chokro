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
> district, the bin, and the date. Where very few people have used a bin, we
> hide the location details so that no single person can be picked out.
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
> **You can ask us to delete your account at any time.** We will remove your
> personal information and your photographs. The packaging measurements already
> counted towards a company's certificate stay in our records, with nothing
> left in them that points to you.
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
> আর কোন তারিখ। যেসব বিন খুব কম মানুষ ব্যবহার করেছেন, সেখানে আমরা অবস্থানের
> তথ্য লুকিয়ে রাখি, যাতে কোনো একজন ব্যক্তিকে আলাদা করে চেনা না যায়।
>
> **আপনার ছবি আমাদের কাছেই থাকে।** আমরা সেগুলো দিয়ে যাচাই করি যে ফেলার ঘটনাটি
> সত্যিই ঘটেছে। ছবি তোলার সঙ্গে সঙ্গেই, আপনার ফোন থেকে বের হওয়ার আগেই, অবস্থান
> ও ডিভাইসের তথ্য মুছে ফেলা হয়। কোনো কোম্পানি কখনও কোনো ছবি দেখে না।
>
> **আমরা রেকর্ড রাখি।** কোনো কোম্পানিকে একবার সার্টিফিকেট দেওয়া হলে — যার
> পেছনে আপনার ফেলা প্যাকেজিংও আছে — আমাদের প্রমাণ করতে হয় সেই সার্টিফিকেট সঠিক
> ছিল। তাই নিয়ন্ত্রক সংস্থা যতদিন জানতে চাইতে পারে, ততদিন সেই রেকর্ড রাখা হয়।
>
> **আপনি যেকোনো সময় অ্যাকাউন্ট মুছে ফেলতে বলতে পারেন।** আমরা আপনার ব্যক্তিগত
> তথ্য ও ছবি সরিয়ে ফেলব। যে ওজনের হিসাব ইতিমধ্যে কোনো কোম্পানির সার্টিফিকেটে
> যুক্ত হয়ে গেছে, তা আমাদের রেকর্ডে থেকে যাবে — তবে তাতে আপনাকে চেনার মতো
> কিছুই আর থাকবে না।
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
| "where very few people have used a bin, we hide the location" | k-anonymity floor | **Only partly true — §4.1** |
| "removed the moment you take it, before it leaves your phone" | `keepExif: false` at every capture path | Yes |
| "kept for as long as the regulator may ask" | NFR-E-8 | Deliberately vague — §4.2 |
| "nothing left in them that points to you" | Severing; attributions hold no uid | **Conditional — §4.3** |

---

## 4. Three places the draft is ahead of the code

These are the review-critical items. Each is a sentence that is currently
*aspirational*, and each must either become true or come out.

### 4.1 "we hide the location details" — partly untrue today

The k-anonymity floor suppresses the **district breakdown** in aggregate
figures. It does **not** apply to the chain-of-custody export, which hands a
producer one row per attribution carrying `binId` and `date` with no floor at
all — the exact "single bin, single day" shape SEC-3 names as isolating an
individual. [DATA_FLOW_MAP.md §6.1](DATA_FLOW_MAP.md).

**Either close the gap or do not make the promise.** The recommendation in the
map is to apply the same floor per (bin, date) group in that export. Until that
lands, this sentence overstates the protection, and a consent that overstates
protection is worse than one that says less.

### 4.2 "as long as the regulator may ask" — vague because the number is unknown

Deliberately imprecise, because the duration is open decision 9 and no number
exists yet ([RETENTION_SCHEDULE.md](RETENTION_SCHEDULE.md)). Counsel should say
whether the PDPA permits a duration stated by reference to a regulatory horizon
rather than in years. If it does not, this sentence cannot be finalised until
Q3 is answered — and this consent screen is then blocked on it.

### 4.3 "nothing left in them that points to you" — true only if severing is what happens

This describes the **sever** disposition: purge `disposals`, keep
`attributions` with the `disposalId` link cut. That is what the schedule
records as the intent, but no executor exists, and whether severing satisfies
the PDPA is counsel Q1.

If the answer is that attributions must be purged too, this sentence stays true
and NFR-E-8 breaks. If the answer is that both must be retained intact, **this
sentence becomes false** and the draft needs a harder one — something closer to
*"measurements already counted towards a company's certificate cannot be
removed"*, which is a materially less comfortable thing to ask someone to agree
to, and worth knowing before launch rather than after.

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
5. **A deletion request path.** The draft promises one. There is no such path
   today, and promising a right the product cannot exercise is its own problem.
6. **A decision on §4.1** before the sentence about hiding locations ships.

Items 1–3 are ordinary work. Item 5 is blocked on open decision 9 in the same
way the executor is: what "delete" *does* is the undecided question.

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
5. Children. The draft assumes an adult reader. Chokro has no age gate.
6. Does the re-consent in §5.3 need to block app use until answered, or may it
   be dismissible?

---

Drafted against commit `1a5f419`, 16 September 2026. Companion documents:
[DATA_FLOW_MAP.md](DATA_FLOW_MAP.md), [RETENTION_SCHEDULE.md](RETENTION_SCHEDULE.md).
