/* Temporary audit harness. Delete after use. */
const PDFDocument = require('pdfkit');
const pdf = require('./src/passportPdf');
const passports = require('./src/passports');

const events = [];
let pageSeq = 0;
const pageIdx = new WeakMap();

const origAddPage = PDFDocument.prototype.addPage;
PDFDocument.prototype.addPage = function (o) {
  const r = origAddPage.call(this, o);
  pageIdx.set(this.page, pageSeq);
  events.push({ kind: 'addPage', page: pageSeq });
  pageSeq += 1;
  return r;
};

const curPage = (d) => (d.page && pageIdx.has(d.page) ? pageIdx.get(d.page) : -1);

const origText = PDFDocument.prototype.text;
PDFDocument.prototype.text = function (text, x, y, options) {
  const beforePage = curPage(this);
  const bx = typeof x === 'number' ? x : this.x;
  const by = typeof y === 'number' ? y : this.y;
  const font = this._font && (this._font.name || this._font.filename || 'unknown');
  const size = this._fontSize;
  let w = 0;
  try { w = this.widthOfString(String(text)); } catch (e) { w = NaN; }
  const lh = this.currentLineHeight(true);
  const r = origText.call(this, text, x, y, options);
  events.push({
    kind: 'text', text: String(text), beforePage, afterPage: curPage(this),
    x: bx, y: by, yAfter: this.y, font, size, width: w, lineHeight: lh,
    opts: Object.assign({}, options || {}),
  });
  return r;
};

const origRR = PDFDocument.prototype.roundedRect;
PDFDocument.prototype.roundedRect = function (x, y, w, h, r) {
  events.push({ kind: 'rect', page: curPage(this), x, y, w, h });
  return origRR.call(this, x, y, w, h, r);
};

const FIGURES = {
  orgId: 'org_cola', periodId: '2026-09', scope: 'period',
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
  attributionCount: 224200, disposalCount: 198400, uniqueSkuCount: 37,
  uncertainMassMg: 402000000, estimatedShare: 0.0804, reversedCount: 14,
  carbonFactorVersion: 'mixedPlastics-2015-uk-v1',
  carbonKgCo2eAvoided: 5120, carbonAbsenceReason: null,
};

function mk(overrides) {
  overrides = overrides || {};
  const figures = Object.assign({}, FIGURES, overrides.figures || {});
  const base = {
    serial: 'CHKR-PP-9F2K-7T4D', orgId: 'org_cola', periodId: '2026-09',
    status: 'issued', contentHash: passports.contentHash(figures),
    issuedAt: new Date('2026-10-03T05:12:00Z'), issuedByName: 'Chokro Compliance',
  };
  return Object.assign(base, overrides, { figures });
}

const A4H = 841.89;
const A4W = 595.28;
const MB = 64;
const MR = 56;
const MAXY = A4H - MB;
const RIGHT = A4W - MR;

async function run(name, overrides, opts) {
  opts = opts || {};
  events.length = 0; pageSeq = 0;
  let buf;
  try {
    buf = await pdf.renderPassportPdf({
      passport: mk(overrides),
      verifyBaseUrl: opts.verifyBaseUrl || 'https://chokro.app',
    });
  } catch (e) {
    console.log('\n### ' + name + '\n  THREW: ' + String(e.message).slice(0, 300));
    return null;
  }
  console.log('\n### ' + name + '  (pages=' + pageSeq + ', bytes=' + buf.length + ')');
  for (const e of events) {
    if (e.kind === 'rect') {
      const bottom = e.y + e.h;
      const flag = bottom > MAXY ? '   <<< RECT BOTTOM PAST BOTTOM MARGIN' : '';
      console.log('  rect  p' + e.page + ' y=' + e.y.toFixed(1) + ' h=' + e.h.toFixed(1)
        + ' bottom=' + bottom.toFixed(1) + flag);
    } else if (e.kind === 'text') {
      const crossed = e.beforePage !== e.afterPage;
      const right = e.x + e.width;
      const off = e.opts.lineBreak === false && right > RIGHT + 0.5;
      if (crossed || off || opts.all) {
        console.log('  text  '
          + (crossed ? 'PAGE-BROKE ' : '')
          + (off ? 'OVERFLOWS-RIGHT ' : '')
          + 'p' + e.beforePage + '->p' + e.afterPage
          + ' y=' + e.y.toFixed(1) + ' yAfter=' + e.yAfter.toFixed(1)
          + ' x=' + e.x.toFixed(1) + ' w=' + e.width.toFixed(1)
          + ' right=' + right.toFixed(1)
          + ' sz=' + e.size + ' lb=' + e.opts.lineBreak
          + ' :: ' + JSON.stringify(e.text.slice(0, 60)));
      }
    }
  }
  return { pages: pageSeq, events: events.slice() };
}

module.exports = { run, mk, FIGURES, MAXY, RIGHT, A4H, A4W };

// ---- invariant checker -------------------------------------------------
function check(ev) {
  const bad = [];
  let lastRect = null;
  for (const e of ev) {
    if (e.kind === 'rect') { lastRect = e; continue; }
    if (e.kind !== 'text') continue;
    const bottom = e.y + e.lineHeight;
    if (e.opts.lineBreak === false && e.y < 790 && bottom > MAXY + 0.01) {
      bad.push('BELOW-BOTTOM-MARGIN(no-wrap) y=' + e.y.toFixed(1) + ' :: ' + JSON.stringify(e.text.slice(0, 40)));
    }
    if (e.y > A4H) {
      bad.push('OFF-PAGE y=' + e.y.toFixed(1) + ' :: ' + JSON.stringify(e.text.slice(0, 40)));
    }
    if (e.beforePage !== e.afterPage) {
      bad.push('PAGE-BROKE p' + e.beforePage + '->p' + e.afterPage + ' y=' + e.y.toFixed(1) + ' :: ' + JSON.stringify(e.text.slice(0, 40)));
    }
    if (e.opts.lineBreak === false && e.x + e.width > RIGHT + 0.5) {
      bad.push('OVER-RIGHT right=' + (e.x + e.width).toFixed(1) + ' :: ' + JSON.stringify(e.text.slice(0, 40)));
    }
    if (lastRect && lastRect.y + lastRect.h > MAXY + 0.01) {
      // report once
    }
  }
  for (const e of ev) {
    if (e.kind === 'rect' && e.y + e.h > MAXY + 0.01) {
      bad.push('RECT-PAST-MARGIN y=' + e.y.toFixed(1) + ' h=' + e.h.toFixed(1));
    }
  }
  return bad;
}
module.exports.check = check;

async function quiet(overrides, opts) {
  const log = console.log;
  console.log = () => {};
  let r;
  try { r = await run('q', overrides, opts); } finally { console.log = log; }
  return r;
}
module.exports.quiet = quiet;
