# Groq Screening Integration — Final Notes

**Date:** August 1, 2026  
**Project:** Chokro Mobile (CSE489, BRAC University)  
**Provider:** Groq API with qwen/qwen3.6-27b  
**Status:** ✅ Complete, tested, and deployed to production

---

## Overview

Replaced Gemini free-tier screening (which faced permanent zero-quota 429 errors) with Groq's multimodal API. The integration is complete end-to-end: disposal photos uploaded to Cloudinary → Groq screening → auto-approve or route to admin review.

**All 87 server tests pass. Screening is live on Render.**

---

## What Changed

### Files Modified

#### `server/src/screen.js` (complete rewrite)
- **Old provider:** Google Gemini 2.0 Flash
- **New provider:** Groq qwen/qwen3.6-27b
- **Endpoint:** `https://api.groq.com/openai/v1/chat/completions`
- **Auth:** `Authorization: Bearer ${GROQ_API_KEY}` (was `x-goog-api-key`)
- **Key env var:** `GROQ_API_KEY` (was `GEMINI_API_KEY`)
- **Critical addition:** `reasoning_effort: "none"` to disable Qwen's thinking mode

#### `server/test/verify.test.js`
- Fixed `isConfigured()` test: changed from `GEMINI_API_KEY` to `GROQ_API_KEY`

#### All other files
- **No changes required** — `verify.js`, `decide.js`, `award.js`, `index.js`, routing, contracts, all untouched

---

## How It Works

### Request/Response Flow

```
User submits disposal photo (Cloudinary URL)
  ↓
POST /disposals/:id/verify (authenticated)
  ↓
verifyDisposal() in verify.js reads disposal document
  ↓
screenImage({imageUrl, declaredItemType, declaredItemCount})
  ↓
Groq API call to qwen/qwen3.6-27b
  ↓ JSON response parsed
  ↓
Returns {confidence, itemCount, itemTypeMatches, notes} or null
  ↓
decide() evaluates:
  - Distance (geofence)
  - Duplicate photo hash
  - Daily cap
  - Screening confidence (threshold: 0.75)
  - Item type match
  ↓
Decision: 'autoApprove' or 'review'
  ↓
If autoApprove:
  → approveDisposal() → wallet credited, ledger entry, lockout set
If review:
  → disposal stays pending, flags logged, admin queue populated
```

### Groq API Details

**Endpoint:** `https://api.groq.com/openai/v1/chat/completions`

**Request body:**
```json
{
  "model": "qwen/qwen3.6-27b",
  "messages": [{
    "role": "user",
    "content": [
      {
        "type": "text",
        "text": "You are screening a photograph submitted as evidence of waste disposal. The person says it shows 1 item(s) of plastic bottles. Reply with ONLY a JSON object, no markdown fence and no commentary: {...}"
      },
      {
        "type": "image_url",
        "image_url": {
          "url": "https://res.cloudinary.com/ata3ir5d/image/upload/v.../..."
        }
      }
    ]
  }],
  "temperature": 0,
  "max_tokens": 300,
  "reasoning_effort": "none"
}
```

**Response structure:**
```json
{
  "choices": [{
    "message": {
      "content": "{\"confidence\": 0.95, \"itemCount\": 1, \"itemTypeMatches\": true, \"notes\": \"A hand is holding a small plastic bottle over an open trash bin, clearly showing the act of disposal.\"}"
    }
  }]
}
```

**Verdict object returned:**
```javascript
{
  confidence: 0.0-1.0,      // How clearly the photo shows waste disposal
  itemCount: number|null,   // How many items counted, or null if uncertain
  itemTypeMatches: boolean, // Whether waste type matches declared type
  notes: string             // One sentence for admin reviewer
}
```

**Failure mode:** Returns `null` on any error (network, timeout, API error, parse failure). This triggers `screeningUnavailable` flag, routing the submission to review (fail-toward-review principle).

---

## Key Design Decisions

### 1. HTTP URLs Only
Groq accepts only remote HTTP(S) URLs, not base64 data URIs. This is satisfied by design: all disposal photos are uploaded to Cloudinary *before* screening, so `imageUrl` is always `https://...`.

### 2. Disable Thinking Mode
Qwen 3.6 27B defaults to thinking mode, which wraps responses in `<think>` tags for reasoning. For this use case (deterministic JSON output), `reasoning_effort: "none"` is required. Without it, `parseVerdict()` silently returns null because the JSON extraction fails.

### 3. No Recomputation of Verdict
The server **never re-screens a submission**. Once a verdict is recorded, it stays — an administrator lowering the disposal award later must not retroactively rewrite what past submissions were worth (§6.2, Chokro design).

### 4. Fail Toward Review, Never Toward Payout
- Screening unavailable → `screeningUnavailable` flag → admin review
- Low confidence → `lowConfidence` flag → admin review
- Type mismatch → `itemTypeMismatch` flag → admin review
- Count disagreement → `countMismatch` flag → admin review (not rejection)
- Any parse error → returns null → review

The system has **zero auto-approval paths that depend on a single check**. Every flag that routes to review is advisory; only the daily cap blocks approval even for an administrator.

---

## Testing & Verification

### Unit Tests
**All 87 server tests pass:**
```bash
npm test
# PASS  test/verify.test.js
# PASS  test/bins.test.js
# PASS  test/server.test.js
```

### End-to-End Tests (Live on Render)
Sample Render server logs showing screening working correctly:

```
[screen] screening: {
  imageUrl: 'https://res.cloudinary.com/ata3ir5d/image/upload/v...',
  declaredItemType: 'plasticBottle',
  declaredItemCount: 1
}
[screen] Groq response status: 200
[screen] Response text length: 185
[screen] Parsed verdict: {
  confidence: 0.95,
  itemCount: 1,
  itemTypeMatches: true,
  notes: 'A hand is holding a small plastic bottle over an open trash bin, clearly showing the act of disposal.'
}
```

**Results observed:**
- ✅ High-confidence images (0.9+) with correct type → auto-approved
- ✅ Low-confidence images (0.1) → routed to review with `lowConfidence` flag
- ✅ Type mismatches → routed to review with `itemTypeMismatch` flag
- ✅ Admin review queue populated with proper flags and screening output
- ✅ No false auto-approvals

---

## Environment Configuration

### Required Env Vars

**Locally (`.env`):**
```
GROQ_API_KEY=gsk_...
GEMINI_API_KEY=  # (legacy, now unused)
```

**On Render:**
```
GROQ_API_KEY=gsk_...
```

Check Render dashboard → Environment tab to confirm `GROQ_API_KEY` is set.

### Verify Configuration

Run this locally to confirm the key is present:
```bash
cd ~/develop/chokro/server
grep GROQ_API_KEY .env
# Should output: GROQ_API_KEY=gsk_...
```

---

## Deployment & Operations

### Initial Deployment
```bash
cd ~/develop/chokro
git add -A
git commit -m "Integrate Groq screening, remove Gemini"
git push
# Render auto-deploys from main branch
```

### Warm the Service Before Demos
Render's free tier sleeps after 15 minutes idle. Before demoing, call:
```bash
curl https://chokro.onrender.com/health
# Should return: {"ok": true, "service": "chokro-server", ...}
```

### Monitor Screening
Check Render server logs for `[screen]` prefixed lines to see screening activity:
```
[screen] screening: {...}
[screen] Groq response status: 200
[screen] Parsed verdict: {...}
```

---

## Limitations & Disclosures

For the term paper's **Limitations** section:

> **Screening Provider:** Photo screening uses Groq's `qwen/qwen3.6-27b` model. Groq marks this model as a preview intended for evaluation rather than guaranteed production use. Groq's multimodal model lineup has changed during this project (Llama 4 Scout and Maverick were deprecated mid-project), so future availability is not guaranteed.
>
> **Image Sources:** Groq accepts only remote HTTP(S) URLs; disposal photos must be uploaded to cloud storage (Cloudinary) before screening. Groq's free tier has modest rate limits, which may affect high-volume testing.
>
> **Confidence Tuning:** The auto-approve confidence threshold is fixed at 0.75. This threshold was set based on a limited sample of test images and may need adjustment with real-world disposal photographs.
>
> **Failure Mode:** Screening outages, rate limits, or API errors route submissions to human review rather than auto-approving. This is intentional (fail-toward-review principle) and means the system remains fully functional if Groq becomes temporarily unavailable.
>
> **Duplicate Detection:** Perceptual hashing detects duplicate photographs within a user's own history only; cross-user photo sharing is not detected.

---

## Files Involved

| File | Change | Notes |
|------|--------|-------|
| `server/src/screen.js` | Complete rewrite | Gemini → Groq |
| `server/src/verify.js` | None | Calls `screenImage()` unchanged |
| `server/src/decide.js` | None | Receives verdict format unchanged |
| `server/src/award.js` | None | No wallet writes affected |
| `server/src/index.js` | None | Routes untouched |
| `server/test/verify.test.js` | One test fixed | `isConfigured()` now checks `GROQ_API_KEY` |
| `server/.env` | Env var updated | `GROQ_API_KEY=gsk_...` |

---

## Troubleshooting

### "Screening unavailable" in app but Groq logs show 200 OK
- Check the flags returned: `lowConfidence`, `itemTypeMismatch`, `countMismatch` are all advisory and route to review
- These are not failures; they are correct operation (fail-toward-review)
- Check the admin review queue to see the submission with its flags and screening output

### Groq returns 429 (rate limited)
- Free tier has modest limits; back off briefly
- The system routes to review, which is correct (§7.4)
- In production, upgrade to Groq's paid tier for higher limits

### Parsing fails (null returned)
- Check Render logs for `[screen]` messages
- Verify the response contains a JSON object starting with `{`
- Confirm `reasoning_effort: "none"` is in the request (disables thinking mode)

### Image not reachable by Groq (400 errors in logs)
- Cloudinary URLs sometimes trigger CDN blocks
- This is rare in production but can happen with test URLs
- Routes to review (correct behavior, fail-toward-review)

---

## Quick Reference

| Aspect | Value |
|--------|-------|
| **Provider** | Groq API |
| **Model** | qwen/qwen3.6-27b |
| **Endpoint** | https://api.groq.com/openai/v1/chat/completions |
| **Auth** | Bearer token in Authorization header |
| **Env var** | GROQ_API_KEY |
| **Temperature** | 0 (deterministic) |
| **Max tokens** | 300 |
| **Reasoning** | none (disabled) |
| **Confidence threshold** | 0.75 |
| **Failure mode** | Return null → screeningUnavailable → review |
| **Tests passing** | 87/87 ✅ |
| **Status** | Live on Render ✅ |

---

## References

- **Groq API Docs:** https://console.groq.com/docs/chat-completions-intro
- **Qwen 3.6 27B Model Card:** https://console.groq.com/docs/model/qwen/qwen3.6-27b
- **Chokro Project Brief:** `Chokro_Mobile_Project_Brief_v2.md` (§4.3, screening design)
- **Previous Session Notes:** Earlier conversation on M2 implementation

---

**Last Updated:** August 1, 2026  
**Status:** Production-ready ✅
