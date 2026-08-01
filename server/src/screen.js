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
 * TERM PAPER, LIMITATIONS: on the free tier, submitted data may be used to
 * improve Google's models. Users' disposal photographs are sent under those
 * terms. That is defensible for an academic prototype only if disclosed.
 */

const MODEL = 'gemini-2.0-flash';
const TIMEOUT_MS = 20000;

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
  return Boolean(process.env.GEMINI_API_KEY);
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
  if (!isConfigured()) return null;
  if (!imageUrl) return null;

  try {
    // Fetch the image and inline it. Gemini cannot reach an arbitrary URL.
    const imageResponse = await fetch(imageUrl);
    if (!imageResponse.ok) return null;

    const buffer = Buffer.from(await imageResponse.arrayBuffer());
    const mimeType = imageResponse.headers.get('content-type') || 'image/jpeg';

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

    try {
      const response = await fetch(
        `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': process.env.GEMINI_API_KEY,
          },
          body: JSON.stringify({
            contents: [
              {
                parts: [
                  { text: buildPrompt(declaredItemType, declaredItemCount) },
                  {
                    inline_data: {
                      mime_type: mimeType,
                      data: buffer.toString('base64'),
                    },
                  },
                ],
              },
            ],
            generationConfig: { temperature: 0, maxOutputTokens: 300 },
          }),
          signal: controller.signal,
        },
      );

      if (response.status === 429) {
        // Rate limited. Treated as "route to review", never as a failure and
        // never as an approval — the free tier's limits are modest and Google
        // revises them without notice (§4.3).
        console.warn('Screening rate limited; routing to review.');
        return null;
      }

      if (!response.ok) {
        console.error(`Screening returned ${response.status}.`);
        return null;
      }

      const body = await response.json();
      const text = body?.candidates?.[0]?.content?.parts?.[0]?.text;
      return parseVerdict(text);
    } finally {
      clearTimeout(timer);
    }
  } catch (err) {
    console.error('Screening failed:', err.message);
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
