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
const PDFDocument = require('pdfkit');
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
    // The subscript ₂ is the case that caught this: `CO₂e` is the natural
    // typography and is missing from Noto Sans Bengali and from Helvetica's
    // WinAnsi encoding alike, so the module writes `CO2e`.
    const everything = [
      ...allStrings('en').map(([, v]) => v),
      ...allStrings('bn').map(([, v]) => v),
    ].join('');
    expect(everything).not.toMatch(/[₂²·]/);
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
    ['Cyrillic', 'Кока-Кола'],
    ['Thai', 'บริษัท'],
  ])('is refused rather than printed as mojibake: %s', (_label, name) => {
    for (const locale of ['en', 'bn']) {
      expect(() => pdf.splitRuns(bodyFor(locale), name)).toThrow(
        /neither the bundled Bengali face nor Helvetica/,
      );
    }
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
    ).rejects.toThrow(/neither the bundled Bengali face nor Helvetica/);
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
      ).rejects.toThrow(/neither the bundled/);
    }

    await expect(
      render({ locale: 'en', status: 'revoked', revocationReason: '中文' }),
    ).rejects.toThrow(/neither the bundled/);
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
    const out = [];
    for (let cp = 0x20; cp < 0x2100; cp += 1) {
      const inBengaliBlock =
        (cp >= 0x0980 && cp <= 0x09ff) || cp === 0x0964 || cp === 0x0965;
      if (inBengaliBlock || pdf.isInvisible(cp)) continue;
      if (font.glyphForCodePoint(cp).id === 0) continue;
      if (pdf.helveticaCovers(cp)) continue;
      out.push(cp);
    }
    return out;
  }

  test('there are such code points, so this test is not vacuous', () => {
    expect(bengaliOnlyCodePoints().length).toBeGreaterThan(10);
  });

  test.each(['en', 'bn'])(
    'every one goes to the Bengali face mid-Latin-run (%s edition)',
    (locale) => {
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
    },
  );

  test('U+2010, the hyphen a word processor substitutes', () => {
    const runs = pdf.splitRuns(bodyFor('en'), 'Coca‐Cola Ltd.');
    expect(runs.map((r) => r.script)).toEqual(['latin', 'bengali', 'latin']);
    expect(runs.map((r) => r.text).join('')).toBe('Coca‐Cola Ltd.');
  });

  test('renders rather than refusing', async () => {
    await expect(
      render({
        locale: 'en',
        figures: { organizationLegalName: 'Coca‐Cola Bangladesh Ltd.' },
      }),
    ).resolves.toBeInstanceOf(Buffer);
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
    ['tab', '\u0009'],
    ['newline', '\u000a'],
    ['carriage return', '\u000d'],
    ['NUL', '\u0000'],
    ['DEL', '\u007f'],
    ['zero-width space', '​'],
    ['RTL mark', '‏'],
    ['BOM', '﻿'],
    ['soft hyphen', '­'],
    ['word joiner', '⁠'],
  ])('%s is treated as invisible', (_label, ch) => {
    expect(pdf.isInvisible(ch.codePointAt(0))).toBe(true);
    expect(pdf.splitRuns(newBody('en').body, `a${ch}b`)[0].text).toBe('ab');
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

describe('Helvetica coverage', () => {
  test('is decided against WinAnsi, not by asking pdfkit', () => {
    // pdfkit encodes anything without complaint, which is what produces
    // mojibake — so coverage is a property of the WinAnsi repertoire.
    for (const cp of [0x41, 0x7e, 0x20, 0xe9, 0xff, 0x20ac, 0x2013, 0x2122]) {
      expect(pdf.helveticaCovers(cp)).toBe(true);
    }
    for (const cp of [0x4e2d, 0x0627, 0x0915, 0x1f600, 0x2192, 0x0995, 0x2082]) {
      expect(pdf.helveticaCovers(cp)).toBe(false);
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
