/**
 * The NULL-anchor guard, and the half of it the self-test cannot reach.
 *
 * `install()` already proves the patch is live: it shapes a string that crashes
 * an unpatched fontkit and refuses to report success if it still does. What it
 * explicitly does NOT prove — the module says so itself — is that the guard
 * still *discriminates*. A patched `applyAnchor` that returned early for every
 * anchor would shape exactly the right glyphs into the wrong positions, pass
 * the self-test, and degrade every Bengali certificate with no signal at all.
 *
 * Catching the misplacement itself needs a reference rendering this project
 * does not have. Catching the predicate going wrong does not, and that is the
 * failure mode with a mechanism behind it: the guard is three null checks
 * against a fontkit internal, and fontkit is free to change what it passes.
 */

const fontkit = require('fontkit');
const path = require('path');
const { install, isInstalled, SELF_TEST_STRING } = require('../src/fontkitNullAnchorFix');

const BENGALI_FONT = path.resolve(__dirname, '../assets/fonts/NotoSansBengali-Regular.ttf');

describe('the NULL-anchor guard', () => {
  test('installs and reports itself installed', () => {
    const state = install(BENGALI_FONT);
    expect(state.patched).toBe(true);
    expect(isInstalled()).toBe(true);
  });

  test('the self-test string shapes without a .notdef glyph', () => {
    install(BENGALI_FONT);
    const font = fontkit.openSync(BENGALI_FONT);
    const run = font.layout(SELF_TEST_STRING);

    expect(run.glyphs.length).toBeGreaterThan(0);
    expect(run.glyphs.filter((g) => g.id === 0)).toHaveLength(0);
  });

  test('the guard fires exactly once on the string it exists for', () => {
    // `পাসপোর্ট` is that string: its reph reaches a MarkBasePos lookup whose
    // base anchor is a legal NULL, which unpatched fontkit dereferences and
    // crashes on. One skip is the correct count.
    //
    // This does NOT prove the guard still discriminates — measured, not
    // assumed: this string reaches `applyAnchor` once, so a guard that skipped
    // EVERYTHING would also report one. The test below is the one that catches
    // that, and this comment says so rather than letting the count look like
    // more evidence than it is.
    const state = install(BENGALI_FONT);
    const font = fontkit.openSync(BENGALI_FONT);

    const before = state.skipped();
    const run = font.layout(SELF_TEST_STRING);

    expect(run.glyphs.length).toBeGreaterThan(1);
    expect(state.skipped() - before).toBe(1);
  });

  test('a real anchor is applied rather than skipped', () => {
    // The other half: proof that `original.call` still runs. Ordinary Bengali
    // positions its marks by advance, so a sentence shows no anchor offsets at
    // all — this sequence (nukta then candrabindu) is one that does, and a
    // non-zero offset cannot be produced by a guard that skipped it.
    install(BENGALI_FONT);
    const font = fontkit.openSync(BENGALI_FONT);

    const run = font.layout('কি়ঁ');
    const positioned = run.positions.filter(
      (pos) => pos.xOffset !== 0 || pos.yOffset !== 0,
    );

    expect(positioned.length).toBeGreaterThan(0);
  });

  test('installing twice does not double-patch', () => {
    const first = install(BENGALI_FONT);
    const second = install(BENGALI_FONT);
    expect(second.patched).toBe(true);
    expect(second).toBe(first);
  });
});
