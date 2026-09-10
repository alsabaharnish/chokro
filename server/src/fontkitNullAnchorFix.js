/**
 * Chokro — a spec-conformance fix for fontkit's GPOS mark attachment.
 *
 * ===========================================================================
 * THE BUG
 * ===========================================================================
 *
 * `fontkit` 2.0.4 (the latest published version, and the one pdfkit 0.20.2
 * depends on) crashes while shaping ordinary Bangla:
 *
 *     font.layout('পাসপোর্ট')
 *     TypeError: Cannot read properties of null (reading 'xCoordinate')
 *         at GPOSProcessor.getAnchor (fontkit/dist/main.cjs:9989)
 *         at GPOSProcessor.applyAnchor (fontkit/dist/main.cjs:9979)
 *
 * `applyLookup` case 4 (MarkBasePos) reads
 *
 *     let baseAnchor = table.baseArray[baseIndex][markRecord.class];
 *     this.applyAnchor(markRecord, baseAnchor, baseGlyphIndex);
 *
 * and `getAnchor` then dereferences that anchor unconditionally. But the
 * OpenType specification says of `BaseRecord.baseAnchorOffsets`:
 *
 *     "Array of offsets (one per mark class) to Anchor tables. Offsets are
 *      from beginning of BaseArray table — NULL if no Anchor table."
 *
 * A NULL offset is legal and means *this base glyph has no attachment point
 * for that mark class*. The correct behaviour is to make no adjustment. The
 * same is true of `LigatureAttach` component anchors (case 5) and
 * `Mark2Record.mark2Anchors` (case 6).
 *
 * Noto Sans Bengali contains such NULL anchors, so any string whose shaping
 * reaches that lookup throws.
 *
 * Measured on the bundled font, with `applyAnchor` instrumented: `পাসপোর্ট`
 * and `কার্বন` each make ONE call, and every call has a NULL base anchor —
 * across both strings the counts are 2 NULL-base, 0 NULL-mark, and *zero*
 * non-NULL. (An earlier version of this comment said seven, which was a count
 * taken over a different set of strings. The number does not carry the
 * argument; the zero does.)
 *
 * That zero is the whole justification. This lookup contributes NOTHING to the
 * shaping of these strings even when it runs, so skipping the NULL calls is not
 * a degradation — it is what the font is asking for. If a future font produced
 * non-NULL anchors here, they would still be applied: the patch skips only the
 * NULL ones.
 *
 * ===========================================================================
 * WHY A RUNTIME PATCH AND NOT SOMETHING ELSE
 * ===========================================================================
 *
 * The options were:
 *
 *  - Upgrade fontkit. There is nothing to upgrade to: 2.0.4 is the latest
 *    published version.
 *  - `patch-package` and a postinstall hook. Equivalent in effect, but it adds
 *    a dependency and a build step, and a patch file in a diff explains itself
 *    far less well than this comment does.
 *  - Avoid the affected text. Not available — the affected text includes the
 *    word "passport" and the phrase "single-use items". A Bangla compliance
 *    certificate cannot route around its own title.
 *  - Drop server-side Bangla. This is the option EPR-31 forbids: a certificate
 *    the client renders is a certificate the client can alter.
 *
 * ===========================================================================
 * WHY THIS FAILS LOUDLY
 * ===========================================================================
 *
 * The patch reaches a class fontkit does not export, through
 * `font._layoutEngine.engine.GPOSProcessor`. That is internal structure, and a
 * future fontkit could move it.
 *
 * So `install()` VERIFIES that it patched something and throws if it did not,
 * and `server/test/passportPdf.test.js` shapes real Bangla and
 * asserts zero `.notdef` glyphs. A fontkit upgrade that breaks this shim fails
 * the test suite. It does not quietly produce certificates with missing text —
 * which, for a document whose whole purpose is to be trusted by a regulator, is
 * the only failure mode that actually matters.
 */

const fs = require('fs');
const fontkit = require('fontkit');

/** Set once the prototype has been patched, so `install` is idempotent. */
const PATCHED = Symbol.for('chokro.fontkit.nullAnchorPatched');

let state = null;

/**
 * Applies the fix. Idempotent. Returns a small report for logging and tests.
 *
 * `fontPath` is any TrueType/OpenType font — it is opened only to reach the
 * `GPOSProcessor` prototype, which is shared by every instance, so patching it
 * once patches all shaping for the life of the process.
 */
function install(fontPath) {
  if (state) return state;

  if (!fontPath || !fs.existsSync(fontPath)) {
    throw new Error(
      `Cannot install the fontkit NULL-anchor fix: no font at ${fontPath}.`,
    );
  }

  const font = fontkit.openSync(fontPath);

  // Any layout constructs the engine; a Latin string is enough and cannot
  // itself hit the bug.
  font.layout('a');

  const processor = font?._layoutEngine?.engine?.GPOSProcessor;
  if (!processor) {
    throw new Error(
      'Cannot install the fontkit NULL-anchor fix: fontkit no longer exposes '
        + 'a GPOSProcessor at font._layoutEngine.engine.GPOSProcessor. Its '
        + 'internals have changed — re-check whether the NULL base-anchor bug '
        + 'is still present before removing this shim.',
    );
  }

  const proto = Object.getPrototypeOf(processor);
  if (proto[PATCHED]) {
    state = { patched: true, alreadyPatched: true, skipped: () => 0 };
    return state;
  }

  if (typeof proto.applyAnchor !== 'function') {
    throw new Error(
      'Cannot install the fontkit NULL-anchor fix: GPOSProcessor has no '
        + 'applyAnchor method. Its internals have changed.',
    );
  }

  const original = proto.applyAnchor;
  let skipped = 0;

  proto.applyAnchor = function patchedApplyAnchor(
    markRecord,
    baseAnchor,
    baseGlyphIndex,
  ) {
    // A NULL anchor on either side means "no attachment point for this mark
    // class" (OpenType: BaseRecord.baseAnchorOffsets, LigatureAttach and
    // Mark2Record alike). No adjustment, and — importantly — no
    // `markAttachment` recorded either, because recording an attachment that
    // was never made would mislead the later mark-filtering passes.
    if (baseAnchor == null || markRecord == null || markRecord.markAnchor == null) {
      skipped += 1;
      return;
    }
    return original.call(this, markRecord, baseAnchor, baseGlyphIndex);
  };

  Object.defineProperty(proto, PATCHED, {
    value: true,
    enumerable: false,
    writable: false,
  });

  // ==========================================================================
  // A FUNCTIONAL SELF-TEST, NOT A STRUCTURAL ONE
  // ==========================================================================
  //
  // Everything above verifies that a method called `applyAnchor` exists on a
  // prototype this module can reach. That is not the same as verifying the
  // patch WORKS, and two ways it can be true while the patch does nothing:
  //
  //   A future fontkit keeps the name and changes where the class lives, or
  //   changes the signature so the anchors arrive in a different order. The
  //   guard then never fires, and the crash returns.
  //
  // So the install shapes a string that crashes unpatched and confirms it now
  // does not. It runs once per process.
  //
  // WHAT THIS DOES NOT CATCH, stated because a check that is trusted for more
  // than it does is worse than no check:
  //
  //   It probes the fontkit copy THIS module resolved. If npm ever gives
  //   pdfkit a different copy, this passes and pdfkit still crashes — so
  //   `registerFonts` in `passportPdf.js` repeats the probe THROUGH PDFKIT,
  //   which is the consumer that actually matters. `fontkit` is also now a
  //   declared dependency, so npm dedupes it.
  //
  //   It counts missing glyphs, not misplaced ones. A guard that started
  //   skipping EVERY anchor would shape the right glyphs in the wrong
  //   positions, and nothing here would notice. That is a real gap: catching
  //   it needs a reference rendering to compare against, which this project
  //   does not have.
  try {
    const probe = font.layout(SELF_TEST_STRING);
    const notdef = probe.glyphs.filter((g) => g.id === 0).length;
    if (notdef > 0) {
      throw new Error(
        `shaped ${notdef} .notdef glyph(s) for ${JSON.stringify(SELF_TEST_STRING)}`,
      );
    }
  } catch (err) {
    proto.applyAnchor = original;
    throw new Error(
      'The fontkit NULL-anchor fix installed but does not work: '
        + `${err.message}. Either fontkit's internals have moved, or this `
        + 'process has two fontkit copies and the patched prototype is not the '
        + 'one pdfkit shapes with. Refusing to report a working patch.',
    );
  }

  state = {
    patched: true,
    alreadyPatched: false,
    skipped: () => skipped,
    // Asserted by the tests, so "the guard fires at all" is a checked claim
    // rather than an assumption. Zero would mean the self-test string stopped
    // exercising the NULL path — the probe would still pass, and would have
    // stopped proving anything.
    selfTestSkipped: skipped,
    selfTestString: SELF_TEST_STRING,
  };
  return state;
}

/**
 * A string that crashes fontkit 2.0.4 unpatched.
 *
 * `পাসপোর্ট` — "passport", the certificate's own title. Its reph reaches the
 * MarkBasePos lookup whose base anchor is a legal NULL offset, which
 * `getAnchor` dereferences. Chosen because it is text the renderer actually
 * prints: a probe using a string the product never renders could pass while
 * the strings it does render fail.
 */
const SELF_TEST_STRING = 'পাসপোর্ট';

/** Whether the fix is in place. */
function isInstalled() {
  return state !== null;
}

module.exports = { install, isInstalled, PATCHED, SELF_TEST_STRING };
