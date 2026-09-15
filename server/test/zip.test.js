/**
 * The ZIP writer (EPR-33).
 *
 * ===========================================================================
 * THESE TESTS EXTRACT WITH THE REAL `unzip`, NOT WITH ASSERTIONS ABOUT BYTES
 * ===========================================================================
 *
 * This writer exists instead of a dependency, on the argument that a
 * stored-entry ZIP is small enough to get right and directly verifiable. The
 * verification is the other half of that argument: a compliance artefact a
 * regulator cannot open is a bad failure, and asserting that byte 38 holds the
 * value this module put there proves nothing about whether anything can read
 * it.
 *
 * So every fixture is written to disk and extracted by the system binary. If
 * `unzip` is unavailable the suite says so loudly rather than passing — a
 * silently skipped verification is worse than none, because it reads as a
 * verification that happened.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const { createZip, dosDateTime, MAX_ENTRIES } = require('../src/zip');

let unzipAvailable = true;
try {
  execFileSync('unzip', ['-v'], { stdio: 'ignore' });
} catch (_) {
  unzipAvailable = false;
}

let dir;

beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'chokro-zip-'));
});

afterEach(() => {
  fs.rmSync(dir, { recursive: true, force: true });
});

/** Writes an archive and returns its path. */
function write(entries, options) {
  const file = path.join(dir, 'pack.zip');
  fs.writeFileSync(file, createZip(entries, options));
  return file;
}

test('the system unzip is available to verify against', () => {
  // The canary. Without it every extraction test below would have to be
  // skipped, and a skipped verification reads as one that happened.
  expect(unzipAvailable).toBe(true);
});

describe('an archive the system unzip accepts', () => {
  const entries = [
    { name: 'manifest.json', content: '{"pack":"audit"}' },
    { name: 'declarations.csv', content: 'period,massMg\n2026-09,18000000000\n' },
    { name: 'methodology.txt', content: 'Collected, not recycled.\n' },
  ];

  test('passes an integrity check', () => {
    const file = write(entries);
    const output = execFileSync('unzip', ['-t', file], { encoding: 'utf8' });
    expect(output).toMatch(/No errors detected/);
  });

  test('lists every entry, with no extras', () => {
    const file = write(entries);
    const listed = execFileSync('unzip', ['-Z1', file], { encoding: 'utf8' })
      .trim()
      .split('\n');
    expect(listed.sort()).toEqual(entries.map((e) => e.name).sort());
  });

  test('round-trips content exactly', () => {
    const file = write(entries);
    execFileSync('unzip', ['-q', file, '-d', path.join(dir, 'out')]);

    for (const entry of entries) {
      const extracted = fs.readFileSync(path.join(dir, 'out', entry.name), 'utf8');
      expect(extracted).toBe(entry.content);
    }
  });

  test('round-trips Bengali exactly', () => {
    // The audit pack carries text from the same producer fields the passport
    // does. A ZIP that mangled UTF-8 would corrupt a producer's legal name in
    // the one artefact meant for a regulator.
    const bangla = 'প্লাস্টিক পাসপোর্ট\nমেঘনা প্যাকেজিং লিমিটেড\n';
    const file = write([{ name: 'bangla.txt', content: bangla }]);
    execFileSync('unzip', ['-q', file, '-d', path.join(dir, 'out')]);

    expect(fs.readFileSync(path.join(dir, 'out', 'bangla.txt'), 'utf8')).toBe(bangla);
  });

  test('round-trips a binary entry', () => {
    // A passport PDF goes into the pack as bytes, and a writer that assumed
    // text would corrupt it in ways a text round-trip cannot detect.
    const binary = Buffer.from([0x25, 0x50, 0x44, 0x46, 0x00, 0xff, 0xfe, 0x0a, 0x1a]);
    const file = write([{ name: 'passport.pdf', content: binary }]);
    execFileSync('unzip', ['-q', file, '-d', path.join(dir, 'out')]);

    expect(fs.readFileSync(path.join(dir, 'out', 'passport.pdf'))).toEqual(binary);
  });

  test('extracts files a reader can actually open', () => {
    // Without the external-attribute field some extractors create files with
    // no read permission — and the signed-shift that fills it overflowed to a
    // negative number on the first attempt, which `writeUInt32LE` refused
    // outright.
    const file = write(entries);
    execFileSync('unzip', ['-q', file, '-d', path.join(dir, 'out')]);

    const mode = fs.statSync(path.join(dir, 'out', 'manifest.json')).mode;
    // Readable by owner at minimum.
    expect(mode & 0o400).toBeTruthy();
  });

  test('carries the timestamp it was given, not the clock', () => {
    // EPR-34: two artefacts over the same evidence differ only where the spec
    // says they may. A ZIP stamped with `new Date()` inside the writer would
    // differ on every run.
    const file = write(entries, { modified: new Date('2026-10-03T05:12:00Z') });
    const listing = execFileSync('unzip', ['-l', file], { encoding: 'utf8' });
    // Date layout varies by `unzip` build (10-03-2026 here, 2026-10-03
    // elsewhere), so this asserts the parts rather than one vendor's format.
    expect(listing).toMatch(/2026/);
    expect(listing).toMatch(/05:12/);
    expect(listing).toMatch(/10.03|03.10/);
  });

  test('is byte-identical across two runs with the same input', () => {
    const at = new Date('2026-10-03T05:12:00Z');
    expect(createZip(entries, { modified: at }))
      .toEqual(createZip(entries, { modified: at }));
  });
});

describe('what the writer refuses', () => {
  test('an empty archive', () => {
    expect(() => createZip([])).toThrow(/at least one entry/i);
    expect(() => createZip(null)).toThrow(/at least one entry/i);
  });

  test('an entry with no name', () => {
    expect(() => createZip([{ name: '', content: 'x' }])).toThrow(/needs a name/i);
  });

  test('a duplicate name', () => {
    // An archive with two entries of one name behaves differently in different
    // readers — first wins, last wins, or a warning. None of those is
    // acceptable for an evidence bundle.
    expect(() =>
      createZip([
        { name: 'a.json', content: '1' },
        { name: 'a.json', content: '2' },
      ]),
    ).toThrow(/Duplicate/i);
  });

  test('more entries than a non-ZIP64 archive can hold', () => {
    // Refusing rather than emitting a file that looks fine and is silently
    // truncated — the failure a hand-written implementation is prone to.
    const many = Array.from({ length: MAX_ENTRIES + 1 }, (_, i) => ({
      name: `f${i}.txt`,
      content: 'x',
    }));
    expect(() => createZip(many)).toThrow(/ZIP64/);
  });
});

describe('the DOS timestamp', () => {
  test('encodes a date ZIP can represent', () => {
    const { date, time } = dosDateTime(new Date('2026-10-03T05:12:00Z'));

    expect((date >> 9) + 1980).toBe(2026);
    expect((date >> 5) & 0x0f).toBe(10);
    expect(date & 0x1f).toBe(3);
    expect(time >> 11).toBe(5);
    expect((time >> 5) & 0x3f).toBe(12);
  });

  test('clamps a pre-1980 date rather than wrapping it', () => {
    // MS-DOS counts years from 1980, so the Unix epoch would wrap into a
    // nonsense year. An audit pack stamped 2044 is worse than one stamped 1980.
    const { date } = dosDateTime(new Date(0));
    expect((date >> 9) + 1980).toBe(1980);
  });

  test('survives an invalid date', () => {
    expect(() => dosDateTime(new Date('nonsense'))).not.toThrow();
    expect(() => dosDateTime(null)).not.toThrow();
  });
});
