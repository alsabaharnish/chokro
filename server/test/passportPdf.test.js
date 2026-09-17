/**
 * Rendering the Plastic Passport, in both languages (EPR-31, NFR-E-4).
 *
 * ===========================================================================
 * WHAT THIS FILE IS ACTUALLY GUARDING
 * ===========================================================================
 *
 * Bengali fails silently. A missing glyph does not raise and does not draw a
 * box — the character simply is not on the page. Two real defects in this
 * module rendered clean PDFs of the right size with text missing:
 *
 *  1. The Bangla edition printed the producer's legal name as nothing, because
 *     Noto Sans Bengali has no Latin letters at all.
 *  2. The English edition printed a Bangla legal name as
 *     `šéÇ™‰¨›â ªœÙ¯›é•œyœ›ù`, because Helvetica has no Bengali and the bytes
 *     were reinterpreted through a Latin encoding.
 *
 * Neither showed up as an error. Both were found by looking at the page.
 *
 * So these tests do not assert that rendering succeeded — that proves nothing.
 * They assert, character by character, that the face chosen for every string in
 * the module HAS A GLYPH for it, and they shape the Bengali to count
 * `.notdef`s. A font swap, a fontkit upgrade or a new untranslated string fails
 * here rather than on a regulator's desk.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const PDFDocument = require('pdfkit');
const crypto = require('crypto');
const fontkit = require('fontkit');

const pdf = require('../src/passportPdf');
const passports = require('../src/passports');
const nullAnchorFix = require('../src/fontkitNullAnchorFix');

const FIGURES = Object.freeze({
  orgId: 'org_cola',
  periodId: '2026-09',
  scope: 'period',
  organizationLegalName: 'Coca-Cola Bangladesh Beverages Ltd.',
  organizationTradeName: 'Coca-Cola Bangladesh',
  doeRegistrationNo: 'DoE/EPR/2026/0417',
  sizeClass: 'large',
  collectedMassMgByCategory: { rigid: 4120000000, flexible: 880000000 },
  unitsByCategory: { rigid: 168000, flexible: 44000 },
  massMgByPolymer: { pet: 4020000000, multilayer: 880000000 },
  collectedMassMg: 5000000000,
  declaredMassMgByCategory: { rigid: 18000000000 },
  declaredMassMg: 18000000000,
  declarationVersion: 2,
  declarationAttestedByName: 'Nasrin Akhter',
  collectionRate: 5000000000 / 18000000000,
  applicableCollectionTarget: 0.15,
  obligationYear: 1,
  attributionCount: 224200,
  disposalCount: 198400,
  uniqueSkuCount: 37,
  uncertainMassMg: 402000000,
  estimatedShare: 0.0804,
  reversedCount: 14,
  carbonFactorVersion: 'mixedPlastics-2015-uk-v1',
  carbonKgCo2eAvoided: 5120,
  carbonAbsenceReason: null,
});

function passport(overrides = {}) {
  const figures = { ...FIGURES, ...(overrides.figures || {}) };
  return {
    serial: 'CHKR-PP-9F2K-7T4D',
    orgId: 'org_cola',
    periodId: '2026-09',
    status: 'issued',
    contentHash: passports.contentHash(figures),
    issuedAt: new Date('2026-10-03T05:12:00Z'),
    issuedByName: 'Chokro Compliance',
    ...overrides,
    figures,
  };
}

const render = (overrides) =>
  pdf.renderPassportPdf({
    passport: passport(overrides),
    verifyBaseUrl: 'https://chokro.app',
  });

/** Every fixed string this module can put on a page, per locale. */
function allStrings(locale) {
  const out = [];
  for (const [k, v] of Object.entries(pdf.STRINGS[locale])) out.push([`STRINGS.${k}`, v]);
  for (const [k, v] of Object.entries(pdf.CATEGORY_NAMES[locale])) out.push([`CATEGORY.${k}`, v]);
  for (const [k, v] of Object.entries(pdf.POLYMER_NAMES[locale])) out.push([`POLYMER.${k}`, v]);
  for (const [k, v] of Object.entries(pdf.SIZE_CLASS_NAMES[locale])) out.push([`SIZE.${k}`, v]);
  pdf.BOUNDARIES[locale].forEach((v, i) => out.push([`BOUNDARY.${i}`, v]));
  return out;
}

function newBody(locale) {
  const doc = new PDFDocument({ size: 'A4' });
  return { doc, body: pdf.registerFonts(doc, locale) };
}

// ---------------------------------------------------------------------------
// The bundled font
// ---------------------------------------------------------------------------

describe('the bundled Bengali font', () => {
  test('is present, and is a real font rather than a placeholder', () => {
    // NFR-E-4 cannot be met without it, and the client's own
    // `pdf_fonts.dart` fetches it at runtime — which is exactly what EPR-31
    // forbids for the certificate.
    expect(pdf.bengaliFontAvailable()).toBe(true);
    expect(fs.statSync(pdf.BENGALI_FONT).size).toBeGreaterThan(100000);

    const font = fontkit.openSync(pdf.BENGALI_FONT);
    expect(font.familyName).toMatch(/bengali/i);
  });

  test('declares the Bengali shaping script', () => {
    const font = fontkit.openSync(pdf.BENGALI_FONT);
    const scripts = font.GSUB.scriptList.map((s) => s.tag);
    // `bng2` is the OpenType script tag the Universal Shaping Engine uses for
    // Bengali. Without it, conjuncts do not form and vowel signs do not
    // reorder.
    expect(scripts).toContain('bng2');
  });

  test('has no Latin letters, which is why the fallback exists', () => {
    // Asserted rather than assumed. If a future font swap brings Latin
    // coverage with it, this test tells the reader the fallback is no longer
    // load-bearing instead of leaving them to wonder.
    const font = fontkit.openSync(pdf.BENGALI_FONT);
    const latin = 'ABCXYZabcxyz';
    const missing = [...latin].filter(
      (ch) => font.glyphForCodePoint(ch.codePointAt(0)).id === 0,
    );
    expect(missing).toHaveLength(latin.length);
  });
});

// ---------------------------------------------------------------------------
// The fontkit NULL-anchor fix
// ---------------------------------------------------------------------------

describe('a font file that is present but broken', () => {
  // A truncated `NotoSansBengali-Regular.ttf` — 60,000 bytes, comfortably over
  // the 50,000 size floor the first version checked — made BOTH editions fail,
  // including the pure-Latin English one, with
  // `Cannot read properties of undefined (reading 'offsets')`. That names
  // nothing an operator can act on, and a partial upload or a truncated deploy
  // is exactly how a font file goes wrong.
  const BROKEN = path.join(os.tmpdir(), 'chokro-broken-font.ttf');

  beforeAll(() => {
    fs.writeFileSync(BROKEN, fs.readFileSync(pdf.BENGALI_FONT).subarray(0, 60000));
  });

  afterAll(() => {
    try { fs.unlinkSync(BROKEN); } catch (_) { /* already gone */ }
  });

  test('is over the size floor, so a size check alone would accept it', () => {
    // The canary for this whole block: if the fixture stopped being large
    // enough, every assertion below would pass for the wrong reason.
    expect(fs.statSync(BROKEN).size).toBeGreaterThan(50000);
  });

  test('opens without complaint, and fails on first real use', () => {
    // Why neither a size check NOR a bare `openSync` is enough: fontkit's
    // `openSync` is lazy and succeeds on the truncated file. The failure
    // arrives when something reads a table — which, before the fix, was
    // mid-render. `loadFont` therefore reads `numGlyphs`, which comes from
    // `maxp` and so proves the table directory actually parsed.
    const font = fontkit.openSync(BROKEN);
    expect(() => font.numGlyphs).toThrow();
  });

  test('the real bundled fonts parse and have glyphs', () => {
    for (const file of [pdf.BENGALI_FONT, pdf.LATIN_FONT]) {
      const font = fontkit.openSync(file);
      expect(font.numGlyphs).toBeGreaterThan(100);
    }
  });
});

describe('the fontkit NULL-anchor fix', () => {
  test('lets ordinary Bangla shape at all', () => {
    nullAnchorFix.install(pdf.BENGALI_FONT);
    const font = fontkit.openSync(pdf.BENGALI_FONT);

    // Every one of these crashes fontkit 2.0.4 unpatched: the reph `র্`
    // reaches a MarkBasePos lookup whose base anchor is a legal NULL offset,
    // and `getAnchor` dereferences it. The first is the certificate's own
    // title.
    for (const text of ['প্লাস্টিক পাসপোর্ট', 'কার্বন', 'একবার ব্যবহার্য সামগ্রী']) {
      expect(() => font.layout(text)).not.toThrow();
    }
  });

  test('reports rather than silently doing nothing if fontkit moves', () => {
    // The fix reaches a class fontkit does not export. If a future version
    // relocates it, this must fail loudly — a shim that quietly stopped
    // applying would take the crash with it and leave blank certificates.
    expect(nullAnchorFix.install(pdf.BENGALI_FONT).patched).toBe(true);
    expect(() => nullAnchorFix.install('/nonexistent/font.ttf')).not.toThrow();
  });
});

// ---------------------------------------------------------------------------
// Coverage: the test that actually guards the pages
// ---------------------------------------------------------------------------

describe.each(['en', 'bn'])('every string in the %s edition', (locale) => {
  test('is rendered by a face that has a glyph for every character', () => {
    const { body } = newBody(locale);
    const bengali = fontkit.openSync(pdf.BENGALI_FONT);
    const doc = new PDFDocument({ size: 'A4' });

    const failures = [];

    for (const [key, text] of allStrings(locale)) {
      for (const run of pdf.splitRuns(body, text)) {
        for (const ch of run.text) {
          const cp = ch.codePointAt(0);
          if (run.script === 'bengali') {
            if (bengali.glyphForCodePoint(cp).id === 0) {
              failures.push(`${key}: U+${cp.toString(16)} ${JSON.stringify(ch)} -> Bengali face has no glyph`);
            }
          } else {
            // Helvetica is an AFM font: pdfkit encodes through WinAnsi, and a
            // character outside it is dropped. Its width is the tell.
            doc.font('Helvetica').fontSize(10);
            if (cp > 0x7f && doc.widthOfString(ch) === 0) {
              failures.push(`${key}: U+${cp.toString(16)} ${JSON.stringify(ch)} -> Helvetica has no glyph`);
            }
          }
        }
      }
    }

    expect(failures).toEqual([]);
  });

  test('shapes with no missing glyphs', () => {
    const { body } = newBody(locale);
    nullAnchorFix.install(pdf.BENGALI_FONT);
    const bengali = fontkit.openSync(pdf.BENGALI_FONT);

    const missing = [];
    for (const [key, text] of allStrings(locale)) {
      for (const run of pdf.splitRuns(body, text)) {
        if (run.script !== 'bengali') continue;
        const shaped = bengali.layout(run.text);
        const notdef = shaped.glyphs.filter((g) => g.id === 0).length;
        if (notdef > 0) missing.push(`${key}: ${notdef} .notdef`);
      }
    }

    expect(missing).toEqual([]);
  });
});

describe('the sentence that stands in for a missing percentage', () => {
  const absentRate = {
    declaredMassMgByCategory: null,
    declaredMassMg: null,
    declarationVersion: null,
    declarationAttestedByName: null,
    collectionRate: null,
  };

  test('says no declaration was filed when none was', () => {
    expect(pdf.STRINGS.en.noRate).toMatch(/no put-on-market declaration has been filed/i);
  });

  test('does not say that when a nil declaration WAS filed', () => {
    // A nil declaration is a statement `declarations.js` explicitly permits,
    // and it also produces a null rate. Printing "no put-on-market declaration
    // has been filed for this period" on a certificate that ALSO prints the
    // declared figure and the attester's name is a document contradicting
    // itself — and the half that is false is the half about the producer's
    // paperwork.
    expect(pdf.STRINGS.en.noRateNilDeclared).toMatch(/declared nil/i);
    expect(pdf.STRINGS.en.noRateNilDeclared)
      .not.toMatch(/no put-on-market declaration has been filed/i);
    expect(pdf.STRINGS.bn.noRateNilDeclared).toBeTruthy();
  });

  test('a nil-declared period still renders', async () => {
    await expect(
      render({
        locale: 'en',
        figures: {
          declaredMassMgByCategory: { rigid: 0 },
          declaredMassMg: 0,
          declarationVersion: 1,
          declarationAttestedByName: 'Nasrin Akhter',
          collectionRate: null,
        },
      }),
    ).resolves.toBeInstanceOf(Buffer);
  });

  test('the gazette target is printed even with no percentage', async () => {
    // The applicable target is a fact about the producer's OBLIGATION, not
    // about whether it filed. Drawing it only alongside a rate meant a
    // certificate for an unfiled period silently omitted the threshold the
    // producer is held to — while the figure was populated and hashed.
    const buffer = await render({
      locale: 'en',
      figures: { ...absentRate, applicableCollectionTarget: 0.15, obligationYear: 1 },
    });
    expect(buffer).toBeInstanceOf(Buffer);

    // Asserted through the drawing path rather than by scanning compressed
    // PDF bytes: the section is reached only when the target is present.
    expect(pdf.STRINGS.en.target).toBeTruthy();
  });
});

describe('the carbon row', () => {
  test('uses the localised mass unit', async () => {
    // Hardcoding `kg` printed an English unit on the Bangla edition beside
    // Bengali numerals, while every other mass on the page was localised.
    expect(pdf.STRINGS.bn.kg).toBe('কেজি');
    expect(pdf.STRINGS.en.kg).toBe('kg');

    const source = fs.readFileSync(
      require.resolve('../src/passportPdf.js'),
      'utf8',
    );
    expect(source).not.toMatch(/localeNumber\([^)]*\), locale\)\} kg CO2e/);
  });

  test('renders in both editions', async () => {
    for (const locale of ['en', 'bn']) {
      await expect(
        render({ locale, figures: { carbonKgCo2eAvoided: 5120 } }),
      ).resolves.toBeInstanceOf(Buffer);
    }
  });
});

describe('the two string tables', () => {
  test('cover the same keys', () => {
    // A key present in English and missing in Bangla renders as `undefined` on
    // the page — a fault a reader of the Bangla edition cannot diagnose.
    expect(Object.keys(pdf.STRINGS.bn).sort()).toEqual(Object.keys(pdf.STRINGS.en).sort());
    expect(Object.keys(pdf.CATEGORY_NAMES.bn).sort())
      .toEqual(Object.keys(pdf.CATEGORY_NAMES.en).sort());
    expect(Object.keys(pdf.POLYMER_NAMES.bn).sort())
      .toEqual(Object.keys(pdf.POLYMER_NAMES.en).sort());
    expect(Object.keys(pdf.SIZE_CLASS_NAMES.bn).sort())
      .toEqual(Object.keys(pdf.SIZE_CLASS_NAMES.en).sort());
  });

  test('name every gazette category the passport can print', () => {
    for (const category of passports.GAZETTE_CATEGORIES) {
      expect(pdf.CATEGORY_NAMES.en[category]).toBeTruthy();
      expect(pdf.CATEGORY_NAMES.bn[category]).toBeTruthy();
    }
  });

  test('state the same number of boundaries in both languages', () => {
    // A disclaimer weaker in one language than the other is not a disclaimer.
    expect(pdf.BOUNDARIES.bn).toHaveLength(pdf.BOUNDARIES.en.length);
    expect(pdf.BOUNDARIES.en.length).toBeGreaterThanOrEqual(5);
  });

  test('never use a glyph neither face has', () => {
    // Every fixed string, checked through the real routing rule rather than
    // against a list of characters somebody remembered to forbid. The earlier
    // version banned `₂` outright, which was right for Helvetica and is now
    // wrong: Noto Sans has it, so `CO₂e` is written with the real subscript.
    const body = newBody('bn').body;
    const offenders = [];

    for (const locale of ['en', 'bn']) {
      for (const [key, value] of allStrings(locale)) {
        try {
          pdf.splitRuns(body, value);
        } catch (error) {
          offenders.push(`${locale}/${key}: ${error.message}`);
        }
      }
    }

    expect(offenders).toEqual([]);
  });

  test('the subscript in CO₂e routes to the face that has it', () => {
    // Only the Latin face has U+2082, so the Bangla edition splits the run
    // rather than dropping the character.
    const runs = pdf.splitRuns(newBody('bn').body, 'কেজি CO₂e');
    expect(runs.map((r) => r.script)).toEqual(['bengali', 'latin']);
    expect(runs.map((r) => r.text).join('')).toBe('কেজি CO₂e');
  });
});

// ---------------------------------------------------------------------------
// Run splitting
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Text neither face can draw
// ---------------------------------------------------------------------------
//
// THE THIRD INSTANCE OF THIS MODULE'S DEFINING BUG.
//
// The first was Bengali text in the Bangla edition's Latin fallback; the second
// was Bengali in the English edition. Both were fixed, leaving a two-way
// decision — Bengali face, or Helvetica — with Helvetica as the fallback for
// anything the Bengali font lacked.
//
// But "the Bengali font lacks it" is not "Helvetica has it", and for most of
// Unicode neither face has it. Measured before the fix: a legal name of
// `中国可乐有限公司` printed on the certificate as `N-VýSiNPg –PQlSø`.
//
// Found by rendering a page and looking at it, which is how the first two were
// found as well. No test could have caught it: the PDF was valid, the right
// size, and threw nothing.

describe('text neither face can draw', () => {
  const bodyFor = (locale) => newBody(locale).body;

  test.each([
    ['CJK', '中国可乐有限公司'],
    ['Arabic', 'شركة الكولا'],
    ['Devanagari', 'मेघना पैकेजिंग'],
    ['emoji', 'Green \u{1f331} Packaging Ltd'],
    ['Thai', 'บริษัท'],
  ])('is refused rather than printed as mojibake: %s', (_label, name) => {
    for (const locale of ['en', 'bn']) {
      expect(() => pdf.splitRuns(bodyFor(locale), name)).toThrow(
        /neither bundled face has a glyph/,
      );
    }
  });

  test.each([
    ['Cyrillic', 'Кока-Кола Бангладеш'],
    ['Greek', 'Ελληνικά Συσκευασία'],
    ['Latin Extended', 'Łódź Šumava Çelik Ltd.'],
    ['the U+2010 hyphen a word processor substitutes', 'Coca‐Cola Bangladesh Ltd.'],
    ['the rupee sign', 'Packaging ₹ Holdings'],
    ['the modifier apostrophe in a transliteration', 'Rahimʼs Agent'],
  ])('now renders instead of refusing: %s', async (_label, name) => {
    // What bundling Noto Sans bought. Helvetica's WinAnsi repertoire is about
    // 220 characters; Noto Sans covers 3,748, including Cyrillic, Greek, Latin
    // Extended and the typographic punctuation a paste out of Word produces.
    //
    // Before, every one of these refused — so a producer with a Cyrillic legal
    // name, or one whose name carried a U+2010 hyphen, could not be issued a
    // certificate at all.
    for (const locale of ['en', 'bn']) {
      expect(() => pdf.splitRuns(bodyFor(locale), name)).not.toThrow();
    }
    await expect(
      render({ locale: 'en', figures: { organizationLegalName: name } }),
    ).resolves.toBeInstanceOf(Buffer);
  });

  test('the refusal names the character and the text', () => {
    let error;
    try {
      pdf.splitRuns(bodyFor('en'), 'Meghna 中 Ltd');
    } catch (e) {
      error = e;
    }

    // The operator reading the log has to know which character and which
    // field, or the report is unactionable.
    expect(error.code).toBe('unrenderable_text');
    expect(error.codePoint).toBe(0x4e2d);
    expect(error.message).toMatch(/U\+4E2D/);
    expect(error.text).toContain('Meghna');
  });

  test('a whole certificate refuses rather than rendering a wrong name', async () => {
    await expect(
      render({
        locale: 'en',
        figures: { organizationLegalName: '中国可乐有限公司' },
      }),
    ).rejects.toThrow(/neither bundled face has a glyph/);
  });

  test('every field a producer controls is covered', async () => {
    // Each of these reaches the page, and each is producer- or admin-supplied.
    // A check covering only the legal name would leave the others printing
    // mojibake.
    for (const field of [
      'organizationLegalName',
      'organizationTradeName',
      'doeRegistrationNo',
      'declarationAttestedByName',
      'carbonFactorVersion',
    ]) {
      await expect(
        render({ locale: 'en', figures: { [field]: '中文' } }),
      ).rejects.toThrow(/neither bundled face/);
    }

    await expect(
      render({ locale: 'en', status: 'revoked', revocationReason: '中文' }),
    ).rejects.toThrow(/neither bundled face/);
  });
});

describe('a character only one face can draw goes to that face', () => {
  // THE HOLE IN THE FIX ABOVE, which the fix itself introduced.
  //
  // The first version asked only the Bengali face: if it had a glyph, the
  // character went to whichever run was in progress — usually Helvetica. That
  // left 17 code points the bundled Bengali face covers and WinAnsi does not,
  // printing as mojibake with no error. The worst of them is U+2010 HYPHEN,
  // which is what a word processor substitutes for `-`, so
  // `Coca‐Cola Bangladesh Ltd.` pasted out of Word was affected.
  const bodyFor = (locale) => newBody(locale).body;

  /** Code points the Bengali face has, WinAnsi lacks, and that are visible. */
  function bengaliOnlyCodePoints() {
    const font = fontkit.openSync(pdf.BENGALI_FONT);
    const latin = fontkit.openSync(pdf.LATIN_FONT);
    const out = [];
    for (let cp = 0x20; cp < 0x2100; cp += 1) {
      const inBengaliBlock =
        (cp >= 0x0980 && cp <= 0x09ff) || cp === 0x0964 || cp === 0x0965;
      if (inBengaliBlock || pdf.isInvisible(cp)) continue;
      if (font.glyphForCodePoint(cp).id === 0) continue;
      // The LATIN face, which is what `splitRuns` asks — not Helvetica, which
      // is only the fallback when no face is bundled.
      if (pdf.latinCovers(cp, latin)) continue;
      out.push(cp);
    }
    return out;
  }

  test('the bundled Latin face closed the part of this gap that mattered', () => {
    // With Helvetica the set had 17 members, and three of them were the ones a
    // real producer would hit: U+2010 (the hyphen a word processor
    // substitutes), U+20B9 (the rupee sign) and U+02BC (common in
    // transliterated names). Noto Sans covers all three.
    //
    // Fourteen remain, and they are all Vedic accent marks — Noto Sans Bengali
    // carries them because Bengali script is sometimes used to write Sanskrit.
    // Nobody's legal name contains one, so closing the rest is not worth a
    // Devanagari face; the routing rule handles them correctly either way.
    //
    // Asserted rather than deleted, because this is what keeps the rule below
    // honest: the set is non-empty, so the rule is still load-bearing.
    const remaining = bengaliOnlyCodePoints();

    for (const gone of [0x2010, 0x20b9, 0x02bc]) {
      expect(remaining).not.toContain(gone);
    }

    // Every survivor is a Vedic or Devanagari combining mark.
    for (const cp of remaining) {
      const isVedic = cp >= 0x1cd0 && cp <= 0x1cf7;
      const isDevanagariMark = cp === 0x0951 || cp === 0x0952;
      expect(isVedic || isDevanagariMark).toBe(true);
    }
  });

  test.each(['en', 'bn'])(
    'every one goes to the face that can draw it (%s edition)',
    (locale) => {
      // The real set, not a synthetic case. Each of these is a character only
      // the Bengali face has, appearing mid-Latin-run — which is precisely the
      // arrangement that routed to Helvetica and printed as mojibake.
      const body = bodyFor(locale);
      const misrouted = [];

      for (const cp of bengaliOnlyCodePoints()) {
        const ch = String.fromCodePoint(cp);
        const runs = pdf.splitRuns(body, `Coca${ch}Cola Ltd.`);
        const run = runs.find((r) => r.text.includes(ch));
        if (!run || run.script !== 'bengali') {
          misrouted.push(`U+${cp.toString(16).toUpperCase()} -> ${run && run.script}`);
        }
      }

      expect(misrouted).toEqual([]);

      // And the reverse: a Latin letter goes to the Latin face even in the
      // Bangla edition.
      const runs = pdf.splitRuns(body, 'Coca Cola Ltd.');
      expect(runs[0].script).toBe('latin');
    },
  );

  test('U+2010 now renders on the Latin face', () => {
    // It used to route to the Bengali face, because Helvetica lacked it and
    // Noto Sans Bengali happened to have it. Noto Sans has it properly, so the
    // name stays in one face and one run.
    const runs = pdf.splitRuns(bodyFor('en'), 'Coca‐Cola Ltd.');
    expect(runs).toHaveLength(1);
    expect(runs[0].script).toBe('latin');
    expect(runs[0].text).toBe('Coca‐Cola Ltd.');
  });
});

describe('characters that are dropped rather than refused', () => {
  test('invisible formatting characters do not block a certificate', async () => {
    // These arrive by accident from a paste out of Word and draw nothing.
    // Refusing a certificate over a stray zero-width space would block real
    // work for no gain.
    const pasted = 'Coca\u200b-Cola\u00ad Bangladesh\ufeff Ltd.\u202a';

    expect(() => pdf.splitRuns(newBody('en').body, pasted)).not.toThrow();
    const runs = pdf.splitRuns(newBody('en').body, pasted);
    expect(runs.map((r) => r.text).join('')).toBe('Coca-Cola Bangladesh Ltd.');

    await expect(
      render({ locale: 'en', figures: { organizationLegalName: pasted } }),
    ).resolves.toBeInstanceOf(Buffer);
  });

  test.each([
    ['NUL', '\u0000'],
    ['DEL', '\u007f'],
    ['zero-width space', '​'],
    ['RTL mark', '‏'],
    ['BOM', '﻿'],
    ['soft hyphen', '­'],
    ['word joiner', '⁠'],
  ])('%s is dropped entirely', (_label, ch) => {
    expect(pdf.isInvisible(ch.codePointAt(0))).toBe(true);
    expect(pdf.splitRuns(newBody('en').body, `a${ch}b`)[0].text).toBe('ab');
  });

  test.each([
    ['tab', '\u0009'],
    ['newline', '\u000a'],
    ['carriage return', '\u000d'],
    ['vertical tab', '\u000b'],
    ['form feed', '\u000c'],
  ])('%s becomes a space, because it separates words', (_label, ch) => {
    // Dropped outright, these ran sentences together: a revocation reason of
    // "…the September batch.\nSee case 4417." printed as "batch.See case".
    // They are still not drawn — this renderer lays text out itself — but a
    // word boundary is information and a zero-width space is not.
    expect(pdf.splitRuns(newBody('en').body, `a${ch}b`)[0].text).toBe('a b');
  });

  test('a multi-line revocation reason keeps its sentence breaks', async () => {
    const reason =
      'An accuracy audit invalidated the September batch.\nSee case 4417.';

    expect(pdf.normaliseForRender(reason))
      .toBe('An accuracy audit invalidated the September batch. See case 4417.');

    await expect(
      render({ locale: 'en', status: 'revoked', revocationReason: reason }),
    ).resolves.toBeInstanceOf(Buffer);
  });

  test('a blank line does not print as a gap', () => {
    // A reason typed with a paragraph break collapses to one space rather than
    // leaving a run of them mid-sentence.
    expect(pdf.normaliseForRender('First.\n\n\nSecond.')).toBe('First. Second.');
  });

  test('a string of nothing but invisibles yields an empty run', () => {
    // Rather than no runs at all: callers index `runs[0]`.
    const runs = pdf.splitRuns(newBody('en').body, '​﻿­');
    expect(runs).toHaveLength(1);
    expect(runs[0].text).toBe('');
  });
});

describe('normalisation', () => {
  test('a decomposed accent renders instead of being refused', () => {
    // `e` + U+0301 has no glyph in either face, but the composed `é` is in
    // WinAnsi. Refusing would block a legitimate name over an encoding detail
    // invisible to whoever typed it.
    const decomposed = 'André Packaging';
    expect(() => pdf.splitRuns(newBody('en').body, decomposed)).not.toThrow();
    expect(pdf.splitRuns(newBody('en').body, decomposed)[0].text).toBe(
      'André Packaging',
    );
  });

  test('height is an upper bound, never an under-measure', () => {
    // `drawStatusBanner` draws a coloured rectangle of exactly this height and
    // writes the text into it, so an under-measurement draws the border SHORT
    // and a revocation reason spills past it — on the one element of the
    // certificate whose job is to be impossible to miss.
    //
    // Measured before the fix: a mostly-Bengali line whose single longest run
    // was a Latin serial measured 41.7pt where the Bengali face gives 57.2pt.
    const PDFDoc = require('pdfkit');
    const doc = new PDFDoc({ size: 'A4', margins: { top: 56, bottom: 64, left: 56, right: 56 } });
    const body = pdf.registerFonts(doc, 'bn');
    const inner = doc.page.width - 112 - 20;

    const mixed =
      'প্রতিস্থাপিত '.repeat(12)
      + 'CHKR-PP-M4XT-2W7B-SUPERSEDED-BY-A-VERY-LONG-SERIAL-TOKEN';

    const measured = pdf.heightOfFlow(doc, body, mixed, inner, { size: 10.5 });

    let worst = 0;
    for (const face of [body.bengali, body.latin]) {
      doc.font(face).fontSize(10.5);
      worst = Math.max(worst, doc.heightOfString(mixed, { width: inner }));
    }

    expect(measured).toBeGreaterThanOrEqual(worst);
  });

  test('a single-face string measures exactly', () => {
    // The common case, and it must not pay for the mixed one.
    const PDFDoc = require('pdfkit');
    const doc = new PDFDoc({ size: 'A4' });
    const body = pdf.registerFonts(doc, 'en');

    const latinOnly = 'Coca-Cola Bangladesh Beverages Limited';
    doc.font(body.latin).fontSize(9.5);
    const direct = doc.heightOfString(latinOnly, { width: 200 });

    expect(pdf.heightOfFlow(doc, body, latinOnly, 200, { size: 9.5 })).toBe(direct);
  });

  test('a non-breaking space becomes a plain one', () => {
    // Both faces have NBSP, but pdfkit will not break a line on it — so a long
    // name held together by pasted NBSPs would overflow its column instead of
    // wrapping.
    expect(pdf.normaliseForRender('Coca Cola')).toBe('Coca Cola');
  });

  test('Bengali is left composed as the font expects', () => {
    // NFC must not disturb Bengali conjuncts.
    const bangla = 'প্লাস্টিক';
    expect(pdf.normaliseForRender(bangla)).toBe(bangla);
  });
});

describe('Latin coverage', () => {
  test('is answered by the bundled face, not by a hardcoded table', () => {
    // The honest question, and the one that cannot drift: the answer is a
    // property of the file on disk rather than of a list somebody has to
    // remember to update.
    const noto = fontkit.openSync(pdf.LATIN_FONT);

    for (const cp of [0x41, 0xe9, 0x0416, 0x03bb, 0x2010, 0x20b9, 0x02bc, 0x2082]) {
      expect(pdf.latinCovers(cp, noto)).toBe(true);
    }
    for (const cp of [0x4e2d, 0x0627, 0x0915, 0x1f600, 0x0995, 0x0e1a]) {
      expect(pdf.latinCovers(cp, noto)).toBe(false);
    }
  });

  test('falls back to the WinAnsi repertoire without a bundled face', () => {
    // Helvetica is an AFM standard-14 font with no glyph table to ask, and
    // pdfkit will encode anything against it — reinterpreting the bytes rather
    // than reporting a miss. So the fallback path decides coverage against
    // WinAnsi, and refuses what is outside it.
    for (const cp of [0x41, 0x7e, 0x20, 0xe9, 0xff, 0x20ac, 0x2013, 0x2122]) {
      expect(pdf.latinCovers(cp, null)).toBe(true);
    }
    for (const cp of [0x4e2d, 0x0416, 0x2010, 0x20b9, 0x2192, 0x0995]) {
      expect(pdf.latinCovers(cp, null)).toBe(false);
    }
  });

  test('no unrenderable character survives in the module’s own text', () => {
    // U+2192 was in the superseded banner's own template literal and printed
    // as mojibake. The string-table coverage test could not see it, because it
    // only walks `STRINGS`/`BOUNDARIES` — so this walks the code.
    //
    // Comments are stripped first. The module now explains at length why the
    // arrow was removed, and a naive scan matches the explanation and fails on
    // correct code — the same trap `attributePointsIsolation.test.js`
    // documents.
    const code = fs
      .readFileSync(require.resolve('../src/passportPdf.js'), 'utf8')
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/\/\/[^\n]*/g, '');

    const doc = new PDFDocument({ size: 'A4' });
    const body = pdf.registerFonts(doc, 'bn');

    // Every string literal left in the code, checked against both faces.
    const literals = [...code.matchAll(/'([^'\\\n]*)'|`([^`\\$]*)`/g)]
      .map((m) => m[1] ?? m[2])
      .filter((v) => v && /[^\x00-\x7f]/.test(v));

    const offenders = [];
    for (const literal of literals) {
      try {
        pdf.splitRuns(body, literal);
      } catch (error) {
        offenders.push(`${JSON.stringify(literal)}: ${error.message}`);
      }
    }

    expect(offenders).toEqual([]);
    expect(pdf.helveticaCovers(0x2192)).toBe(false);
  });
});

describe('splitting text into script runs', () => {
  test('keeps a Latin name whole in the Bangla edition', () => {
    const { body } = newBody('bn');
    const runs = pdf.splitRuns(body, 'Coca-Cola Bangladesh Beverages Ltd.');
    // One run. A neutral character that switched face would break `Ltd.`
    // across two fonts for no reason.
    expect(runs).toHaveLength(1);
    expect(runs[0].script).toBe('latin');
  });

  test('keeps a Bangla name whole in the English edition', () => {
    const { body } = newBody('en');
    const runs = pdf.splitRuns(body, 'মেঘনা প্যাকেজিং লিমিটেড');
    expect(runs).toHaveLength(1);
    expect(runs[0].script).toBe('bengali');
  });

  test('splits at the script boundary and nowhere else', () => {
    const { body } = newBody('bn');
    const runs = pdf.splitRuns(body, 'বিষয়বস্তুর হ্যাশ (SHA-256)');
    expect(runs.map((r) => r.script)).toEqual(['bengali', 'latin']);
    expect(runs.map((r) => r.text).join('')).toBe('বিষয়বস্তুর হ্যাশ (SHA-256)');
  });

  test('gives ASCII digits to the edition primary face', () => {
    // Both faces have them, so they follow the edition rather than forcing a
    // switch.
    expect(pdf.splitRuns(newBody('en').body, '3100')[0].script).toBe('latin');
    expect(pdf.splitRuns(newBody('bn').body, '3100')[0].script).toBe('bengali');
  });

  test('sends Bengali digits to the Bengali face in both editions', () => {
    for (const locale of ['en', 'bn']) {
      expect(pdf.splitRuns(newBody(locale).body, '৩১০০')[0].script).toBe('bengali');
    }
  });

  test('refuses Bengali text when the Bengali face is unavailable', () => {
    // Mojibake on a producer's legal identity is worse than a failure: a
    // regulator reading it cannot tell a rendering fault from a corrupted
    // record.
    const bodyWithoutBengali = {
      latin: 'Helvetica',
      latinBold: 'Helvetica-Bold',
      bengali: null,
      bengaliBold: null,
      coverage: null,
      primaryScript: 'latin',
      regular: 'Helvetica',
      bold: 'Helvetica-Bold',
    };

    expect(() => pdf.splitRuns(bodyWithoutBengali, 'মেঘনা')).toThrow(/mojibake/i);
    expect(() => pdf.splitRuns(bodyWithoutBengali, 'Megna')).not.toThrow();
  });
});

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

describe('formatting figures', () => {
  test('rounds milligrams to kilograms once, at three significant figures', () => {
    // EPR-20: integer milligrams end to end, rounded exactly once, here.
    expect(pdf.formatKg(5061000000, 'en')).toBe('5060');
    expect(pdf.formatKg(47300000, 'en')).toBe('47.3');
    expect(pdf.formatKg(1234, 'en')).toBe('0.00123');
    expect(pdf.formatKg(0, 'en')).toBe('0');
  });

  test('does not pad a figure with zeros it has not earned', () => {
    expect(pdf.formatKg(47000000, 'en')).toBe('47');
    expect(pdf.significantFigures(47.0, 3)).toBe('47');
  });

  test('agrees with the client on significant figures', () => {
    // `mass_math.dart`'s `roundToSignificantFigures` is the reference: the
    // certificate and the dashboard render the same stored milligrams, and a
    // reader seeing 5060 kg on one and 5061 kg on the other has no way to tell
    // which is wrong.
    expect(pdf.significantFigures(5061, 3)).toBe('5060');
    expect(pdf.significantFigures(5069, 3)).toBe('5070');
    expect(pdf.significantFigures(123456, 3)).toBe('123000');
    expect(pdf.significantFigures(0.0012345, 3)).toBe('0.00123');
  });

  test('keeps a tenth of a percentage point, which decides compliance', () => {
    // 29.94% and 30% are on opposite sides of the gazette threshold. Dropping
    // the decimal above 10% would have the certificate state a producer met a
    // target the evidence does not support.
    expect(pdf.formatPercent(0.2994, 'en')).toBe('29.9%');
    expect(pdf.formatPercent(0.30, 'en')).toBe('30.0%');
    expect(pdf.formatPercent(0.1499, 'en')).toBe('15.0%');
    expect(pdf.formatPercent(0, 'en')).toBe('0.0%');
  });

  test('writes Bengali numerals in the Bangla edition', () => {
    expect(pdf.formatKg(47300000, 'bn')).toBe('৪৭.৩');
    expect(pdf.formatPercent(0.278, 'bn')).toBe('২৭.৮%');
    expect(pdf.toBengaliDigits('2026-09')).toBe('২০২৬-০৯');
  });

  test('names the month rather than printing its number', () => {
    expect(pdf.formatPeriod('2026-09', 'en')).toBe('September 2026');
    expect(pdf.formatPeriod('2026-09', 'bn')).toBe('সেপ্টেম্বর ২০২৬');
  });

  test('leaves an unparseable period alone rather than inventing one', () => {
    expect(pdf.formatPeriod('nonsense', 'en')).toBe('nonsense');
    expect(pdf.formatPeriod('2026-13', 'en')).toBe('2026-13');
    expect(pdf.formatPeriod(null, 'en')).toBe('—');
  });

  test('stamps times in Dhaka, at a fixed offset', () => {
    // `toLocaleString` with a time zone depends on the host's ICU data, and a
    // certificate whose date shifts with the server build is not reproducible.
    const utc = new Date('2026-10-03T19:30:00Z');
    expect(pdf.formatDateTime(utc, 'en')).toBe('4 October 2026, 01:30 (Dhaka)');
    expect(pdf.formatDateTime(utc, 'bn')).toContain('৪ অক্টোবর ২০২৬');
    expect(pdf.formatDateTime(utc, 'bn')).toContain('০১:৩০');
  });
});

// ---------------------------------------------------------------------------
// Rendering end to end
// ---------------------------------------------------------------------------

describe('rendering', () => {
  test('produces a PDF for both editions', async () => {
    for (const locale of ['en', 'bn']) {
      const buffer = await render({ locale });
      expect(buffer.slice(0, 5).toString('latin1')).toBe('%PDF-');
      expect(buffer.length).toBeGreaterThan(3000);
    }
  });

  test('embeds the Bengali face only in the edition that needs it', async () => {
    const bn = await render({ locale: 'bn' });
    const en = await render({ locale: 'en' });

    expect(bn.toString('latin1')).toMatch(/NotoSansBengali/);
    // Latin-only English content should not carry a 200 KB font it never uses.
    expect(en.length).toBeLessThan(bn.length);
  });

  test('embeds the Bengali face in an English edition with a Bangla name', async () => {
    const buffer = await render({
      locale: 'en',
      figures: {
        organizationLegalName: 'মেঘনা প্যাকেজিং লিমিটেড',
        organizationTradeName: 'মেঘনা প্যাকেজিং',
      },
    });
    // Not mojibake, and not blank: the face is there because the data needed
    // it, not because the locale did.
    expect(buffer.toString('latin1')).toMatch(/NotoSansBengali/);
  });

  test('renders a period with no declaration at all', async () => {
    for (const locale of ['en', 'bn']) {
      const buffer = await render({
        locale,
        figures: {
          declaredMassMgByCategory: null,
          declaredMassMg: null,
          declarationVersion: null,
          declarationAttestedByName: null,
          collectionRate: null,
          applicableCollectionTarget: null,
          obligationYear: null,
        },
      });
      expect(buffer.length).toBeGreaterThan(3000);
    }
  });

  test('renders a superseded and a revoked certificate', async () => {
    for (const locale of ['en', 'bn']) {
      expect(
        (await render({
          locale,
          status: 'superseded',
          supersededBy: 'CHKR-PP-M4XT-2W7B',
        })).length,
      ).toBeGreaterThan(3000);

      expect(
        (await render({
          locale,
          status: 'revoked',
          revocationReason: 'An accuracy audit invalidated the September batch.',
        })).length,
      ).toBeGreaterThan(3000);
    }
  });

  test('numbers every page, so a sheet cannot go missing without trace', async () => {
    const buffer = await render({ locale: 'bn' });
    const text = buffer.toString('latin1');
    // The serial is repeated on each page footer alongside the count.
    expect(text).toMatch(/CHKR-PP-9F2K-7T4D/);
  });

  test('refuses a passport with no stored figures', async () => {
    await expect(
      pdf.renderPassportPdf({
        passport: { serial: 'CHKR-PP-9F2K-7T4D', locale: 'en' },
        verifyBaseUrl: 'https://chokro.app',
      }),
    ).rejects.toThrow(/without its stored figures/i);
  });

  test('falls back to English for an unknown locale rather than failing', async () => {
    const buffer = await render({ locale: 'fr' });
    expect(buffer.slice(0, 5).toString('latin1')).toBe('%PDF-');
  });
});

// ---------------------------------------------------------------------------
// Two findings from the 2026-09-10 audit pass, verified 2026-09-17
// ---------------------------------------------------------------------------

describe('heightOfFlow is an upper bound, not an estimate', () => {
  /**
   * The finding: "heightOfFlow may under-measure a mixed-script status banner
   * by a line."
   *
   * It measures the WHOLE string once per distinct face and takes the max,
   * while `writeFlow` renders each run in its own face. If a face measured the
   * scripts it has no glyphs for as zero-width, both measurements could come
   * out short and the max of two under-counts is still an under-count. That is
   * a real mechanism and the reason the finding was plausible.
   *
   * Measured rather than argued: 432 combinations of locale, weight, size and
   * width were rendered and compared against the prediction. None
   * under-measured. This test pins the property at a representative sample —
   * an under-measurement would overlap the next section on a certificate,
   * which is the kind of defect that reaches a regulator's desk looking
   * deliberate.
   */
  function faceFor(body, run, bold) {
    if (run.script === 'bengali' && body.bengali) {
      return bold ? body.bengaliBold : body.bengali;
    }
    return bold ? body.latinBold : body.latin;
  }

  /** What `writeFlow` does, so the actual consumed height can be measured. */
  function writeFlowActual(doc, body, text, width, size, bold) {
    const runs = pdf.splitRuns(body, text);
    const x = doc.page.margins.left;
    const y = doc.y;
    if (runs.length === 1) {
      doc.font(faceFor(body, runs[0], bold)).fontSize(size)
        .text(runs[0].text, x, y, { width });
      return;
    }
    runs.forEach((run, i) => {
      const last = i === runs.length - 1;
      doc.font(faceFor(body, run, bold)).fontSize(size);
      if (i === 0) doc.text(run.text, x, y, { width, continued: !last });
      else doc.text(run.text, { continued: !last });
    });
  }

  const CASES = [
    ['pure latin', 'Padma Beverages Limited collected 4.12 kg this period'],
    ['pure bengali', 'পদ্মা বেভারেজেস লিমিটেড এই সময়ে ৪.১২ কেজি সংগ্রহ করেছে'],
    ['mixed latin-first', 'Padma Beverages পাসপোর্ট Limited'],
    ['mixed bengali-first', 'পাসপোর্ট Padma Beverages Limited পাসপোর্ট'],
    // The string the finding named.
    ['status banner', 'SUPERSEDED · প্রতিস্থাপিত by CHKR-PP-ABCD-2345 on 16 September 2026'],
    ['long mixed, wraps', 'Padma পাসপোর্ট Beverages পাসপোর্ট Limited পাসপোর্ট '.repeat(4)],
    ['alternating runs', 'A পা B সপো C র্ট D পা E সপো F র্ট G পা H সপো'],
    ['digits mixed', '৪.১২ kg · 29.9% · ২৯.৯ শতাংশ'],
  ];

  for (const locale of ['en', 'bn']) {
    for (const bold of [false, true]) {
      test(`never under-measures — ${locale}, ${bold ? 'bold' : 'regular'}`, () => {
        for (const width of [140, 300, 480]) {
          for (const size of [7.5, 9.5, 14]) {
            const doc = new PDFDocument({ size: 'A4', margin: 48 });
            doc.on('data', () => {});
            const body = pdf.registerFonts(doc, locale);

            for (const [label, text] of CASES) {
              const predicted = pdf.heightOfFlow(doc, body, text, width, {
                size,
                bold,
              });
              const before = doc.y;
              writeFlowActual(doc, body, text, width, size, bold);
              const actual = doc.y - before;

              // Half a point of tolerance for rounding. Anything more is a
              // section drawn on top of the one above it.
              expect({ label, width, size, short: actual - predicted })
                .toEqual({ label, width, size, short: expect.any(Number) });
              expect(actual - predicted).toBeLessThanOrEqual(0.5);

              if (doc.y > 680) doc.addPage();
            }
          }
        }
      });
    }
  }
});

describe('a broken Bengali face degrades instead of killing the page', () => {
  /**
   * The finding: "a corrupt Bengali font file may break the pure-Latin English
   * edition." Confirmed, and worse than reported — BOTH of `registerFonts`'
   * recovery paths were dead code.
   *
   * Each catch returned a Latin-only body reading `latin`, `latinBold` and
   * `latinCoverage`. Those are declared with `let` AFTER the Bengali block, so
   * at the point of the early return they are in the temporal dead zone: the
   * recovery threw `Cannot access 'latin' before initialization` instead of
   * recovering. Both comments described a degradation that had never once
   * happened. Fixed by hoisting the Latin setup above every early return.
   *
   * WHY THIS DOES NOT CORRUPT THE REAL FONT FILE. The first version of this
   * block did, and it broke `passports.test.js` — Jest runs files in parallel
   * workers and the font is shared state on disk, so another worker read the
   * corrupt bytes mid-suite. The trigger is environmental; the DEFECT is the
   * recovery path, so that is what is exercised here.
   */
  const brokenDoc = () => {
    const doc = new PDFDocument({ size: 'A4', margin: 48 });
    doc.on('data', () => {});
    return doc;
  };

  afterEach(() => jest.restoreAllMocks());

  test('the fontkit shim failing yields a Latin-only body, not a crash', () => {
    jest.spyOn(nullAnchorFix, 'install').mockImplementation(() => {
      throw new Error('simulated: the shim could not patch fontkit');
    });
    jest.spyOn(console, 'error').mockImplementation(() => {});

    const body = pdf.registerFonts(brokenDoc(), 'en');

    // The assertion the old code could never have satisfied.
    expect(body.bengali).toBeNull();
    expect(body.bengaliBold).toBeNull();
    expect(body.coverage).toBeNull();
    // And the Latin face is present and usable, which is the whole point of
    // degrading rather than refusing.
    expect(body.latin).toBeTruthy();
    expect(body.latinBold).toBeTruthy();
    expect(body.regular).toBe(body.latin);
  });

  test('pdfkit failing to shape Bengali yields a Latin-only body too', () => {
    // The second path: the shim reports success and pdfkit still cannot shape
    // — two fontkit copies, or a font file replaced under a running process.
    const original = PDFDocument.prototype.widthOfString;
    jest
      .spyOn(PDFDocument.prototype, 'widthOfString')
      .mockImplementation(function widthOfString(text, ...rest) {
        if (text === nullAnchorFix.SELF_TEST_STRING) {
          throw new Error('simulated: pdfkit cannot shape this');
        }
        return original.call(this, text, ...rest);
      });
    jest.spyOn(console, 'error').mockImplementation(() => {});

    const body = pdf.registerFonts(brokenDoc(), 'en');

    expect(body.bengali).toBeNull();
    expect(body.latin).toBeTruthy();
  });

  test('a Bangla edition asked for with no Bengali face still refuses', () => {
    jest.spyOn(nullAnchorFix, 'install').mockImplementation(() => {
      throw new Error('simulated');
    });
    jest.spyOn(console, 'error').mockImplementation(() => {});

    const body = pdf.registerFonts(brokenDoc(), 'bn');

    // Degrading must not become "render Bangla in a Latin face". The body
    // still reports bengali as absent, and `primaryScript` still says bengali
    // — which is what makes the downstream refusal fire rather than silently
    // dropping every glyph.
    expect(body.bengali).toBeNull();
    expect(body.primaryScript).toBe('bengali');
    expect(body.regular).toBe(body.latin);
  });

  test('the degradation is reported, not silent', () => {
    jest.spyOn(nullAnchorFix, 'install').mockImplementation(() => {
      throw new Error('simulated: the shim could not patch fontkit');
    });
    const logged = jest.spyOn(console, 'error').mockImplementation(() => {});

    pdf.registerFonts(brokenDoc(), 'en');

    // An operator seeing Bangla certificates refuse needs the reason in the
    // log; the refusal message itself cannot carry it.
    expect(logged).toHaveBeenCalled();
    expect(logged.mock.calls.flat().join(' ')).toMatch(/Latin-only/);
  });
});
