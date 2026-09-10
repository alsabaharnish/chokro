/**
 * One in-memory Firestore, shared by the server tests.
 *
 * ===========================================================================
 * WHY THIS IS A SHARED FILE AND NOT A LOCAL HELPER
 * ===========================================================================
 *
 * It used to be three near-copies, one per test file, and each copy grew its
 * own bug:
 *
 *  - `producerSkus`' copy ignored the query operator, so a `>` range filter
 *    matched nothing. A query bounded on `expiresAt > now` looked empty and the
 *    invitation ceiling it guards never fired in a single test.
 *  - `organizations`' copy had no `set`/`update` on a document ref, so a write
 *    through a bare ref failed.
 *  - `eprPeriods`' copy had NEITHER the read-after-write guard NOR
 *    operator-honouring filters, long after both were fixed elsewhere.
 *
 * A fake is test infrastructure, so a gap in it does not fail anything — it
 * quietly widens what the suite accepts. Four copies would have meant a fourth
 * gap. One copy means a fix reaches every caller.
 *
 * ===========================================================================
 * THE ONE RULE IT ENFORCES ON PURPOSE
 * ===========================================================================
 *
 * Firestore requires every read in a transaction to precede every write, and
 * the Admin SDK throws unconditionally otherwise. Four real read-after-write
 * bugs shipped past this suite because the fakes did not care, and one of them
 * was in a function that had no test at all. `txn.get` after any write throws
 * here, with the message the Admin SDK actually produces.
 */

/** The increment sentinel the tests' `firebase` mock produces. */
function isIncrement(value) {
  return Boolean(value) && typeof value === 'object' && '__increment' in value;
}

/** The arrayUnion sentinel. */
function isArrayUnion(value) {
  return Boolean(value) && typeof value === 'object' && '__arrayUnion' in value;
}

/**
 * Applies an update map, honouring dotted field paths and the sentinels.
 *
 * `null` is a legitimate stored value — `gazetteCategoryResolved: null` is a
 * real write — so a sentinel is detected by a predicate rather than by
 * comparing against null, which an earlier version did and threw on.
 */
function applyUpdate(existing, update) {
  const result = { ...(existing || {}) };

  for (const [rawKey, value] of Object.entries(update)) {
    if (rawKey.includes('.')) {
      const [head, ...rest] = rawKey.split('.');
      const tail = rest.join('.');
      const nested = { ...(result[head] || {}) };
      if (isIncrement(value)) {
        nested[tail] = (nested[tail] || 0) + value.__increment;
      } else if (isArrayUnion(value)) {
        const current = Array.isArray(nested[tail]) ? nested[tail] : [];
        nested[tail] = [...new Set([...current, ...value.__arrayUnion])];
      } else {
        nested[tail] = value;
      }
      result[head] = nested;
      continue;
    }

    if (isIncrement(value)) {
      result[rawKey] = (result[rawKey] || 0) + value.__increment;
    } else if (isArrayUnion(value)) {
      const current = Array.isArray(result[rawKey]) ? result[rawKey] : [];
      result[rawKey] = [...new Set([...current, ...value.__arrayUnion])];
    } else {
      result[rawKey] = value;
    }
  }

  return result;
}

/**
 * Reduces a value to something comparable.
 *
 * A stored Firestore `Timestamp` and a `Date` are different objects for the
 * same instant, so a range filter on a timestamp has to compare instants
 * rather than object identity — and an equality filter on two distinct `Date`
 * objects for the same moment must be true, which `===` alone would get wrong.
 */
function comparable(value) {
  if (value && typeof value.toDate === 'function') return value.toDate().getTime();
  if (value instanceof Date) return value.getTime();
  return value;
}

/**
 * Compares a stored value against a filter, honouring the operator.
 *
 * A fake that treated every `where` as equality returned nothing for every
 * range filter, which made queries that guard a ceiling look empty.
 */
function compare(rawStored, op, rawValue) {
  const stored = comparable(rawStored);
  const value = Array.isArray(rawValue) ? rawValue.map(comparable) : comparable(rawValue);

  switch (op) {
    case '==':
      return stored === value;
    case '!=':
      return stored !== value;
    case '>':
      return stored > value;
    case '>=':
      return stored >= value;
    case '<':
      return stored < value;
    case '<=':
      return stored <= value;
    case 'in':
      return Array.isArray(value) && value.includes(stored);
    case 'not-in':
      return Array.isArray(value) && !value.includes(stored);
    case 'array-contains':
      return Array.isArray(rawStored) && rawStored.map(comparable).includes(value);
    case 'array-contains-any':
      return (
        Array.isArray(rawStored)
        && Array.isArray(value)
        && rawStored.map(comparable).some((v) => value.includes(v))
      );
    default:
      throw new Error(`The Firestore fake does not implement operator "${op}".`);
  }
}

function fakeFirestore() {
  const store = new Map();
  const key = (col, id) => `${col}/${id}`;
  let autoId = 0;

  // Set by the first write in a transaction, cleared when one begins.
  let writeIssued = false;

  function makeRef(col, id) {
    return {
      id,
      path: key(col, id),
      async get() {
        const data = store.get(key(col, id));
        return { exists: data !== undefined, id, ref: makeRef(col, id), data: () => data };
      },
      // Present because a real DocumentReference has them, and a path that
      // wrote through a bare ref used to fail here for no reason a reader
      // could see.
      async set(data, options) {
        store.set(key(col, id), options?.merge
          ? applyUpdate(store.get(key(col, id)), data)
          : { ...data });
      },
      async update(data) {
        store.set(key(col, id), applyUpdate(store.get(key(col, id)), data));
      },
      async delete() {
        store.delete(key(col, id));
      },
    };
  }

  function collection(col) {
    // Fresh per `collection()` call, as a real query builder is.
    const q = { filters: [], max: Infinity, order: null, startedAfter: false };

    const api = {
      doc(id) {
        autoId += 1;
        return makeRef(col, id || `auto_${autoId}`);
      },
      where(field, op, value) {
        q.filters.push([field, op, value]);
        return api;
      },
      orderBy(field, direction = 'asc') {
        q.order = [field, direction];
        return api;
      },
      startAfter(value) {
        // Honoured, not just recorded. A fake that accepted a cursor and
        // ignored it returns page one on every pass, so a paged read either
        // loops forever or silently reports only its first batch — and a
        // report that quietly stops at 500 rows is worse than one that fails.
        q.startedAfter = true;
        q.after = value;
        return api;
      },
      limit(n) {
        q.max = n;
        return api;
      },
      async get() {
        let rows = [...store.entries()]
          .filter(([k]) => k.startsWith(`${col}/`))
          .map(([k, v]) => ({
            id: k.slice(col.length + 1),
            ref: makeRef(col, k.slice(col.length + 1)),
            data: () => v,
          }));

        for (const [field, op, value] of q.filters) {
          // `__name__` is how the Admin SDK spells a document-id filter.
          rows = rows.filter((r) =>
            compare(field === '__name__' ? r.id : r.data()[field], op, value));
        }

        if (q.order) {
          const [field, direction] = q.order;
          // `__name__` orders by document id, as the Admin SDK does. Reading
          // it as a data field returns undefined for every row, so the sort
          // becomes a no-op and the fake silently returns insertion order —
          // which would let a test asserting deterministic ordering pass on
          // code that does not order at all.
          const valueOf = (row) =>
            field === '__name__' ? row.id : comparable(row.data()[field]);
          rows.sort((a, b) => {
            const x = valueOf(a);
            const y = valueOf(b);
            if (x === y) return 0;
            return direction === 'desc' ? (y > x ? 1 : -1) : (x > y ? 1 : -1);
          });
        } else {
          rows.sort((a, b) => a.id.localeCompare(b.id));
        }

        if (q.startedAfter && q.after !== undefined) {
          const orderField = q.order ? q.order[0] : '__name__';
          const cursorIndex = rows.findIndex((r) =>
            orderField === '__name__'
              ? r.id === q.after
              : comparable(r.data()[orderField]) === comparable(q.after));
          rows = cursorIndex === -1 ? rows : rows.slice(cursorIndex + 1);
        }

        rows = rows.slice(0, q.max);
        return { docs: rows, empty: rows.length === 0, size: rows.length };
      },
    };

    return api;
  }

  const txn = {
    async get(target) {
      if (writeIssued) {
        throw new Error(
          'Firestore transactions require all reads to be executed before all writes.',
        );
      }
      return typeof target.get === 'function' ? target.get() : target;
    },
    set(ref, data, options) {
      writeIssued = true;
      store.set(ref.path, options?.merge
        ? applyUpdate(store.get(ref.path), data)
        : { ...data });
    },
    update(ref, data) {
      writeIssued = true;
      store.set(ref.path, applyUpdate(store.get(ref.path), data));
    },
    delete(ref) {
      writeIssued = true;
      store.delete(ref.path);
    },
  };

  return {
    collection,

    async runTransaction(fn) {
      // A fresh transaction starts with no writes issued, exactly as a real
      // one does — otherwise the second transaction in a test would refuse
      // every read.
      writeIssued = false;
      return fn(txn);
    },

    batch() {
      const ops = [];
      const api = {
        set(ref, data, options) {
          ops.push(() => store.set(ref.path, options?.merge
            ? applyUpdate(store.get(ref.path), data)
            : { ...data }));
          return api;
        },
        update(ref, data) {
          ops.push(() => store.set(ref.path, applyUpdate(store.get(ref.path), data)));
          return api;
        },
        delete(ref) {
          ops.push(() => store.delete(ref.path));
          return api;
        },
        async commit() {
          for (const op of ops) op();
          return ops.length;
        },
      };
      return api;
    },

    _store: store,
    _seed(col, id, data) {
      store.set(key(col, id), data);
    },
    _find(col) {
      return [...store.entries()]
        .filter(([k]) => k.startsWith(`${col}/`))
        .map(([k, v]) => ({ id: k.slice(col.length + 1), ...v }));
    },
  };
}

module.exports = {
  fakeFirestore,
  applyUpdate,
  compare,
  comparable,
  isIncrement,
  isArrayUnion,
};
