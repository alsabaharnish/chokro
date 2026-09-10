/**
 * Chokro — automated photo screening (F2.10).
 *
 * Asks a vision model whether a photograph shows what the user said it shows,
 * and — the part the payout actually rests on — whether the waste ended up in
 * the bin. The verdict never rejects anything: it either clears a submission
 * for the auto-approve lane, or it does not, in which case a person looks.
 *
 * WHY `binVisible`/`wasteInBin` EXIST.
 * The verdict used to report only a confidence number, an item count and a
 * type match. None of those asks the question the award is for. A photograph
 * of the declared waste held in a hand, or set on the ground next to the bin,
 * satisfies all three: the type matches, the count matches, and the image is
 * perfectly clear — so confidence is high. Standing at the bin satisfies the
 * geofence, and a fresh photo satisfies the duplicate check. The result was a
 * flagless submission down the auto-approve lane, and points for waste that
 * was never disposed of. The two booleans below are the only signal in the
 * pipeline that distinguishes being at a bin from using one.
 *
 * WITHOUT AN API KEY THIS RETURNS NULL, AND THAT IS A SUPPORTED STATE.
 * `decide()` reads null as `screeningUnavailable` and routes to review. The
 * same path is taken by a rate limit, a timeout, or a malformed response. This
 * is why the pipeline works before a key is obtained — it simply never
 * auto-approves, which is the safe direction.
 *
 * NEVER THROWS. Every failure returns null. A screening outage must not turn
 * into a failed submission for the user, and must never turn into an approval.
 *
 * PROVIDER: Groq, via the OpenAI-compatible chat-completions endpoint.
 *
 * IMAGE CONSTRAINT: Groq accepts only remote HTTP(S) URLs, not base64 data
 * URIs. In the Chokro flow, disposal photos are uploaded to Cloudinary before
 * screening, so the imageUrl parameter is always `https://...`. This constraint
 * is satisfied by design and needs no workaround.
 *
 * MODEL: qwen/qwen3.6-27b, Groq's current multimodal model, with
 * reasoning_effort="none" to disable thinking mode and get direct JSON output.
 *
 * TERM PAPER, LIMITATIONS: Groq serves qwen/qwen3.6-27b as a preview model
 * for evaluation, and Groq's multimodal lineup has changed multiple times
 * during this project — both worth disclosing.
 *
 * ---------------------------------------------------------------------------
 * SKU RECOGNITION (EPR-7, EPR-15, EPR-16)
 * ---------------------------------------------------------------------------
 *
 * This module is EXTENDED, not replaced. `screenConfidence`,
 * `screenItemCount`, `screenBinVisible` and `screenWasteInBin` keep their exact
 * current meanings, and `decide()` continues to read only those — see the
 * warning in §6.8 and the test that pins it.
 *
 * When a candidate shortlist is supplied, the model is additionally asked which
 * of those registered products it can see and how many of each, and returns
 * that as a separate `skuMatches` block. Two properties of that block matter:
 *
 *   IT NEVER AFFECTS THE VERDICT. A recognition failure, a malformed match
 *   list, a model that ignores the question entirely — none of it changes
 *   `binVisible`, `wasteInBin`, `confidence` or `itemCount`. The disposal
 *   decision must not become sensitive to whether a producer's product was
 *   identified, or a screening change would silently move payouts.
 *
 *   IT NEVER INVENTS. `skuMatches` is null when recognition did not run and an
 *   empty array when it ran and matched nothing. Those are different facts and
 *   the attribution path treats them differently (EPR-19): null means "not
 *   checked", empty means "checked, nothing there". Neither is ever read as
 *   "attribute something generic".
 *
 * THE MODEL IS NEVER TOLD WHAT ANYTHING WEIGHS. It returns counts. The mass is
 * applied afterwards, server-side, from the verified revision in force on the
 * day of the disposal (EPR-20) — so a model cannot be nudged toward the heavier
 * option, and a compromised prompt cannot inflate a kilogram.
 */

const MODEL = 'qwen/qwen3.6-27b';
const TIMEOUT_MS = 20000;
const ENDPOINT = 'https://api.groq.com/openai/v1/chat/completions';

/** The closed item-type vocabulary (§6.1), in words a model will recognise. */
const ITEM_TYPE_LABELS = Object.freeze({
  plasticBottle: 'plastic bottles',
  plasticOther: 'other plastic waste',
  paper: 'paper or cardboard',
  glass: 'glass',
  metal: 'metal or cans',
  eWaste: 'electronic waste',
  organic: 'organic waste',
});

function isValidItemType(value) {
  return Object.hasOwn(ITEM_TYPE_LABELS, value);
}

function isConfigured() {
  return Boolean(process.env.GROQ_API_KEY);
}

/**
 * The prompt.
 *
 * Asks for strict JSON and nothing else. It deliberately does *not* ask "should
 * this be approved" — the model reports what it sees, and `decide()` owns the
 * decision. Handing the approval question to the model would put a payout
 * decision inside something we cannot test deterministically.
 */
function buildPrompt(declaredItemType, declaredItemCount, shortlist = []) {
  const label = ITEM_TYPE_LABELS[declaredItemType] || declaredItemType;
  const hasCandidates = Array.isArray(shortlist) && shortlist.length > 0;

  const lines = [
    'You are screening a photograph submitted as evidence that waste was put',
    'into a public waste bin. The claim is only valid if the waste is actually',
    'inside the bin, or visibly in the act of being dropped into it. Waste held',
    'in a hand, resting on the ground, standing beside the bin or merely in the',
    'same frame as the bin does NOT count as disposed.',
    '',
    `The person says it shows ${declaredItemCount} item(s) of ${label}.`,
    '',
  ];

  if (hasCandidates) {
    // The candidates carry no mass and no price. See the module header.
    lines.push(
      'SECOND, SEPARATE QUESTION. Below is a numbered list of specific',
      'registered products. Say which of them you can actually see in this',
      'photograph, and how many of each.',
      '',
      'Rules for this part, and they matter more than being helpful:',
      '- Only list a product if you can identify it from what is visible.',
      '- Do NOT guess between similar products. If you can see a bottle but',
      '  cannot tell which brand, list nothing.',
      '- Do NOT list a product because it is plausible for this kind of waste.',
      '- An empty list is a correct and useful answer.',
      '- Count only items you can see. Do not infer a count from the number',
      '  the person stated.',
      '',
      'Candidates:',
    );

    shortlist.forEach((candidate, index) => {
      const parts = [
        `${index + 1}. id=${candidate.skuId}`,
        `brand="${candidate.brand}"`,
        `product="${candidate.name}"`,
      ];
      if (candidate.volumeMl) parts.push(`volume=${candidate.volumeMl}ml`);
      if (Array.isArray(candidate.hints) && candidate.hints.length > 0) {
        parts.push(`look for="${candidate.hints.join('; ')}"`);
      }
      lines.push(`   ${parts.join(' ')}`);
    });

    lines.push('');
  }

  lines.push(
    'Reply with ONLY a JSON object, no markdown fence and no commentary:',
    '{',
    '  "binVisible": <true only if a waste bin or container is clearly visible>,',
    '  "wasteInBin": <true only if the waste is inside the bin, or being dropped into it>,',
    '  "confidence": <0.0-1.0, how clearly this photo shows the stated waste going into the bin>,',
    '  "itemCount": <how many items you can count, or null if you cannot tell>,',
    '  "itemTypeMatches": <true if the waste matches the stated type>,',
  );

  if (hasCandidates) {
    lines.push(
      '  "skuMatches": [',
      '    {"skuId": "<an id from the list above, exactly>",',
      '     "units": <how many of it you can see, 1 or more>,',
      '     "confidence": <0.0-1.0, how sure you are it is THIS product>}',
      '  ],',
    );
  }

  lines.push(
    '  "notes": "<one short sentence for a human reviewer>"',
    '}',
    '',
    'If you cannot tell whether the waste reached the bin, answer false rather',
    'than guessing, and say why in notes.',
  );

  if (hasCandidates) {
    lines.push(
      'If you recognise none of the listed products, return an empty',
      '"skuMatches" array. That is expected most of the time.',
    );
  }

  return lines.join('\n');
}

/** Extracts the JSON object from a model response that may be fenced. */
function parseVerdict(text, allowedSkuIds = null) {
  if (typeof text !== 'string') return null;

  const cleaned = text.replace(/```json/gi, '').replace(/```/g, '').trim();
  const start = cleaned.indexOf('{');
  const end = cleaned.lastIndexOf('}');
  if (start === -1 || end === -1 || end <= start) return null;

  try {
    const parsed = JSON.parse(cleaned.slice(start, end + 1));

    const confidence =
      typeof parsed.confidence === 'number' ? parsed.confidence : null;
    if (confidence === null || confidence < 0 || confidence > 1) return null;

    return {
      confidence,
      itemCount:
        typeof parsed.itemCount === 'number' ? Math.round(parsed.itemCount) : null,
      itemTypeMatches: parsed.itemTypeMatches === true,
      // Tri-state on purpose, unlike `itemTypeMatches` above.
      //
      // These two decide whether the waste reached the bin at all, so "the
      // model did not answer" must not read as either answer. Coercing a
      // missing field to false would flag honest submissions; coercing it to
      // true would restore the hole this field exists to close. Null means not
      // reported, and `decide()` treats it as not checked.
      binVisible: typeof parsed.binVisible === 'boolean' ? parsed.binVisible : null,
      wasteInBin: typeof parsed.wasteInBin === 'boolean' ? parsed.wasteInBin : null,
      notes: typeof parsed.notes === 'string' ? parsed.notes.slice(0, 300) : null,
      // A SEPARATE BLOCK, PARSED SEPARATELY, AND ITS FAILURE IS SEPARATE.
      //
      // `parseSkuMatches` returns null when the model did not answer the
      // recognition question and an array when it did. Neither outcome can
      // change any field above it, so a malformed match list degrades
      // attribution and leaves the disposal verdict exactly as it was
      // (EPR-7, EPR-16).
      skuMatches: parseSkuMatches(parsed.skuMatches, allowedSkuIds),
    };
  } catch {
    return null;
  }
}

/**
 * Parses the recognition block.
 *
 * @param {unknown} raw            whatever the model put in `skuMatches`
 * @param {Set<string>|null} allowedSkuIds  the shortlist that was sent
 * @returns {Array<object>|null} null when recognition did not run or could not
 *   be read; an array — possibly empty — when it did
 *
 * NULL AND EMPTY ARE DIFFERENT FACTS.
 * Null means "not checked". Empty means "checked, nothing recognised". The
 * attribution path treats them differently: the first leaves the disposal
 * `pending` so a retry can attribute it later, the second records it as
 * `unattributable` and counts it into the visible unattributed pool (EPR-19).
 * Collapsing them would either lose real attributions or invent an empty pool.
 *
 * EVERY RETURNED ID IS CHECKED AGAINST THE SHORTLIST THAT WAS SENT.
 * A model that returns an id it was not offered has either hallucinated one or
 * echoed something from its training data. Accepting it would attribute mass to
 * a product this disposal was never screened against — and, worse, to whichever
 * organisation happens to own that id. This is the single most important line
 * in the function.
 */
function parseSkuMatches(raw, allowedSkuIds) {
  if (!Array.isArray(raw)) return null;

  const matches = [];
  const seen = new Set();

  for (const entry of raw) {
    if (!entry || typeof entry !== 'object') continue;

    const skuId = entry.skuId;
    if (typeof skuId !== 'string' || skuId.length === 0) continue;

    // The check that matters. An unoffered id is dropped, not trusted.
    if (allowedSkuIds && !allowedSkuIds.has(skuId)) {
      console.warn(`[screen] model returned an unoffered skuId: ${skuId}`);
      continue;
    }

    // One row per product. A model listing the same bottle twice is describing
    // one product, and summing its rows would double the mass.
    if (seen.has(skuId)) continue;

    const units =
      typeof entry.units === 'number' && Number.isFinite(entry.units)
        ? Math.round(entry.units)
        : null;
    // A match with no usable count cannot become a mass, so it is not a match.
    if (units === null || units < 1) continue;
    // An implausible count at a bin is a parsing artefact, not evidence.
    if (units > 500) continue;

    const confidence =
      typeof entry.confidence === 'number' && Number.isFinite(entry.confidence)
        ? entry.confidence
        : null;
    // No confidence means no tier, and EPR-17 decides what happens to a match
    // by its tier. Dropping is the fail-closed reading; defaulting to high
    // would auto-attribute an unrated guess.
    if (confidence === null || confidence < 0 || confidence > 1) continue;

    seen.add(skuId);
    matches.push({ skuId, units, confidence });
  }

  return matches;
}

/**
 * Screens a photograph.
 *
 * @returns {Promise<object|null>} the verdict, or null when screening did not
 *   run or could not be trusted. Null is never an approval.
 */
async function screenImage({
  imageUrl,
  declaredItemType,
  declaredItemCount,
  shortlist = [],
}) {
  if (!isConfigured()) {
    console.log('[screen] GROQ_API_KEY not configured');
    return null;
  }
  if (!imageUrl) {
    console.log('[screen] no imageUrl provided');
    return null;
  }

  console.log('[screen] screening:', { imageUrl: imageUrl.slice(0, 50) + '...', declaredItemType, declaredItemCount });

  // The exact set of ids this request offered. Anything else the model returns
  // is dropped — see `parseSkuMatches`.
  const allowedSkuIds =
    Array.isArray(shortlist) && shortlist.length > 0
      ? new Set(shortlist.map((c) => c.skuId))
      : null;

  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

    try {
      const response = await fetch(ENDPOINT, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${process.env.GROQ_API_KEY}`,
        },
        body: JSON.stringify({
          model: MODEL,
          messages: [
            {
              role: 'user',
              content: [
                {
                  type: 'text',
                  text: buildPrompt(
                    declaredItemType,
                    declaredItemCount,
                    shortlist,
                  ),
                },
                {
                  type: 'image_url',
                  image_url: { url: imageUrl },
                },
              ],
            },
          ],
          temperature: 0,
          // The model supports JSON mode for image inputs. The prompt still
          // states the schema, while this prevents commentary/fences from
          // turning an otherwise usable verdict into a manual-review fallback.
          response_format: { type: 'json_object' },
          // Room for the match list. 300 was sized for the verdict alone, and a
          // response truncated mid-array parses as malformed JSON — which
          // `parseVerdict` correctly returns null for, quietly losing the
          // whole verdict rather than just the recognition block.
          max_completion_tokens: allowedSkuIds ? 700 : 300,
          reasoning_effort: 'none',
        }),
        signal: controller.signal,
      });

      console.log('[screen] Groq response status:', response.status);

      if (response.status === 429) {
        console.warn('[screen] Rate limited; routing to review.');
        return null;
      }

      if (!response.ok) {
        const body = await response.text();
        console.error(`[screen] Groq returned ${response.status}:`, body.slice(0, 200));
        return null;
      }

      const body = await response.json();
      const text = body?.choices?.[0]?.message?.content;
      console.log('[screen] Response text length:', text?.length);
      
      const verdict = parseVerdict(text, allowedSkuIds);
      console.log('[screen] Parsed verdict:', verdict);
      return verdict;
    } finally {
      clearTimeout(timer);
    }
  } catch (err) {
    console.error('[screen] Exception:', err.message);
    return null;
  }
}

module.exports = {
  MODEL,
  parseSkuMatches,
  ITEM_TYPE_LABELS,
  isValidItemType,
  isConfigured,
  buildPrompt,
  parseVerdict,
  screenImage,
};
