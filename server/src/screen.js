/**
 * Chokro — automated photo screening (F2.10).
 *
 * Asks a vision model whether a photograph shows what the user said it shows.
 * The verdict never rejects anything: it either clears a submission for the
 * auto-approve lane, or it does not, in which case a person looks.
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
 */

const MODEL = 'qwen/qwen3.6-27b';
const TIMEOUT_MS = 20000;
const ENDPOINT = 'https://api.groq.com/openai/v1/chat/completions';

/** The closed item-type vocabulary (§6.1), in words a model will recognise. */
const ITEM_TYPE_LABELS = Object.freeze({
  plasticBottles: 'plastic bottles',
  otherPlastic: 'other plastic waste',
  paperCardboard: 'paper or cardboard',
  glass: 'glass',
  metalCans: 'metal or cans',
  electronicWaste: 'electronic waste',
  organicWaste: 'organic waste',
});

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
function buildPrompt(declaredItemType, declaredItemCount) {
  const label = ITEM_TYPE_LABELS[declaredItemType] || declaredItemType;

  return [
    'You are screening a photograph submitted as evidence of waste disposal.',
    '',
    `The person says it shows ${declaredItemCount} item(s) of ${label}.`,
    '',
    'Reply with ONLY a JSON object, no markdown fence and no commentary:',
    '{',
    '  "confidence": <0.0-1.0, how clearly this photo shows waste being disposed of>,',
    '  "itemCount": <how many items you can count, or null if you cannot tell>,',
    '  "itemTypeMatches": <true if the waste matches the stated type>,',
    '  "notes": "<one short sentence for a human reviewer>"',
    '}',
  ].join('\n');
}

/** Extracts the JSON object from a model response that may be fenced. */
function parseVerdict(text) {
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
      notes: typeof parsed.notes === 'string' ? parsed.notes.slice(0, 300) : null,
    };
  } catch {
    return null;
  }
}

/**
 * Screens a photograph.
 *
 * @returns {Promise<object|null>} the verdict, or null when screening did not
 *   run or could not be trusted. Null is never an approval.
 */
async function screenImage({ imageUrl, declaredItemType, declaredItemCount }) {
  if (!isConfigured()) {
    console.log('[screen] GROQ_API_KEY not configured');
    return null;
  }
  if (!imageUrl) {
    console.log('[screen] no imageUrl provided');
    return null;
  }

  console.log('[screen] screening:', { imageUrl: imageUrl.slice(0, 50) + '...', declaredItemType, declaredItemCount });

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
                  text: buildPrompt(declaredItemType, declaredItemCount),
                },
                {
                  type: 'image_url',
                  image_url: { url: imageUrl },
                },
              ],
            },
          ],
          temperature: 0,
          max_tokens: 300,
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
      
      const verdict = parseVerdict(text);
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
  ITEM_TYPE_LABELS,
  isConfigured,
  buildPrompt,
  parseVerdict,
  screenImage,
};
