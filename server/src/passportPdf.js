/**
 * Chokro — rendering the Plastic Passport (EPR-31, NFR-E-4).
 *
 * ===========================================================================
 * WHY THIS IS ON THE SERVER
 * ===========================================================================
 *
 * EPR-31, verbatim: "a certificate a user's device produced is a certificate a
 * user's device can alter". The client already renders PDFs elsewhere in
 * Chokro, and reusing that here would have been less work. It would also have
 * meant the authoritative compliance artefact was assembled inside a process
 * the producer controls, from figures that process could substitute on the way
 * to the page. The serial, the hash and the figures are all minted in
 * `passports.js` and rendered here, in a process the producer does not run.
 *
 * ===========================================================================
 * BANGLA, AND WHY THIS REFUSES RATHER THAN DEGRADES
 * ===========================================================================
 *
 * NFR-E-4 requires a Bangla edition. Bengali is a complex script: it reorders
 * vowel signs ahead of their consonant, and forms conjuncts (`প্লাস্টিক` is
 * nine codepoints and five glyphs). A renderer without a Bengali font does not
 * produce ugly Bangla — it produces *nothing*, because pdfkit's built-in
 * Helvetica has no Bengali glyphs at all and simply omits them. The text
 * silently disappears from the page.
 *
 * A compliance certificate that quietly loses its text is worse than a missing
 * one: the producer files it, the regulator receives a page of headings with
 * blank values, and nobody discovers the fault until it matters. So
 * `renderPassportPdf` REFUSES a Bangla edition when the font is absent, with an
 * error naming the missing file. It does not fall back to English and label it
 * Bangla, and it does not emit the page and hope.
 *
 * Verified against the bundled font before this was written: fontkit 2.0.4
 * ships the Universal Shaping Engine with `bng2` in GSUB and the Indic
 * features, and shapes Bengali conjuncts correctly — `প্লাস্টিক` collapses
 * nine codepoints to five glyphs with no `.notdef`.
 *
 * It also has a crash bug on NULL GPOS anchors, which ordinary Bangla hits;
 * `fontkitNullAnchorFix` corrects it and explains why. That fix is installed
 * before any Bengali text is measured, because pdfkit shapes text at the
 * moment it is written to the page — including inside `heightOfString`, which
 * this module calls to decide page breaks.
 *
 * ===========================================================================
 * WHY BOTH EDITIONS USE TWO FONTS
 * ===========================================================================
 *
 * Noto Sans Bengali has NO LATIN LETTERS AT ALL. It covers the Bengali block,
 * the danda, the ASCII digits and the ASCII punctuation — and not one of
 * `A`–`Z` or `a`–`z`. Measured on the bundled file: all 52 Latin letters map to
 * glyph 0.
 *
 * That is not a cosmetic problem. A Bangla certificate still has to print
 * `Coca-Cola Bangladesh Beverages Ltd.`, `DoE/EPR/2026/0417` and
 * `mixedPlastics-2015-uk-v1` — the producer's own legal identity, its
 * regulator's reference number, and the emission factor version that makes the
 * carbon line reproducible. In a single-font Bangla edition every one of those
 * renders as nothing at all.
 *
 * So the Bangla edition composes two faces, and the split is driven by what the
 * faces ACTUALLY CONTAIN rather than by a hardcoded Unicode range: `splitRuns`
 * asks each face whether it has a glyph. A range-based splitter would have to
 * be kept in step with the string table by hand, and the failure mode of
 * getting it wrong is invisible text — which is the whole thing this module
 * exists to prevent. The coverage test cannot drift out of step with the font,
 * because it *is* the font.
 *
 * It asks BOTH faces, and that took three attempts to get right. See the
 * section below.
 *
 * The same fault runs in the other direction, and it is worse. Helvetica has no
 * Bengali either, and `মেঘনা প্যাকেজিং লিমিটেড` in Helvetica does not come out
 * blank — it comes out as `šéÇ™‰¨›â ªœÙ¯›é•œyœ›ù`, because the bytes get
 * reinterpreted through a Latin encoding. Most Bangladeshi producers have Bangla
 * legal names, so an English edition with only Helvetica prints the producer's
 * own legal identity as mojibake. A regulator reading that cannot tell a
 * rendering fault from a corrupted record.
 *
 * So BOTH editions compose both faces. The locale decides which face neutral
 * characters default to and which language the fixed text is in; it does not
 * decide which scripts can be rendered. Producer-supplied fields — legal name,
 * trade name, the person who attested, a revocation reason — are whatever the
 * producer typed, in either script, and both editions have to print them
 * faithfully.
 *
 * When Bengali text is encountered and the Bengali face is unavailable,
 * `splitRuns` throws rather than let the mojibake through. That is a broken
 * deployment (the font is committed to the repository), and on a document whose
 * only purpose is to be trusted, failing is better than lying.
 *
 * ===========================================================================
 * AND THE SAME PROBLEM FOR EVERY OTHER SCRIPT
 * ===========================================================================
 *
 * Fixing the Bengali case left a two-way decision — Bengali face, or Helvetica
 * — with Helvetica as the fallback for anything the Bengali font lacked. But
 * "the Bengali font lacks it" is not the same statement as "Helvetica has it",
 * and for most of Unicode NEITHER face has it.
 *
 * Measured: `中国可乐有限公司` as an organisation's legal name rendered on the
 * certificate as `N-VýSiNPg –PQlSø`. Not blank — mojibake, exactly as the
 * Bengali-in-Helvetica case did, because Helvetica is an AFM font encoded
 * through WinAnsi and the bytes get reinterpreted. Arabic, Devanagari, emoji
 * and a decomposed accent all behaved the same way.
 *
 * A Bangladeshi producer with a Chinese or Middle Eastern parent is not a
 * hypothetical, and `declarationAttestedByName` is a person's name in whatever
 * script that person writes it in.
 *
 * So `splitRuns` now has a third outcome. Each character is, in order:
 *
 *   NORMALISED — NFC first, so `e` + U+0301 becomes `é`, which Helvetica does
 *     have. Refusing a decomposed accent would block a legitimate name over an
 *     encoding detail invisible to whoever typed it.
 *
 *   STRIPPED if it is invisible — controls, zero-width spaces, bidi marks, the
 *     BOM, soft hyphens. These carry nothing a reader would see, they arrive by
 *     accident from a paste out of Word, and refusing a certificate over one
 *     would block real work for no gain.
 *
 *   REFUSED if it is visible and neither face can draw it. A legal name is the
 *     one field on this document that must be reproduced exactly, and a
 *     certificate that silently prints a different name than the company's is
 *     not a lesser version of a correct certificate — it is a false one.
 *
 * (This is also why `CO2e` is written with an ASCII 2 rather than the subscript
 * `₂`: neither face has that glyph.)
 */

const fs = require('fs');
const path = require('path');
const PDFDocument = require('pdfkit');
const fontkit = require('fontkit');
const passports = require('./passports');
const fontkitNullAnchorFix = require('./fontkitNullAnchorFix');

const FONT_DIR = path.join(__dirname, '..', 'assets', 'fonts');
const BENGALI_FONT = path.join(FONT_DIR, 'NotoSansBengali-Regular.ttf');
const BENGALI_FONT_BOLD = path.join(FONT_DIR, 'NotoSansBengali-Bold.ttf');

const MG_PER_KILOGRAM = 1000000;

const LOCALES = Object.freeze(['en', 'bn']);

/**
 * The bilingual string table.
 *
 * Held here rather than in the client's localisation because these are the
 * words on a legal artefact. The Bangla is the operative text of the Bangla
 * edition, not a convenience translation of an English original, and the
 * boundary statements in particular have to say the same thing in both — a
 * disclaimer that is weaker in one language than the other is not a disclaimer.
 */
const STRINGS = Object.freeze({
  en: {
    title: 'Plastic Passport',
    subtitle: 'Producer collection evidence',
    issuer: 'Issued by Chokro',
    serial: 'Serial',
    period: 'Reporting period',
    producer: 'Producer',
    tradeName: 'Trade name',
    doeReg: 'DoE registration',
    sizeClass: 'Industry size',
    collected: 'Collected through Chokro',
    declared: 'Put on market (declared by producer)',
    rate: 'Collection percentage',
    target: 'Applicable gazette target',
    obligationYear: 'Obligation year',
    byCategory: 'By gazette category',
    byPolymer: 'By polymer',
    category: 'Category',
    collectedCol: 'Collected',
    declaredCol: 'Declared',
    evidence: 'Evidence',
    attributions: 'Attributed collection events',
    disposals: 'Disposal events',
    uniqueSkus: 'Distinct products',
    estimatedShare: 'Share resting on estimated mass',
    reversed: 'Reversed attributions',
    carbon: 'Indicative avoided emissions',
    carbonFactor: 'Emission factor version',
    verifyTitle: 'Verification',
    verifyBody: 'Confirm this certificate at',
    contentHash: 'Content hash (SHA-256)',
    issuedAt: 'Issued',
    issuedBy: 'Issued by',
    status: 'Status',
    boundaries: 'What this certificate does and does not state',
    notDeclared: 'not declared',
    noRate: 'Not stated — no put-on-market declaration has been filed for this period',
    noRateNilDeclared:
      'Not stated — this period was declared nil, and a share of nil is not a '
      + 'figure',
    noTarget: 'Not stated — no obligation start date is recorded',
    noCarbon: 'Not stated',
    noCarbonUncertain:
      'Not stated — too much of this period’s mass rests on estimates',
    attestedBy: 'Declaration attested by',
    page: 'Page',
    of: 'of',
    kg: 'kg',
    statusIssued: 'Issued and current',
    statusSuperseded: 'Superseded by a later certificate',
    statusRevoked: 'Revoked',
  },
  bn: {
    title: 'প্লাস্টিক পাসপোর্ট',
    subtitle: 'উৎপাদকের সংগ্রহের প্রমাণ',
    issuer: 'চক্র কর্তৃক প্রদত্ত',
    serial: 'ক্রমিক নম্বর',
    period: 'প্রতিবেদন সময়কাল',
    producer: 'উৎপাদক',
    tradeName: 'বাণিজ্যিক নাম',
    doeReg: 'পরিবেশ অধিদপ্তর নিবন্ধন',
    sizeClass: 'শিল্পের আকার',
    collected: 'চক্রের মাধ্যমে সংগৃহীত',
    declared: 'বাজারে ছাড়া হয়েছে (উৎপাদক ঘোষিত)',
    rate: 'সংগ্রহের শতকরা হার',
    target: 'প্রযোজ্য গেজেট লক্ষ্যমাত্রা',
    obligationYear: 'বাধ্যবাধকতার বছর',
    byCategory: 'গেজেট শ্রেণি অনুযায়ী',
    byPolymer: 'পলিমার অনুযায়ী',
    category: 'শ্রেণি',
    collectedCol: 'সংগৃহীত',
    declaredCol: 'ঘোষিত',
    evidence: 'প্রমাণ',
    attributions: 'চিহ্নিত সংগ্রহের ঘটনা',
    disposals: 'নিষ্কাশনের ঘটনা',
    uniqueSkus: 'পৃথক পণ্য',
    estimatedShare: 'অনুমিত ভরের উপর নির্ভরশীল অংশ',
    reversed: 'বাতিলকৃত সংযুক্তি',
    carbon: 'পরিহারকৃত নিঃসরণের সূচক হিসাব',
    carbonFactor: 'নিঃসরণ গুণকের সংস্করণ',
    verifyTitle: 'যাচাইকরণ',
    verifyBody: 'এই সনদ যাচাই করুন',
    contentHash: 'বিষয়বস্তুর হ্যাশ (SHA-256)',
    issuedAt: 'প্রদানের তারিখ',
    issuedBy: 'প্রদানকারী',
    status: 'অবস্থা',
    boundaries: 'এই সনদ কী বলে এবং কী বলে না',
    notDeclared: 'ঘোষিত হয়নি',
    noRate:
      'উল্লেখ করা হয়নি — এই সময়কালের জন্য বাজারে ছাড়ার কোনো ঘোষণা দাখিল করা হয়নি',
    noRateNilDeclared:
      'উল্লেখ করা হয়নি — এই সময়কালে শূন্য ঘোষণা করা হয়েছে, এবং শূন্যের অংশ কোনো '
      + 'হিসাব নয়',
    noTarget: 'উল্লেখ করা হয়নি — বাধ্যবাধকতা শুরুর তারিখ নথিভুক্ত নেই',
    noCarbon: 'উল্লেখ করা হয়নি',
    noCarbonUncertain:
      'উল্লেখ করা হয়নি — এই সময়কালের ভরের অত্যধিক অংশ অনুমানের উপর নির্ভরশীল',
    attestedBy: 'ঘোষণা প্রত্যয়নকারী',
    page: 'পৃষ্ঠা',
    of: '/',
    kg: 'কেজি',
    statusIssued: 'প্রদত্ত ও বর্তমান',
    statusSuperseded: 'পরবর্তী সনদ দ্বারা প্রতিস্থাপিত',
    statusRevoked: 'বাতিলকৃত',
  },
});

/** Gazette category names, in both languages. */
const CATEGORY_NAMES = Object.freeze({
  en: {
    rigid: 'Rigid packaging',
    flexible: 'Flexible packaging',
    eps: 'Expanded polystyrene',
    singleUse: 'Single-use items',
    other: 'Other plastics',
  },
  bn: {
    rigid: 'কঠিন মোড়ক',
    flexible: 'নমনীয় মোড়ক',
    eps: 'প্রসারিত পলিস্টাইরিন',
    singleUse: 'একবার ব্যবহার্য সামগ্রী',
    other: 'অন্যান্য প্লাস্টিক',
  },
});

const POLYMER_NAMES = Object.freeze({
  en: {
    pet: 'PET', hdpe: 'HDPE', pvc: 'PVC', ldpe: 'LDPE',
    pp: 'PP', ps: 'PS', multilayer: 'Multilayer', other: 'Other',
  },
  bn: {
    pet: 'পিইটি', hdpe: 'এইচডিপিই', pvc: 'পিভিসি', ldpe: 'এলডিপিই',
    pp: 'পিপি', ps: 'পিএস', multilayer: 'বহুস্তর', other: 'অন্যান্য',
  },
});

const SIZE_CLASS_NAMES = Object.freeze({
  en: { micro: 'Micro', small: 'Small', medium: 'Medium', large: 'Large' },
  bn: { micro: 'অতিক্ষুদ্র', small: 'ক্ষুদ্র', medium: 'মধ্যম', large: 'বৃহৎ' },
});

/**
 * The boundary statements, in both languages (EPR-32, §6.6).
 *
 * These are the reason the certificate is defensible. Every one of them is a
 * limit the spec requires stated on the artefact itself, because a figure
 * without its boundary invites exactly the claim §11's prohibited-claims list
 * forbids.
 */
const BOUNDARIES = Object.freeze({
  en: [
    'Collection percentages count only material collected through Chokro. '
      + 'They are not a producer’s total national collection, and this '
      + 'certificate is not a statement of compliance with the 2024 gazette.',
    'This certificate does not state a recycling rate. Chokro records '
      + 'collection; it does not hold evidence of what was recycled '
      + 'downstream, and a collection figure is not a recycling figure.',
    'Put-on-market figures are declared by the producer under attestation. '
      + 'Chokro has not independently verified them.',
    'Avoided-emissions figures are indicative, derived from a published '
      + 'external emission factor, and are not a verified carbon credit or '
      + 'offset of any kind.',
    'Verification confirms only that this document is the one Chokro issued '
      + 'and has not been superseded. It is not an endorsement of the '
      + 'producer.',
  ],
  bn: [
    'সংগ্রহের শতকরা হার কেবল চক্রের মাধ্যমে সংগৃহীত উপাদান গণনা করে। '
      + 'এটি কোনো উৎপাদকের সমগ্র জাতীয় সংগ্রহ নয়, এবং এই সনদ ২০২৪ সালের '
      + 'গেজেট পরিপালনের ঘোষণা নয়।',
    'এই সনদ পুনঃচক্রায়নের হার উল্লেখ করে না। চক্র সংগ্রহের নথি রাখে; '
      + 'পরবর্তী ধাপে কী পুনঃচক্রায়িত হয়েছে তার প্রমাণ চক্রের কাছে নেই, '
      + 'এবং সংগ্রহের হিসাব পুনঃচক্রায়নের হিসাব নয়।',
    'বাজারে ছাড়ার পরিমাণ উৎপাদক প্রত্যয়নসহ ঘোষণা করেছেন। চক্র তা '
      + 'স্বতন্ত্রভাবে যাচাই করেনি।',
    'পরিহারকৃত নিঃসরণের পরিমাণ একটি প্রকাশিত বহিঃস্থ গুণক থেকে প্রাপ্ত '
      + 'সূচক হিসাব মাত্র, কোনো যাচাইকৃত কার্বন ক্রেডিট বা অফসেট নয়।',
    'যাচাইকরণ কেবল নিশ্চিত করে যে এই নথি চক্র কর্তৃক প্রদত্ত এবং '
      + 'প্রতিস্থাপিত হয়নি। এটি উৎপাদকের কোনো অনুমোদন নয়।',
  ],
});

/** Bengali digits, for the Bangla edition's numerals. */
const BENGALI_DIGITS = ['০', '১', '২', '৩', '৪', '৫', '৬', '৭', '৮', '৯'];

const BENGALI_MONTHS = [
  'জানুয়ারি', 'ফেব্রুয়ারি', 'মার্চ', 'এপ্রিল', 'মে', 'জুন',
  'জুলাই', 'আগস্ট', 'সেপ্টেম্বর', 'অক্টোবর', 'নভেম্বর', 'ডিসেম্বর',
];

const ENGLISH_MONTHS = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/** Whether the Bengali font is present. Checked, never assumed. */
function bengaliFontAvailable() {
  try {
    return fs.statSync(BENGALI_FONT).size > 50000;
  } catch (_) {
    return false;
  }
}

/**
 * Renders the certificate.
 *
 * Resolves to a Buffer. Rejects — rather than emitting a page — when a Bangla
 * edition is asked for and the font is not there.
 */
async function renderPassportPdf({ passport, verifyBaseUrl }) {
  const locale = LOCALES.includes(passport?.locale) ? passport.locale : 'en';
  return renderEdition({ passport, locale, verifyBaseUrl });
}

async function renderEdition({ passport, locale, verifyBaseUrl }) {
  if (!passport || !passport.figures) {
    throw new Error('Cannot render a passport without its stored figures.');
  }

  if (locale === 'bn' && !bengaliFontAvailable()) {
    // Named explicitly, because the operator reading this log is the person who
    // has to put the file there.
    throw new Error(
      'Cannot render the Bangla edition: the Bengali font is missing at '
        + `${BENGALI_FONT}. Refusing rather than emitting a certificate whose `
        + 'Bangla text would silently render blank.',
    );
  }

  const t = STRINGS[locale];
  const f = passport.figures;
  const doc = new PDFDocument({
    size: 'A4',
    margins: { top: 56, bottom: 64, left: 56, right: 56 },
    // Required by `drawPageNumbers`, which numbers every page after the
    // content is laid out and so has to switch back to pages already written.
    // Without this, pdfkit flushes each page as it is finished and
    // `switchToPage` on an earlier one throws — a fault that only appears once
    // a certificate runs past one page, which the Bangla edition does.
    bufferPages: true,
    info: {
      Title: `${t.title} — ${passport.serial}`,
      Author: 'Chokro',
      Subject: `${f.organizationTradeName || f.organizationLegalName} · ${f.periodId}`,
      Keywords: `plastic passport,EPR,${passport.serial},${f.periodId}`,
      Creator: 'Chokro EPR producer portal',
    },
    // A certificate a screen reader cannot read is a certificate a
    // vision-impaired regulator cannot check.
    pdfVersion: '1.7',
    lang: locale === 'bn' ? 'bn-BD' : 'en',
    displayTitle: true,
  });

  const chunks = [];
  doc.on('data', (chunk) => chunks.push(chunk));
  const finished = new Promise((resolve, reject) => {
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);
  });

  // Fonts. The Bangla edition uses Noto Sans Bengali throughout — including
  // for Latin runs, which it covers — rather than switching fonts mid-line,
  // because a mid-line switch loses the shaping context Bengali depends on.
  const body = registerFonts(doc, locale);

  const ctx = { doc, t, f, locale, passport, body, verifyBaseUrl };

  drawHeader(ctx);
  drawStatusBanner(ctx);
  drawHeadline(ctx);
  drawCategoryTable(ctx);
  drawPolymerTable(ctx);
  drawEvidence(ctx);
  drawBoundaries(ctx);
  drawVerification(ctx);
  drawPageNumbers(ctx);

  doc.end();
  return finished;
}

/**
 * Registers the fonts and returns the faces to compose with.
 *
 * The Bengali face is registered for BOTH editions whenever the file is
 * present, because producer-supplied text can be in either script regardless
 * of which edition is being rendered. `NotoSansBengali-Bold.ttf` is optional:
 * without it the regular face is used for Bengali headings too, which is a
 * visual compromise rather than a correctness one.
 *
 * `coverage` is the fontkit handle for the Bengali face — what `splitRuns`
 * interrogates, so the fallback decision is made against the actual glyph table
 * rather than against an assumption about it.
 */
function registerFonts(doc, locale) {
  let bengali = null;
  let bengaliBold = null;
  let coverage = null;

  if (bengaliFontAvailable()) {
    // Before the font is registered, and so before pdfkit can shape anything
    // with it. `registerFont` is lazy, but `heightOfString` is not.
    fontkitNullAnchorFix.install(BENGALI_FONT);

    doc.registerFont('bn', BENGALI_FONT);

    // The same probe the shim runs, but THROUGH PDFKIT — which is the consumer
    // that matters. The shim patches the fontkit copy it resolved; if npm ever
    // hands pdfkit a different one, the shim's own self-test passes and pdfkit
    // still crashes. Measuring a string that crashes unpatched, with the
    // registered font, is the only check that covers that case.
    //
    // `widthOfString` shapes the text, so this exercises the same path the page
    // will, at the cost of one shaping call per document.
    try {
      doc.font('bn').fontSize(10)
        .widthOfString(fontkitNullAnchorFix.SELF_TEST_STRING);
    } catch (err) {
      throw new Error(
        'pdfkit cannot shape Bengali even though the fontkit NULL-anchor fix '
          + `reported success: ${err.message}. This process almost certainly `
          + 'has two fontkit copies, and the patched one is not the one pdfkit '
          + 'uses. Refusing to render rather than emitting a certificate with '
          + 'missing text.',
      );
    }

    bengali = 'bn';
    bengaliBold = 'bn';
    try {
      if (fs.statSync(BENGALI_FONT_BOLD).size > 50000) {
        doc.registerFont('bn-bold', BENGALI_FONT_BOLD);
        bengaliBold = 'bn-bold';
      }
    } catch (_) {
      // Regular face for Bengali headings. Noted, not fatal.
    }
    coverage = fontkit.openSync(BENGALI_FONT);
  }

  const primaryScript = locale === 'bn' ? 'bengali' : 'latin';

  return {
    // Helvetica needs no file: it is one of the PDF standard 14, present in
    // every conforming reader. A bundled Latin face would be one more thing to
    // ship and one more thing to be missing.
    latin: 'Helvetica',
    latinBold: 'Helvetica-Bold',
    bengali,
    bengaliBold,
    coverage,
    primaryScript,
    // The primary face, for the few places that set a font directly.
    regular: primaryScript === 'bengali' && bengali ? bengali : 'Helvetica',
    bold:
      primaryScript === 'bengali' && bengaliBold ? bengaliBold : 'Helvetica-Bold',
  };
}

/**
 * Splits text into runs, each tagged with the script whose face can render it.
 *
 * The rule, in order:
 *
 *  1. A character in the Bengali block (plus the danda, which lives in the
 *     Devanagari block but is Bengali punctuation) MUST use the Bengali face.
 *     Helvetica would not error on it — it would print mojibake, so this is the
 *     one case that refuses outright when the face is unavailable.
 *  2. A character the Bengali face has no glyph for MUST use Helvetica. This is
 *     what catches the Latin letters, and it catches them by asking the font
 *     rather than by assuming a range.
 *  3. Anything else — space, ASCII digits, punctuation, the em dash — is
 *     covered by both, so it stays with the run in progress. A neutral
 *     character that switched face would break `Ltd.` across two fonts for no
 *     reason, and would set the space inside `DoE/EPR/2026/0417` in a different
 *     face from the text around it. With no run in progress it takes the
 *     edition's primary script.
 */
function splitRuns(body, text) {
  // NFC first. `e` + U+0301 has no glyph in either face, but the composed
  // `é` is in WinAnsi — so normalising renders a legitimate name that
  // refusing would have blocked over an invisible encoding detail.
  const value = normaliseForRender(String(text ?? ''));
  if (value.length === 0) {
    return [{ text: '', script: body.primaryScript }];
  }

  const runs = [];
  let current = null;

  for (const ch of value) {
    const cp = ch.codePointAt(0);

    if (isInvisible(cp)) continue;

    const inBengaliBlock =
      (cp >= 0x0980 && cp <= 0x09ff) || cp === 0x0964 || cp === 0x0965;

    let script;
    if (inBengaliBlock) {
      if (!body.bengali) {
        throw unrenderable(
          'Cannot render Bengali text: the Bengali font is missing at '
            + `${BENGALI_FONT}. Refusing rather than emitting a certificate on `
            + 'which the text would appear as mojibake.',
          { codePoint: cp, text: value },
        );
      }
      script = 'bengali';
      // Not Bengali script. Which faces can actually draw it?
      //
      // THIS ASKS BOTH. An earlier version asked only the Bengali face and, if
      // it had a glyph, handed the character to the run in progress — usually
      // Helvetica. That leaves 17 code points the bundled Bengali face covers
      // and WinAnsi does not, printing as mojibake with no error:
      //
      //   U+2010 HYPHEN          — what a word processor substitutes for `-`
      //   U+20B9 RUPEE SIGN
      //   U+02BC MODIFIER APOSTROPHE — common in transliterated names
      //   U+0951..U+1CF7         — Vedic and Devanagari-extended marks
      //
      // `Coca` + U+2010 + `Cola Ltd.` is a legal name somebody will paste out
      // of Word, and it routed entirely to Helvetica.
    } else {
      const bengaliCanDraw = Boolean(
        body.bengali && body.coverage && body.coverage.glyphForCodePoint(cp).id !== 0,
      );
      const latinCanDraw = helveticaCovers(cp);

      if (bengaliCanDraw && latinCanDraw) {
        // Genuinely neutral — a digit, a space, punctuation. Stays with the run
        // in progress so `Ltd.` is not broken across two faces for no reason.
        script = current ? current.script : body.primaryScript;
      } else if (latinCanDraw) {
        script = 'latin';
      } else if (bengaliCanDraw) {
        // Only the Bengali face has it. It must go there even mid-Latin-run:
        // this is the branch that catches U+2010 and U+20B9.
        script = 'bengali';
      } else {
      // NEITHER FACE CAN DRAW IT.
      //
      // The case this branch exists for: falling through to Helvetica here is
      // what printed `中国可乐有限公司` as `N-VýSiNPg –PQlSø`. A legal name is
      // the one field on this document that must be reproduced exactly.
        throw unrenderable(
          `Cannot render U+${cp.toString(16).toUpperCase().padStart(4, '0')} `
            + `(${JSON.stringify(String.fromCodePoint(cp))}) in `
            + `${JSON.stringify(truncate(value))}: neither the bundled Bengali `
            + 'face nor Helvetica has a glyph for it, so it would print as '
            + 'mojibake. Refusing to issue a certificate that misspells the '
            + 'text it certifies.',
          { codePoint: cp, text: value },
        );
      }
    }

    if (current && current.script === script) {
      current.text += ch;
    } else {
      current = { text: ch, script };
      runs.push(current);
    }
  }

  // Everything was invisible. An empty run rather than no runs, so callers
  // that index `runs[0]` do not have to guard.
  return runs.length > 0 ? runs : [{ text: '', script: body.primaryScript }];
}

/**
 * Composes decomposed sequences so a face that has the composed form can draw
 * it.
 *
 * Also folds the non-breaking space to a plain one: both faces have it, but
 * pdfkit does not break a line on it, so a long name held together by pasted
 * NBSPs would overflow its column rather than wrap.
 */
function normaliseForRender(text) {
  return text.normalize('NFC').replace(/\u00a0/g, ' ');
}

/**
 * Whether a code point is invisible, and therefore safe to drop.
 *
 * Controls, the zero-width family, bidi overrides, the BOM, soft hyphens and
 * interlinear annotation marks. None of these draws anything, all of them
 * arrive by accident from a paste, and refusing a certificate over one would
 * block real work for no gain. Tab and newline are included: this renderer
 * lays text out itself, and a raw newline inside a producer's trade name is a
 * paste artefact rather than an intended line break.
 */
function isInvisible(cp) {
  return (
    cp < 0x20                                   // C0 controls, incl. tab/newline
    || (cp >= 0x7f && cp <= 0x9f)               // DEL and C1 controls
    || cp === 0x00ad                            // soft hyphen
    || (cp >= 0x200b && cp <= 0x200f)           // ZWSP..RLM
    || (cp >= 0x202a && cp <= 0x202e)           // bidi embedding/override
    || (cp >= 0x2060 && cp <= 0x206f)           // word joiner, invisible ops
    || cp === 0xfeff                            // BOM
    || (cp >= 0xfff9 && cp <= 0xfffb)           // interlinear annotation
  );
}

/**
 * Whether Helvetica can draw a code point.
 *
 * Helvetica is one of the PDF standard 14: an AFM font that pdfkit encodes
 * through WinAnsi. A character outside WinAnsi is not substituted or flagged —
 * the byte is reinterpreted, which is what produces mojibake. So coverage is
 * decided against the WinAnsi repertoire rather than by asking pdfkit, which
 * will happily encode anything.
 *
 * The set is Latin-1 minus the C1 range, plus the WinAnsi additions in 0x80–
 * 0x9F's printable slots.
 */
const WINANSI_EXTRAS = new Set([
  0x20ac, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021, 0x02c6, 0x2030,
  0x0160, 0x2039, 0x0152, 0x017d, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022,
  0x2013, 0x2014, 0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0x017e, 0x0178,
]);

function helveticaCovers(cp) {
  if (cp >= 0x20 && cp <= 0x7e) return true;          // ASCII printable
  if (cp >= 0x00a0 && cp <= 0x00ff) return true;      // Latin-1 supplement
  return WINANSI_EXTRAS.has(cp);
}

/**
 * A refusal that carries what could not be rendered.
 *
 * Typed, because the route distinguishes "this deployment is broken" from
 * "this producer's data cannot be certified as it stands" — the first is
 * Chokro's problem and the second needs the producer to be told which field.
 */
function unrenderable(message, { codePoint, text }) {
  const error = new Error(message);
  error.code = 'unrenderable_text';
  error.codePoint = codePoint;
  error.text = truncate(text);
  return error;
}

function truncate(text, max = 60) {
  const value = String(text ?? '');
  return value.length <= max ? value : `${value.slice(0, max)}…`;
}

/** The registered face for one run. */
function faceFor(body, run, bold) {
  if (run.script === 'bengali' && body.bengali) {
    return bold ? body.bengaliBold : body.bengali;
  }
  return bold ? body.latinBold : body.latin;
}

/**
 * Writes text that may wrap, composing faces as needed.
 *
 * Mixed runs are chained with pdfkit's `continued`, which is the only way to
 * change face mid-paragraph and keep the line breaking correct. `continued`
 * does not respect `align`, so a mixed run is always left-aligned — every
 * aligned figure on this certificate is single-face, and
 * `passportPdf.test.js` asserts that stays true.
 */
function writeFlow(doc, body, text, x, y, width, opts = {}) {
  const {
    size = 9.5,
    bold = false,
    color = '#1E2937',
    align = 'left',
    lineGap,
  } = opts;

  const runs = splitRuns(body, text);

  if (runs.length === 1) {
    doc
      .font(faceFor(body, runs[0], bold))
      .fontSize(size)
      .fillColor(color)
      .text(runs[0].text, x, y, { width, align, lineGap });
    return;
  }

  runs.forEach((run, index) => {
    const last = index === runs.length - 1;
    doc.font(faceFor(body, run, bold)).fontSize(size).fillColor(color);
    if (index === 0) {
      doc.text(run.text, x, y, { width, continued: !last, lineGap });
    } else {
      doc.text(run.text, { continued: !last, lineGap });
    }
  });
}

/**
 * Writes one line that must not wrap, at a computed alignment.
 *
 * Table cells and the page footer. Runs are measured and placed by hand rather
 * than chained, because `continued` and `align` do not compose — and a
 * right-aligned mass column that silently left-aligned would make the figures
 * hard to compare, which is the one thing a column of figures is for.
 */
function writeLine(doc, body, text, x, y, width, opts = {}) {
  const {
    size = 9.5,
    bold = false,
    color = '#1E2937',
    align = 'left',
  } = opts;

  const runs = splitRuns(body, text);

  const widths = runs.map((run) => {
    doc.font(faceFor(body, run, bold)).fontSize(size);
    return doc.widthOfString(run.text);
  });
  const total = widths.reduce((a, b) => a + b, 0);

  let cursor = x;
  if (align === 'right') cursor = x + width - total;
  else if (align === 'center') cursor = x + (width - total) / 2;

  let height = 0;
  runs.forEach((run, index) => {
    doc
      .font(faceFor(body, run, bold))
      .fontSize(size)
      .fillColor(color)
      .text(run.text, cursor, y, { lineBreak: false });
    height = Math.max(height, doc.currentLineHeight());
    cursor += widths[index];
  });

  doc.y = y + height;
}

/**
 * The height mixed text will occupy.
 *
 * Measured with the face that carries the most characters. Bengali and
 * Helvetica have different line heights, so for genuinely mixed text this is an
 * estimate — used only to decide page breaks, and only ever generous by a
 * line rather than short by one, because `drawBoundaries` adds slack.
 */
function heightOfFlow(doc, body, text, width, { size = 9.5, bold = false } = {}) {
  const runs = splitRuns(body, text);
  const dominant = runs.reduce(
    (best, run) => (run.text.length > best.text.length ? run : best),
    runs[0],
  );
  doc.font(faceFor(body, dominant, bold)).fontSize(size);
  return doc.heightOfString(String(text ?? ''), { width });
}

function drawHeader(ctx) {
  const { doc, t, f, body, locale, passport } = ctx;
  const left = doc.page.margins.left;
  const width = doc.page.width - left - doc.page.margins.right;

  writeFlow(doc, body, t.title, left, doc.y, width, {
    size: 22,
    bold: true,
    color: '#0F172A',
  });

  writeFlow(doc, body, `${t.subtitle} · ${t.issuer}`, left, doc.y, width, {
    size: 10.5,
    color: '#475569',
  });

  doc.moveDown(0.6);

  doc
    .moveTo(left, doc.y)
    .lineTo(left + width, doc.y)
    .lineWidth(1.2)
    .strokeColor('#0EA5A4')
    .stroke();

  doc.moveDown(0.8);

  const y0 = doc.y;
  const half = width / 2;

  writeFlow(doc, body, t.serial, left, y0, half - 8, {
    size: 9,
    color: '#64748B',
  });
  // The serial in a monospaced face even in the Bangla edition: it is retyped
  // into a verification page, and Latin base32 is easier to transcribe from
  // Courier than from anything proportional.
  doc
    .font('Courier-Bold')
    .fontSize(13)
    .fillColor('#0F172A')
    .text(passport.serial, left, doc.y + 1, { lineBreak: false });
  const serialBottom = doc.y;

  const rightX = left + half;
  writeFlow(doc, body, t.period, rightX, y0, half, {
    size: 9,
    color: '#64748B',
  });
  writeFlow(doc, body, formatPeriod(f.periodId, locale), rightX, doc.y + 1, half, {
    size: 13,
    bold: true,
    color: '#0F172A',
  });

  doc.y = Math.max(serialBottom, doc.y);
  doc.moveDown(1);

  // The producer's identity. Legal name first, because that is who the
  // obligation attaches to; the trade name is what a reader recognises.
  //
  // Every one of these is Latin in practice, which is exactly why the Bangla
  // edition needs the fallback face.
  labelled(ctx, t.producer, f.organizationLegalName || '—');
  if (f.organizationTradeName && f.organizationTradeName !== f.organizationLegalName) {
    labelled(ctx, t.tradeName, f.organizationTradeName);
  }
  if (f.doeRegistrationNo) {
    labelled(ctx, t.doeReg, f.doeRegistrationNo);
  }
  if (f.sizeClass && SIZE_CLASS_NAMES[locale][f.sizeClass]) {
    labelled(ctx, t.sizeClass, SIZE_CLASS_NAMES[locale][f.sizeClass]);
  }
}

/**
 * The status banner (EPR-30).
 *
 * A superseded or revoked certificate says so on its own face, in colour, above
 * the figures — not in a footnote. The whole reason reissue supersedes rather
 * than overwrites is that the old copy stays in circulation; a copy that does
 * not announce its own status defeats that.
 */
function drawStatusBanner({ doc, t, body, passport }) {
  const status = passport.status || 'issued';
  if (status === 'issued') return;

  const left = doc.page.margins.left;
  const width = doc.page.width - left - doc.page.margins.right;

  doc.moveDown(0.6);
  const label = status === 'revoked' ? t.statusRevoked : t.statusSuperseded;
  const tone =
    status === 'revoked'
      ? { fill: '#FEF2F2', border: '#DC2626', text: '#991B1B' }
      : { fill: '#FFFBEB', border: '#D97706', text: '#92400E' };

  let detail = '';
  if (status === 'superseded' && passport.supersededBy) {
    // An em dash, not `→`. U+2192 is outside WinAnsi, so Helvetica has no
    // glyph for it and the arrow itself printed as mojibake — caught by the
    // unrenderable check the moment it existed, and invisible to the
    // string-table coverage test because it lives in a template literal here
    // rather than in `STRINGS`.
    detail = ` — ${passport.supersededBy}`;
  } else if (status === 'revoked' && passport.revocationReason) {
    detail = ` — ${passport.revocationReason}`;
  }

  const text = `${t.status}: ${label}${detail}`;
  const inner = width - 20;
  const height = heightOfFlow(doc, body, text, inner, { size: 10.5, bold: true }) + 16;
  const top = doc.y;

  doc.roundedRect(left, top, width, height, 4).fillAndStroke(tone.fill, tone.border);
  writeFlow(doc, body, text, left + 10, top + 8, inner, {
    size: 10.5,
    bold: true,
    color: tone.text,
  });
  doc.y = top + height + 4;
}

/** The headline figures: collected, declared, rate, target. */
function drawHeadline({ doc, t, f, body, locale }) {
  const left = doc.page.margins.left;
  const width = doc.page.width - left - doc.page.margins.right;

  doc.moveDown(0.8);

  const top = doc.y;
  const boxHeight = 104;
  doc.roundedRect(left, top, width, boxHeight, 6).fillAndStroke('#F0FDFA', '#99F6E4');

  const innerY = top + 12;
  const colWidth = width / 2 - 22;
  const leftX = left + 14;
  const rightX = left + width / 2 + 6;

  writeFlow(doc, body, t.collected, leftX, innerY, colWidth, {
    size: 9,
    color: '#0F766E',
  });
  writeFlow(
    doc,
    body,
    `${formatKg(f.collectedMassMg, locale)} ${t.kg}`,
    leftX,
    doc.y + 2,
    colWidth,
    { size: 19, bold: true, color: '#0F172A' },
  );

  writeFlow(doc, body, t.declared, leftX, innerY + 48, colWidth, {
    size: 9,
    color: '#0F766E',
  });
  writeFlow(
    doc,
    body,
    f.declaredMassMg === null ? '—' : `${formatKg(f.declaredMassMg, locale)} ${t.kg}`,
    leftX,
    doc.y + 2,
    colWidth,
    { size: 15, bold: true, color: f.declaredMassMg === null ? '#94A3B8' : '#0F172A' },
  );

  // The percentage, or the sentence saying why there is not one.
  //
  // EPR-24, and the whole point of the phase: "the collection percentage
  // appears only because a declaration was filed". A blank, a dash or a 0%
  // would each read as a figure. The absence has to say what is missing and who
  // can fix it.
  writeFlow(doc, body, t.rate, rightX, innerY, colWidth, {
    size: 9,
    color: '#0F766E',
  });

  if (f.collectionRate === null) {
    writeFlow(doc, body, absentRateSentence(t, f), rightX, doc.y + 2, colWidth, {
      size: 9,
      color: '#B45309',
    });

    // The applicable target is a fact about the producer's OBLIGATION, not
    // about whether it filed. Drawing it only alongside a rate meant a
    // certificate for an unfiled period silently omitted the threshold the
    // producer is held to — while `figures.applicableCollectionTarget` was
    // populated, hashed, and printed on every other certificate.
    if (f.applicableCollectionTarget !== null
        && f.applicableCollectionTarget !== undefined) {
      writeFlow(doc, body, t.target, rightX, innerY + 58, colWidth, {
        size: 9,
        color: '#0F766E',
      });
      writeFlow(
        doc,
        body,
        formatPercent(f.applicableCollectionTarget, locale)
          + (f.obligationYear
            ? ` (${t.obligationYear} ${localeNumber(f.obligationYear, locale)})`
            : ''),
        rightX,
        doc.y + 1,
        { size: 9.5, color: '#0F172A' },
      );
    }
  } else {
    writeFlow(doc, body, formatPercent(f.collectionRate, locale), rightX, doc.y + 2, colWidth, {
      size: 19,
      bold: true,
      color: '#0F172A',
    });

    writeFlow(doc, body, t.target, rightX, innerY + 52, colWidth, {
      size: 9,
      color: '#0F766E',
    });
    const targetText =
      f.applicableCollectionTarget === null
        ? t.noTarget
        : formatPercent(f.applicableCollectionTarget, locale)
          + (f.obligationYear
            ? ` (${t.obligationYear} ${localeNumber(f.obligationYear, locale)})`
            : '');
    writeFlow(doc, body, targetText, rightX, doc.y + 1, colWidth, {
      size: 9.5,
      color: f.applicableCollectionTarget === null ? '#94A3B8' : '#0F172A',
    });
  }

  doc.y = top + boxHeight;
}

/**
 * The sentence that stands in for a missing percentage.
 *
 * Reads the figures rather than assuming, because a NIL declaration — which
 * `declarations.js` explicitly permits — also produces a null rate. Printing
 * "no put-on-market declaration has been filed for this period" on a
 * certificate that ALSO prints the declared figure and the attester's name is
 * a document contradicting itself, and the half that is false is the half
 * about the producer's paperwork.
 */
function absentRateSentence(t, f) {
  if (f.declaredMassMg === 0 || f.declarationVersion) return t.noRateNilDeclared;
  return t.noRate;
}

function drawCategoryTable(ctx) {
  const { doc, t, f, body, locale } = ctx;
  const left = doc.page.margins.left;
  const width = doc.page.width - left - doc.page.margins.right;

  doc.moveDown(1);
  sectionHeading(ctx, t.byCategory);

  const cols = [width * 0.44, width * 0.28, width * 0.28];
  tableHeader(ctx, [t.category, t.collectedCol, t.declaredCol], cols, left);

  for (const category of passports.GAZETTE_CATEGORIES) {
    const collected = f.collectedMassMgByCategory?.[category] ?? 0;
    const declaredMap = f.declaredMassMgByCategory;
    const declared = declaredMap ? declaredMap[category] : undefined;

    // Nothing collected and nothing declared: the row would carry no
    // information, and five empty rows make the real ones harder to read.
    if (!collected && !Number.isInteger(declared)) continue;

    tableRow(
      ctx,
      [
        CATEGORY_NAMES[locale][category] ?? category,
        `${formatKg(collected, locale)} ${t.kg}`,
        // An undeclared category is not zero (EPR-42). Said in words rather
        // than with a dash, because a dash in a mass column reads as nil.
        Number.isInteger(declared)
          ? `${formatKg(declared, locale)} ${t.kg}`
          : t.notDeclared,
      ],
      cols,
      left,
      { mutedIndexes: Number.isInteger(declared) ? [] : [2] },
    );
  }
}

function drawPolymerTable(ctx) {
  const { doc, t, f, body, locale } = ctx;
  const entries = Object.entries(f.massMgByPolymer ?? {})
    .filter(([, mg]) => Number.isFinite(mg) && mg > 0)
    .sort((a, b) => b[1] - a[1]);

  if (entries.length === 0) return;

  const left = doc.page.margins.left;
  const width = doc.page.width - left - doc.page.margins.right;

  doc.moveDown(1);
  sectionHeading(ctx, t.byPolymer);

  const cols = [width * 0.6, width * 0.4];
  for (const [polymer, mg] of entries) {
    tableRow(
      ctx,
      [POLYMER_NAMES[locale][polymer] ?? polymer, `${formatKg(mg, locale)} ${t.kg}`],
      cols,
      left,
    );
  }
}

function drawEvidence(ctx) {
  const { doc, t, f, locale } = ctx;

  doc.moveDown(1);
  sectionHeading(ctx, t.evidence);

  const rows = [
    [t.attributions, localeNumber(f.attributionCount, locale)],
    [t.disposals, localeNumber(f.disposalCount, locale)],
    [t.uniqueSkus, localeNumber(f.uniqueSkuCount, locale)],
    // EPR-25: the estimated share is stated on the artefact, not buried.
    [t.estimatedShare, formatPercent(f.estimatedShare ?? 0, locale)],
  ];

  if (f.reversedCount > 0) {
    rows.push([t.reversed, localeNumber(f.reversedCount, locale)]);
  }

  if (f.declarationAttestedByName) {
    rows.push([t.attestedBy, f.declarationAttestedByName]);
  }

  // The carbon line, or the reason there is not one (EPR-38, EPR-39).
  if (f.carbonKgCo2eAvoided !== null && f.carbonKgCo2eAvoided !== undefined) {
    rows.push([
      t.carbon,
      // The localised unit, like every other mass on the page. Hardcoding `kg`
      // printed an English unit on the Bangla edition beside Bengali numerals.
      `${localeNumber(Math.round(f.carbonKgCo2eAvoided), locale)} ${t.kg} CO2e`,
    ]);
    rows.push([t.carbonFactor, f.carbonFactorVersion ?? '—']);
  } else {
    rows.push([
      t.carbon,
      f.carbonAbsenceReason === 'tooUncertain' ? t.noCarbonUncertain : t.noCarbon,
    ]);
  }

  for (const [label, value] of rows) {
    labelled(ctx, label, value);
  }
}

function drawBoundaries(ctx) {
  const { doc, t, body, locale } = ctx;
  const left = doc.page.margins.left;
  const width = doc.page.width - left - doc.page.margins.right;
  const statements = BOUNDARIES[locale];
  const inner = width - 24;

  // Measured before the page-break decision, so the block is never split with
  // one statement orphaned on a following page — a boundary statement a reader
  // can miss is a boundary statement that has not been made.
  let needed = 34;
  for (const statement of statements) {
    needed += heightOfFlow(doc, body, `•  ${statement}`, inner, { size: 8.5 }) + 5;
  }

  if (doc.y + needed > doc.page.height - doc.page.margins.bottom) {
    doc.addPage();
  }

  doc.moveDown(1);
  sectionHeading(ctx, t.boundaries);

  const top = doc.y;
  for (const statement of statements) {
    writeFlow(doc, body, `•  ${statement}`, left + 12, doc.y, inner, {
      size: 8.5,
      color: '#475569',
    });
    doc.moveDown(0.35);
  }

  doc
    .moveTo(left + 3, top - 2)
    .lineTo(left + 3, doc.y)
    .lineWidth(2)
    .strokeColor('#CBD5E1')
    .stroke();
}

function drawVerification(ctx) {
  const { doc, t, body, locale, passport, verifyBaseUrl } = ctx;
  const left = doc.page.margins.left;
  const width = doc.page.width - left - doc.page.margins.right;

  const boxHeight = 100;
  if (doc.y + boxHeight + 26 > doc.page.height - doc.page.margins.bottom) {
    doc.addPage();
  }

  doc.moveDown(1);
  const top = doc.y;
  doc.roundedRect(left, top, width, boxHeight, 6).fillAndStroke('#F8FAFC', '#E2E8F0');

  const inner = width - 28;
  const innerX = left + 14;

  writeFlow(doc, body, t.verifyTitle, innerX, top + 12, inner, {
    size: 10,
    bold: true,
    color: '#0F172A',
  });

  const url = `${trimSlash(verifyBaseUrl)}/passports/verify/${passport.serial}`;
  writeFlow(doc, body, `${t.verifyBody}:`, innerX, doc.y + 2, inner, {
    size: 9,
    color: '#475569',
  });
  doc
    .font('Courier')
    .fontSize(8.5)
    .fillColor('#0369A1')
    .text(url, innerX, doc.y + 1, { width: inner, link: url, underline: false });

  // The hash, in Courier and broken across two lines: 64 hex characters at a
  // readable size do not fit one A4 line, and a hash the reader cannot
  // transcribe cannot be checked.
  writeFlow(doc, body, t.contentHash, innerX, doc.y + 5, inner, {
    size: 8,
    color: '#64748B',
  });
  doc
    .font('Courier')
    .fontSize(8)
    .fillColor('#334155')
    .text(
      `${passport.contentHash.slice(0, 32)}\n${passport.contentHash.slice(32)}`,
      innerX,
      doc.y + 1,
      { width: inner, lineGap: 1 },
    );

  doc.y = top + boxHeight;

  const issued = toDate(passport.issuedAt);
  const footer =
    `${t.issuedAt}: ${issued ? formatDateTime(issued, locale) : '—'}`
    + (passport.issuedByName ? `  ·  ${t.issuedBy}: ${passport.issuedByName}` : '');
  writeFlow(doc, body, footer, left, doc.y + 8, width, {
    size: 8,
    color: '#94A3B8',
  });
}

/**
 * Page numbers, written last across every page.
 *
 * A multi-page certificate whose pages are not numbered is a certificate from
 * which a page can be removed without trace — and the boundary statements are
 * exactly the page somebody would want to remove. The serial is on every page
 * for the same reason: it ties a loose sheet back to the certificate it came
 * from.
 */
function drawPageNumbers({ doc, t, body, locale, passport }) {
  const range = doc.bufferedPageRange();
  const total = range.count;

  for (let i = 0; i < total; i += 1) {
    doc.switchToPage(range.start + i);
    const left = doc.page.margins.left;
    const width = doc.page.width - left - doc.page.margins.right;
    const y = doc.page.height - doc.page.margins.bottom + 22;

    const pageText =
      `${t.page} ${localeNumber(i + 1, locale)} ${t.of} ${localeNumber(total, locale)}`;

    // The serial is Latin and the page count may be Bengali, so this line is
    // measured and placed rather than aligned.
    doc.font('Courier').fontSize(7.5);
    const serialWidth = doc.widthOfString(passport.serial);
    const sep = '  ·  ';
    doc.font(body.latin).fontSize(7.5);
    const sepWidth = doc.widthOfString(sep);
    const pageWidth = splitRuns(body, pageText).reduce((sum, run) => {
      doc.font(faceFor(body, run, false)).fontSize(7.5);
      return sum + doc.widthOfString(run.text);
    }, 0);

    let cursor = left + (width - (serialWidth + sepWidth + pageWidth)) / 2;

    doc
      .font('Courier')
      .fontSize(7.5)
      .fillColor('#94A3B8')
      .text(passport.serial, cursor, y, { lineBreak: false });
    cursor += serialWidth;

    doc.font(body.latin).fontSize(7.5).text(sep, cursor, y, { lineBreak: false });
    cursor += sepWidth;

    writeLine(doc, body, pageText, cursor, y, pageWidth, {
      size: 7.5,
      color: '#94A3B8',
    });
  }
}

// ---------------------------------------------------------------------------
// Drawing helpers
// ---------------------------------------------------------------------------

function sectionHeading({ doc, body }, text) {
  const left = doc.page.margins.left;
  const width = doc.page.width - left - doc.page.margins.right;
  writeFlow(doc, body, text, left, doc.y, width, {
    size: 11,
    bold: true,
    color: '#0F172A',
  });
  doc.moveDown(0.3);
}

/**
 * A label and its value, side by side.
 *
 * The value is the field most likely to be mixed-script — a producer's legal
 * name, a DoE reference, an emission factor version — so it flows through the
 * composing writer.
 */
function labelled({ doc, body }, label, value) {
  const left = doc.page.margins.left;
  const width = doc.page.width - left - doc.page.margins.right;
  const labelWidth = width * 0.46;

  const y = doc.y;
  writeFlow(doc, body, label, left, y, labelWidth - 8, {
    size: 9,
    color: '#64748B',
  });
  const labelBottom = doc.y;

  writeFlow(doc, body, String(value), left + labelWidth, y, width - labelWidth, {
    size: 9.5,
    color: '#1E2937',
  });

  doc.y = Math.max(labelBottom, doc.y) + 2;
}

function tableHeader({ doc, body }, cells, cols, left) {
  const y = doc.y;
  let x = left;
  cells.forEach((cell, i) => {
    writeLine(doc, body, cell, x, y, cols[i] - 8, {
      size: 8.5,
      bold: true,
      color: '#64748B',
      align: i === 0 ? 'left' : 'right',
    });
    x += cols[i];
  });
  doc.y = y + 14;
  doc
    .moveTo(left, doc.y - 4)
    .lineTo(left + cols.reduce((a, b) => a + b, 0), doc.y - 4)
    .lineWidth(0.6)
    .strokeColor('#E2E8F0')
    .stroke();
}

function tableRow({ doc, body }, cells, cols, left, { mutedIndexes = [] } = {}) {
  const y = doc.y;
  let x = left;
  let bottom = y;

  cells.forEach((cell, i) => {
    writeLine(doc, body, String(cell), x, y, cols[i] - 8, {
      size: 9.5,
      color: mutedIndexes.includes(i) ? '#94A3B8' : '#1E2937',
      align: i === 0 ? 'left' : 'right',
    });
    bottom = Math.max(bottom, doc.y);
    x += cols[i];
  });

  doc.y = bottom + 4;
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

/**
 * Milligrams to a kilogram string, rounded exactly once, here (EPR-20).
 *
 * Three significant figures, matching `mass_math.dart`'s `formatKilograms`, so
 * a figure on the certificate and the same figure on the producer's dashboard
 * read identically. Rounding happens at display and nowhere earlier: every
 * stored figure is an exact integer milligram.
 */
function formatKg(mg, locale) {
  const kg = intOr0(mg) / MG_PER_KILOGRAM;
  const text = kg === 0 ? '0' : significantFigures(kg, 3);
  return locale === 'bn' ? toBengaliDigits(text) : text;
}

/**
 * Rounds to significant figures — the leading digits too, not just the
 * decimals.
 *
 * This must agree with `roundToSignificantFigures` in `mass_math.dart`,
 * because the certificate and the producer's dashboard show the same stored
 * milligrams and a reader who saw `5060 kg` on one and `5061 kg` on the other
 * would have no way to tell which was wrong. An earlier version here clamped
 * the decimal places and never touched the integer digits, so every figure of
 * four digits or more silently disagreed with the client.
 */
function significantFigures(value, digits) {
  if (!Number.isFinite(value) || value === 0 || digits < 1) return '0';

  const exponent = Math.floor(Math.log10(Math.abs(value)));
  const scale = 10 ** (digits - 1 - exponent);
  const rounded = Math.round(value * scale) / scale;

  const decimals = Math.max(0, Math.min(digits - 1 - exponent, 10));
  const fixed = rounded.toFixed(decimals);
  // Trailing zeros after a decimal point overstate precision.
  return decimals > 0 ? fixed.replace(/\.?0+$/, '') : fixed;
}

/**
 * A fraction as a percentage, always to one decimal place.
 *
 * One decimal, unconditionally, matching `CompliancePosition.percentLabel` on
 * the client. Dropping it above 10% — which this did at first — turns 29.94%
 * into "30%", and 30% is exactly the gazette threshold: the certificate would
 * state a producer had met a target the evidence does not support. A tenth of a
 * percentage point is the difference between compliant and not.
 */
function formatPercent(fraction, locale) {
  const text = `${((fraction ?? 0) * 100).toFixed(1)}%`;
  return locale === 'bn' ? toBengaliDigits(text) : text;
}

function localeNumber(value, locale) {
  const text = String(intOr0(value));
  return locale === 'bn' ? toBengaliDigits(text) : text;
}

function toBengaliDigits(text) {
  return String(text).replace(/[0-9]/g, (d) => BENGALI_DIGITS[Number(d)]);
}

/** `2026-09` to "September 2026" or "সেপ্টেম্বর ২০২৬". */
function formatPeriod(periodId, locale) {
  const match = /^(\d{4})-(\d{2})$/.exec(String(periodId ?? ''));
  if (!match) return String(periodId ?? '—');
  const year = match[1];
  const monthIndex = Number(match[2]) - 1;
  if (monthIndex < 0 || monthIndex > 11) return String(periodId);

  return locale === 'bn'
    ? `${BENGALI_MONTHS[monthIndex]} ${toBengaliDigits(year)}`
    : `${ENGLISH_MONTHS[monthIndex]} ${year}`;
}

/**
 * A timestamp in Asia/Dhaka.
 *
 * Fixed +6, as everywhere else in the EPR module: `toLocaleString` with a time
 * zone depends on the host's ICU data, and a certificate whose date shifts with
 * the server's build is not reproducible.
 */
function formatDateTime(date, locale) {
  const dhaka = new Date(date.getTime() + 6 * 60 * 60 * 1000);
  const day = String(dhaka.getUTCDate());
  const month = dhaka.getUTCMonth();
  const year = String(dhaka.getUTCFullYear());
  const hh = String(dhaka.getUTCHours()).padStart(2, '0');
  const mm = String(dhaka.getUTCMinutes()).padStart(2, '0');

  return locale === 'bn'
    ? `${toBengaliDigits(day)} ${BENGALI_MONTHS[month]} ${toBengaliDigits(year)}, `
      + `${toBengaliDigits(hh)}:${toBengaliDigits(mm)} (ঢাকা)`
    : `${day} ${ENGLISH_MONTHS[month]} ${year}, ${hh}:${mm} (Dhaka)`;
}

function toDate(value) {
  if (!value) return null;
  if (value instanceof Date) return value;
  if (typeof value.toDate === 'function') return value.toDate();
  if (typeof value === 'string') {
    const parsed = new Date(value);
    return Number.isNaN(parsed.getTime()) ? null : parsed;
  }
  return null;
}

function trimSlash(url) {
  return String(url || 'https://chokro.app').replace(/\/+$/, '');
}

function intOr0(value) {
  return Number.isFinite(value) && value > 0 ? Math.round(value) : 0;
}

module.exports = {
  LOCALES,
  STRINGS,
  BOUNDARIES,
  CATEGORY_NAMES,
  POLYMER_NAMES,
  SIZE_CLASS_NAMES,
  BENGALI_FONT,
  BENGALI_FONT_BOLD,
  bengaliFontAvailable,
  splitRuns,
  registerFonts,
  normaliseForRender,
  isInvisible,
  helveticaCovers,
  renderPassportPdf,
  formatKg,
  formatPercent,
  formatPeriod,
  formatDateTime,
  toBengaliDigits,
  significantFigures,
};
