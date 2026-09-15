/**
 * Chokro — a minimal ZIP writer, for the audit pack (EPR-33).
 *
 * ===========================================================================
 * WHY THIS EXISTS RATHER THAN A DEPENDENCY
 * ===========================================================================
 *
 * The audit pack is one artefact containing several documents, and EPR-33 asks
 * for a ZIP. This project had no zip library, so the choice was to add one or
 * to write the format.
 *
 * Writing it won on a narrow argument. The pack's entries are JSON and CSV
 * text, and STORED (uncompressed) entries need no deflate at all — which
 * removes the part of the ZIP format that is genuinely easy to get wrong.
 * What remains is a CRC-32, three fixed-layout records and some offset
 * arithmetic, all of which are directly verifiable against the system `unzip`.
 *
 * A compliance artefact that a regulator cannot open is a bad failure, so
 * `zip.test.js` extracts every fixture with the real `unzip` binary rather than
 * asserting byte patterns. If that test cannot run, the right move is to add a
 * library rather than to trust this.
 *
 * ===========================================================================
 * WHAT THIS DELIBERATELY DOES NOT SUPPORT
 * ===========================================================================
 *
 * No compression, no encryption, no directories, no ZIP64. The last is the one
 * with a real limit: ZIP64 is needed beyond 4 GB total or 65,535 entries, and
 * an audit pack is a dozen text files. `createZip` REFUSES beyond those bounds
 * rather than emitting a file that looks fine and is silently truncated — which
 * is exactly the failure mode a hand-written implementation is prone to.
 */

const zlib = require('zlib');

/** ZIP's four-byte record signatures. */
const LOCAL_FILE_HEADER = 0x04034b50;
const CENTRAL_DIRECTORY = 0x02014b50;
const END_OF_CENTRAL_DIRECTORY = 0x06054b50;

/**
 * The version needed to extract: 2.0, meaning "stored or deflated, no ZIP64".
 *
 * 1.0 would be the honest minimum for stored-only entries, but some readers
 * treat anything below 2.0 as suspect and 2.0 is universally understood.
 */
const VERSION_NEEDED = 20;

/** Stored, not deflated. See the module comment. */
const METHOD_STORED = 0;

/**
 * The general-purpose bit flag.
 *
 * Bit 11 says the filename is UTF-8. Every name this writer produces is ASCII,
 * so it changes nothing today — but setting it means a future name carrying a
 * Bengali period label is interpreted correctly rather than as CP437.
 */
const FLAG_UTF8 = 0x0800;

/** ZIP64 begins beyond these, and this writer refuses rather than truncating. */
const MAX_ENTRIES = 0xffff;
const MAX_TOTAL_BYTES = 0xffffffff;

/**
 * Builds a ZIP from named buffers.
 *
 * `entries` is `[{ name, content }]`, where `content` is a Buffer or a string.
 * `modified` is a Date — passed in rather than read from a clock, because two
 * audit packs over the same evidence should differ only where EPR-34 says they
 * may.
 */
function createZip(entries, { modified = new Date(0) } = {}) {
  if (!Array.isArray(entries) || entries.length === 0) {
    throw new Error('A ZIP needs at least one entry.');
  }
  if (entries.length > MAX_ENTRIES) {
    throw new Error(
      `${entries.length} entries needs ZIP64, which this writer does not `
        + 'produce. Refusing rather than emitting a truncated archive.',
    );
  }

  const seen = new Set();
  const { date, time } = dosDateTime(modified);

  const locals = [];
  const centrals = [];
  let offset = 0;

  for (const entry of entries) {
    const name = String(entry.name || '');
    if (!name) throw new Error('Every ZIP entry needs a name.');
    // A duplicate name produces an archive whose behaviour on extraction
    // depends on the reader — some take the first, some the last, some warn.
    // None of those is acceptable for an evidence bundle.
    if (seen.has(name)) throw new Error(`Duplicate ZIP entry: ${name}`);
    seen.add(name);

    const nameBytes = Buffer.from(name, 'utf8');
    const content = Buffer.isBuffer(entry.content)
      ? entry.content
      : Buffer.from(String(entry.content ?? ''), 'utf8');

    const crc = zlib.crc32(content);

    const local = Buffer.alloc(30);
    local.writeUInt32LE(LOCAL_FILE_HEADER, 0);
    local.writeUInt16LE(VERSION_NEEDED, 4);
    local.writeUInt16LE(FLAG_UTF8, 6);
    local.writeUInt16LE(METHOD_STORED, 8);
    local.writeUInt16LE(time, 10);
    local.writeUInt16LE(date, 12);
    local.writeUInt32LE(crc, 14);
    // Stored, so compressed and uncompressed sizes are the same. Writing them
    // here rather than in a trailing data descriptor keeps the archive
    // streamable-by-nobody and readable-by-everybody.
    local.writeUInt32LE(content.length, 18);
    local.writeUInt32LE(content.length, 22);
    local.writeUInt16LE(nameBytes.length, 26);
    local.writeUInt16LE(0, 28); // no extra field

    locals.push(local, nameBytes, content);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(CENTRAL_DIRECTORY, 0);
    central.writeUInt16LE(VERSION_NEEDED, 4); // version made by
    central.writeUInt16LE(VERSION_NEEDED, 6); // version needed
    central.writeUInt16LE(FLAG_UTF8, 8);
    central.writeUInt16LE(METHOD_STORED, 10);
    central.writeUInt16LE(time, 12);
    central.writeUInt16LE(date, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(content.length, 20);
    central.writeUInt32LE(content.length, 24);
    central.writeUInt16LE(nameBytes.length, 28);
    central.writeUInt16LE(0, 30); // extra field length
    central.writeUInt16LE(0, 32); // comment length
    central.writeUInt16LE(0, 34); // disk number start
    central.writeUInt16LE(0, 36); // internal attributes
    // External attributes: 0644, in the high 16 bits, as Unix zip writes them.
    // Without this some extractors create files with no read permission.
    //
    // `>>> 0` is load-bearing: JavaScript's `<<` is a SIGNED 32-bit shift, so
    // `0o100644 << 16` is 2,174,845,952 — past 2^31 — and comes back negative,
    // which `writeUInt32LE` then refuses outright.
    central.writeUInt32LE((0o100644 << 16) >>> 0, 38);
    central.writeUInt32LE(offset, 42);

    centrals.push(central, nameBytes);

    offset += local.length + nameBytes.length + content.length;
    if (offset > MAX_TOTAL_BYTES) {
      throw new Error(
        'This archive exceeds 4 GB and needs ZIP64, which this writer does not '
          + 'produce. Refusing rather than emitting a truncated archive.',
      );
    }
  }

  const centralBytes = Buffer.concat(centrals);

  const end = Buffer.alloc(22);
  end.writeUInt32LE(END_OF_CENTRAL_DIRECTORY, 0);
  end.writeUInt16LE(0, 4); // this disk
  end.writeUInt16LE(0, 6); // disk with central directory
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralBytes.length, 12);
  end.writeUInt32LE(offset, 16);
  end.writeUInt16LE(0, 20); // comment length

  return Buffer.concat([...locals, centralBytes, end]);
}

/**
 * A Date as the DOS date and time ZIP stores.
 *
 * MS-DOS format: seconds in two-second units, and the year as an offset from
 * 1980. A date before 1980 cannot be represented, so it is clamped rather than
 * wrapping into a nonsense year — an audit pack stamped 2044 because somebody
 * passed the Unix epoch would be worse than one stamped 1980.
 */
function dosDateTime(value) {
  const at = value instanceof Date && !Number.isNaN(value.getTime())
    ? value
    : new Date(0);

  const year = Math.max(1980, at.getUTCFullYear());

  return {
    date:
      ((year - 1980) << 9)
      | ((at.getUTCMonth() + 1) << 5)
      | at.getUTCDate(),
    time:
      (at.getUTCHours() << 11)
      | (at.getUTCMinutes() << 5)
      | Math.floor(at.getUTCSeconds() / 2),
  };
}

module.exports = {
  createZip,
  dosDateTime,
  MAX_ENTRIES,
  MAX_TOTAL_BYTES,
};
