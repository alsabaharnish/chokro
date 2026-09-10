/**
 * Chokro — candidate selection for SKU recognition (EPR-15, SEC-11, NFR-E-7).
 *
 * WHY A SHORTLIST AND NOT THE CATALOGUE
 * Sending a full national product catalogue in a prompt is neither affordable
 * nor accurate. Not affordable because every disposal would carry the whole
 * registry in its input tokens, and this project runs on a free instance with a
 * metered model quota. Not accurate because a model asked to pick from hundreds
 * of near-identical bottles will pick one, confidently, and a confident wrong
 * brand is worse than no brand at all — it attributes one company's kilograms
 * to another.
 *
 * SO THE SHORTLIST IS THE ACCURACY CONTROL, NOT JUST THE COST CONTROL.
 * It narrows by three facts that are already known and are not the model's
 * guess: what the Champion declared they were throwing away, which bin they
 * were standing at, and what has actually been recognised at that bin before.
 *
 * NEVER THROWS. Every failure returns an empty shortlist, which means "no
 * candidates" and therefore "not attributed" — never "attributed as generic"
 * (EPR-16, EPR-19). A registry read that fails must degrade attribution and
 * leave the disposal decision untouched.
 */

const { db } = require('./firebase');

/**
 * The declared item type narrows which gazette categories are plausible.
 *
 * NOT a mapping from the declaration to a reported category — §1's own note is
 * that the seven-value disposal vocabulary does not map onto the gazette's five
 * categories, and guessing is exactly what a DoE data verification finds. This
 * is only a *filter on candidates*: the gazette category that ends up on an
 * attribution comes from the registered product, declared by the producer who
 * makes it and checked when its mass was verified.
 *
 * `plasticOther` deliberately spans four categories, because it genuinely does.
 * A Champion who selects it has told us almost nothing about which category the
 * item belongs to, and narrowing further on that basis would be inventing
 * information.
 */
const CANDIDATE_CATEGORIES = Object.freeze({
  plasticBottle: ['rigid', 'singleUse'],
  plasticOther: ['rigid', 'flexible', 'eps', 'singleUse'],
  // The remaining declared types are not plastic. A registered product is
  // always plastic under this gazette, so these yield no candidates at all —
  // which is correct, and cheaper than asking a model about a glass jar.
  paper: [],
  glass: [],
  metal: [],
  eWaste: [],
  organic: [],
});

/** Whether a declared item type could contain a registered product at all. */
function couldContainRegisteredProduct(declaredItemType) {
  const categories = CANDIDATE_CATEGORIES[declaredItemType];
  return Array.isArray(categories) && categories.length > 0;
}

/**
 * How many candidates one lookup may read before the cap is applied.
 *
 * Deliberately larger than the cap: the ranking below is only meaningful if
 * there is something to rank. Reading exactly `cap` documents and then
 * "ranking" them would order an arbitrary slice of the registry, which is the
 * same as not ranking at all.
 *
 * Still bounded (QA-10). A national register of obligated products is a few
 * thousand SKUs at most, and this reads a few hundred of them per disposal.
 */
const CANDIDATE_READ_LIMIT = 300;

/**
 * Builds the candidate shortlist for one disposal.
 *
 * @param {object} input
 * @param {string} input.declaredItemType   what the Champion said they disposed of
 * @param {string|null} input.district      the bin's district, when known
 * @param {string} input.binId
 * @param {number} input.cap                policy shortlist size (EPR-15)
 * @returns {Promise<Array<object>>} candidates, best first, at most `cap`
 */
async function buildShortlist({
  declaredItemType,
  district = null,
  binId = null,
  cap = 40,
}) {
  if (!couldContainRegisteredProduct(declaredItemType)) return [];

  const categories = CANDIDATE_CATEGORIES[declaredItemType];

  try {
    const firestore = db();

    // Only products with a verified mass are candidates.
    //
    // This is the load-bearing filter, and it is a correctness filter rather
    // than an efficiency one: a match against a product whose mass Chokro has
    // not verified could not be turned into a defensible kilogram anyway
    // (EPR-11), so recognising it would spend a model call to produce a row
    // that reporting must then ignore.
    const snap = await firestore
      .collection('producerSkus')
      .where('massStatus', '==', 'verified')
      .where('status', '==', 'active')
      .limit(CANDIDATE_READ_LIMIT)
      .get();

    const eligible = snap.docs
      .map((d) => ({ skuId: d.id, ...d.data() }))
      .filter((sku) => categories.includes(sku.gazetteCategory))
      .filter((sku) => Number.isInteger(sku.verifiedUnitMassMg));

    if (eligible.length === 0) return [];

    // Local frequency, read once. Which products have actually been recognised
    // at this bin before is the strongest signal available and it costs one
    // document — a bottle brand sold on one street corner is the brand that
    // corner's bin keeps seeing.
    const frequency = binId ? await readBinFrequency(binId) : {};

    const ranked = eligible
      .map((sku) => ({
        sku,
        score: candidateScore({ sku, district, frequency }),
      }))
      .sort((a, b) => {
        if (b.score !== a.score) return b.score - a.score;
        // A stable tiebreak, so the same disposal produces the same shortlist
        // twice. An unstable order would make a re-run of the same photograph
        // send a different prompt and get a different answer, which would make
        // the accuracy audit measure the shortlist rather than the model.
        return a.sku.skuId.localeCompare(b.sku.skuId);
      })
      .slice(0, cap)
      .map(({ sku }) => toCandidate(sku));

    return ranked;
  } catch (err) {
    // Empty, never partial and never a throw. An empty shortlist means "no
    // candidates", which means "not attributed" — the safe direction. A
    // registry read that fails must not fail a disposal (EPR-16).
    console.error('[shortlist] build failed:', err.message);
    return [];
  }
}

/**
 * Ranks a candidate.
 *
 * Three signals, weighted by how much they actually narrow the field:
 *
 *   Local history is worth most. It is observed rather than assumed, and it is
 *   specific to this bin.
 *
 *   District is worth something. Distribution is regional, and a brand sold in
 *   Khulna is less likely in a Dhaka bin — but a national brand is in both, so
 *   this is a nudge and not a filter.
 *
 *   A barcode on file is worth a little. It makes a future scan resolvable
 *   (EPR-18), so keeping such products in the shortlist compounds.
 */
function candidateScore({ sku, district, frequency }) {
  let score = 0;

  const seen = frequency[sku.skuId] || 0;
  // Diminishing: the difference between one sighting and ten matters, the
  // difference between a hundred and a thousand does not.
  if (seen > 0) score += 100 * Math.log10(1 + seen);

  if (district && sku.district && sku.district === district) score += 20;
  if (sku.gtin) score += 5;

  return score;
}

/**
 * How often each product has been recognised at this bin.
 *
 * One document, maintained by the attribution path. Absent for a bin that has
 * never produced an attribution, which is the ordinary state of a new bin and
 * not an error.
 */
async function readBinFrequency(binId) {
  try {
    const snap = await db().collection('binSkuFrequency').doc(binId).get();
    if (!snap.exists) return {};
    const counts = snap.data()?.counts;
    return counts && typeof counts === 'object' ? counts : {};
  } catch (err) {
    // A missing signal degrades the ranking; it must not fail the shortlist.
    console.error('[shortlist] bin frequency read failed:', err.message);
    return {};
  }
}

/**
 * The shape sent to the model.
 *
 * Deliberately minimal, and it carries **no mass**. The model is asked which
 * products are in the picture and how many — it is never told what they weigh,
 * because a model that knew the masses could be nudged toward the heavier
 * option, and because the mass is applied server-side from the verified
 * revision afterwards (EPR-20). What the model returns is a count; what turns a
 * count into a kilogram is not the model's business.
 */
function toCandidate(sku) {
  return {
    skuId: sku.skuId,
    name: typeof sku.name === 'string' ? sku.name.slice(0, 140) : '',
    brand: typeof sku.brand === 'string' ? sku.brand.slice(0, 120) : '',
    gazetteCategory: sku.gazetteCategory,
    polymer: sku.polymer,
    volumeMl: Number.isInteger(sku.volumeMl) ? sku.volumeMl : null,
    hints: Array.isArray(sku.recognitionHints)
      ? sku.recognitionHints.filter((h) => typeof h === 'string').slice(0, 6)
      : [],
  };
}

/**
 * Resolves a scanned GTIN to a verified product (EPR-18).
 *
 * The barcode path, and the reason it is preferred wherever available: visual
 * brand recognition of a crushed bottle in a dim bin at dusk is a hard
 * computer-vision problem, and reading a GTIN is a solved one. Where a Champion
 * scans, accuracy stops being probabilistic.
 *
 * Returns null for an unknown or unverified GTIN. Null is not an error — most
 * scanned barcodes will belong to products no obligated producer has
 * registered, and that is simply not an attribution.
 */
async function resolveGtin(gtin) {
  if (typeof gtin !== 'string' || !/^\d{8,14}$/.test(gtin)) return null;

  try {
    const snap = await db()
      .collection('producerSkus')
      .where('gtin', '==', gtin)
      .where('massStatus', '==', 'verified')
      .limit(2)
      .get();

    if (snap.empty) return null;

    // Two registered products with one barcode is a data problem, not a match.
    // Picking either would attribute one company's mass on a coin flip, so it
    // is refused and logged for the anomaly queue (EPR-45).
    if (snap.size > 1) {
      console.warn(`[shortlist] GTIN ${gtin} resolves to more than one product`);
      return null;
    }

    const doc = snap.docs[0];
    const sku = { skuId: doc.id, ...doc.data() };
    if (!Number.isInteger(sku.verifiedUnitMassMg)) return null;

    return sku;
  } catch (err) {
    console.error('[shortlist] GTIN resolution failed:', err.message);
    return null;
  }
}

module.exports = {
  CANDIDATE_CATEGORIES,
  CANDIDATE_READ_LIMIT,
  couldContainRegisteredProduct,
  buildShortlist,
  candidateScore,
  toCandidate,
  resolveGtin,
};
