#!/usr/bin/env node
/**
 * Chokro — demonstration seed (M3 deliverable).
 *
 * "Never demo from an empty database." A presentation that begins by creating
 * an account, registering a bin and listing a product spends its five minutes
 * on setup and never reaches the thing being marked — the earn/spend cycle.
 * This script puts a plausible platform in place so the demonstration can start
 * at the interesting part.
 *
 *   SEED_PASSWORD=... node scripts/seed.js --yes
 *
 * ## Two safety rails, both deliberate
 *
 * **No password in the repository (NFR-9).** `SEED_PASSWORD` is required and has
 * no default. A committed demo password is still a credential in the repository,
 * and the exception would be the one nobody remembers to remove.
 *
 * **`--yes` is required, and the project id is printed first.** This writes with
 * the Admin SDK, which bypasses every security rule. Pointed at the wrong
 * project it would silently mint accounts and wallets there. The flag makes
 * running it an act rather than an accident.
 *
 * ## Why the ledger is accumulated rather than asserted
 *
 * NFR-4 says a balance must be reconstructable from the `transactions` ledger.
 * A seed that wrote a wallet balance and some plausible-looking entries would
 * violate exactly the invariant the project spends most of its effort proving.
 * So every balance below is the running total of the entries this script writes,
 * and `stats/platform` is likewise derived from what was actually seeded. If the
 * demonstration data is inconsistent, it is inconsistent in a way the app itself
 * would produce.
 *
 * Idempotent by construction: documents are written at fixed ids and accounts
 * are looked up by email before being created, so re-running refreshes the
 * demonstration rather than doubling it.
 */

require('dotenv').config();

const { db, auth, admin, initFirebase } = require('../src/firebase');
const policyModule = require('../src/pointsPolicy');

const POLICY = policyModule.defaults();

// ---------------------------------------------------------------------------
// The cast
// ---------------------------------------------------------------------------

const PEOPLE = [
  { key: 'admin', name: 'Rumi Chowdhury', email: 'admin@chokro.demo', role: 'admin' },
  { key: 'seller1', name: 'Nabila Haque', email: 'nabila@chokro.demo', role: 'seller' },
  { key: 'seller2', name: 'Tanvir Ahmed', email: 'tanvir@chokro.demo', role: 'seller' },
  { key: 'buyer1', name: 'Sadia Rahman', email: 'sadia@chokro.demo', role: 'buyer' },
  { key: 'buyer2', name: 'Imran Kabir', email: 'imran@chokro.demo', role: 'buyer' },
];

const BINS = [
  {
    id: 'seed_bin_merul',
    label: 'Merul Badda — Block C gate',
    lat: 23.7808,
    lng: 90.4074,
    radiusMeters: 50,
  },
  {
    id: 'seed_bin_bashundhara',
    label: 'Bashundhara R/A — Gate 1',
    lat: 23.8194,
    lng: 90.4265,
    radiusMeters: 60,
  },
  {
    id: 'seed_bin_gulshan',
    label: 'Gulshan 2 — Circle park',
    lat: 23.7925,
    lng: 90.4143,
    radiusMeters: 45,
  },
];

/** Listings, spread across sellers and categories so the filter has work to do. */
const PRODUCTS = [
  {
    id: 'seed_p_toothbrush',
    seller: 'seller1',
    shopName: 'Green Corner',
    title: 'Bamboo Toothbrush',
    description:
      'A biodegradable brush with soft bristles and a bamboo handle. Sold in '
      + 'a paper sleeve with no plastic wrap.',
    category: 'personalCare',
    tags: ['eco friendly', 'bamboo', 'plastic free'],
    price: 250,
    stock: 40,
  },
  {
    id: 'seed_p_jutebag',
    seller: 'seller1',
    shopName: 'Green Corner',
    title: 'Jute Shopping Bag',
    description:
      'Hand-stitched jute bag that folds flat. Holds about eight kilograms, '
      + 'which is a full week of vegetables.',
    category: 'fashion',
    tags: ['jute', 'reusable', 'handmade'],
    price: 480,
    stock: 25,
  },
  {
    id: 'seed_p_bottle',
    seller: 'seller1',
    shopName: 'Green Corner',
    title: 'Steel Water Bottle',
    description:
      'Double-walled steel bottle, 750ml, keeps water cold for most of a day. '
      + 'Replaces roughly three hundred single-use bottles a year.',
    category: 'homeAndLiving',
    tags: ['reusable', 'steel', 'plastic free'],
    price: 900,
    stock: 12,
  },
  {
    id: 'seed_p_compost',
    seller: 'seller2',
    shopName: 'Shobuj Ghor',
    title: 'Balcony Compost Bin',
    description:
      'A twenty-litre compost bin sized for a balcony, with a tap for liquid '
      + 'fertiliser and a lid that actually seals.',
    category: 'gardening',
    tags: ['compost', 'garden', 'organic'],
    price: 1600,
    stock: 8,
  },
  {
    id: 'seed_p_seeds',
    seller: 'seller2',
    shopName: 'Shobuj Ghor',
    title: 'Native Herb Seed Set',
    description:
      'Six packets of herbs that grow well on a Dhaka balcony — coriander, '
      + 'mint, basil, chilli, spinach and fenugreek.',
    category: 'gardening',
    tags: ['seeds', 'garden', 'organic'],
    price: 320,
    stock: 60,
  },
  {
    id: 'seed_p_notebook',
    seller: 'seller2',
    shopName: 'Shobuj Ghor',
    title: 'Recycled Paper Notebook',
    description:
      'A hundred and sixty pages of recycled paper, stitched rather than glued '
      + 'so it opens flat and can be repaired.',
    category: 'stationery',
    tags: ['recycled', 'paper', 'handmade'],
    price: 180,
    stock: 45,
  },
  {
    id: 'seed_p_soap',
    seller: 'seller1',
    shopName: 'Green Corner',
    title: 'Cold Pressed Neem Soap',
    description:
      'Cold-pressed soap with neem and turmeric, wrapped in paper. Made in '
      + 'small batches, so colour varies between them.',
    category: 'personalCare',
    tags: ['handmade', 'plastic free'],
    price: 140,
    stock: 0,
  },
  {
    id: 'seed_p_lunchbox',
    seller: 'seller2',
    shopName: 'Shobuj Ghor',
    title: 'Steel Lunch Box',
    description:
      'Three-tier steel tiffin carrier with a clip lock. The kind that lasts a '
      + 'decade rather than a term.',
    category: 'homeAndLiving',
    tags: ['steel', 'reusable'],
    price: 1100,
    stock: 15,
  },
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Mirrors `searchTokensFor` in lib/core/product_taxonomy.dart. */
function normalizeTag(raw) {
  return String(raw)
    .trim()
    .toLowerCase()
    .replace(/\s+/g, '-')
    .replace(/[^a-z0-9-]/g, '')
    .replace(/-+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40);
}

function searchTokensFor({ title, category, tags }) {
  const tokens = new Set();
  const add = (value) => {
    if (tokens.size >= 30 || value.length < 2) return;
    tokens.add(value);
  };

  for (const word of title.toLowerCase().split(/[^a-z0-9]+/)) add(word);
  for (const tag of tags.map(normalizeTag).filter(Boolean)) {
    add(tag);
    for (const part of tag.split('-')) add(part);
  }
  add(category.toLowerCase());

  return [...tokens].sort();
}

function daysAgo(n) {
  return new Date(Date.now() - n * 24 * 60 * 60 * 1000);
}

/**
 * The ledger, accumulated.
 *
 * Every credit and debit goes through here, so a wallet balance is by
 * construction the sum of its entries (NFR-4) rather than a number somebody
 * typed alongside them.
 */
class Ledger {
  constructor() {
    this.balances = new Map();
    this.entries = [];
    this.pointsIssued = 0;
    this.pointsRedeemed = 0;
  }

  post({ uid, delta, source, refId, at }) {
    const before = this.balances.get(uid) || 0;
    const after = before + delta;
    if (after < 0) {
      throw new Error(`Seed would overdraw ${uid}: ${before} ${delta}`);
    }

    this.balances.set(uid, after);
    this.entries.push({
      userId: uid,
      delta,
      source,
      refId,
      balanceAfter: after,
      createdAt: at,
    });

    if (delta > 0) this.pointsIssued += delta;
    else this.pointsRedeemed += -delta;

    return after;
  }

  balanceOf(uid) {
    return this.balances.get(uid) || 0;
  }
}

// ---------------------------------------------------------------------------
// Seed
// ---------------------------------------------------------------------------

async function ensureAccount(person, password) {
  let record;
  try {
    record = await auth().getUserByEmail(person.email);
    await auth().updateUser(record.uid, { password, displayName: person.name });
  } catch (err) {
    if (err.code !== 'auth/user-not-found') throw err;
    record = await auth().createUser({
      email: person.email,
      password,
      displayName: person.name,
      emailVerified: true,
    });
  }
  return record.uid;
}

async function main() {
  const password = process.env.SEED_PASSWORD;
  if (!password || password.length < 6) {
    throw new Error(
      'Set SEED_PASSWORD (at least 6 characters) before running the seed. It '
        + 'is not stored in the repository — see NFR-9.',
    );
  }

  initFirebase();
  const firestore = db();
  const projectId = admin.app().options.credential.projectId
    || process.env.GOOGLE_CLOUD_PROJECT
    || '(unknown)';

  if (!process.argv.includes('--yes')) {
    console.log(`\nThis writes demonstration data to: ${projectId}`);
    console.log('It uses the Admin SDK, which bypasses every security rule.');
    console.log('Re-run with --yes if that is the project you meant.\n');
    process.exit(1);
  }

  console.log(`Seeding ${projectId}…`);

  // ---- accounts and wallets ----
  const uids = {};
  for (const person of PEOPLE) {
    uids[person.key] = await ensureAccount(person, password);
  }

  const ledger = new Ledger();

  // ---- policy ----
  await firestore.collection('config').doc('points').set({
    ...POLICY,
    updatedAt: admin.firestore.Timestamp.fromDate(daysAgo(14)),
    updatedBy: uids.admin,
  });

  // ---- bins ----
  for (const bin of BINS) {
    await firestore.collection('bins').doc(bin.id).set({
      binId: bin.id,
      label: bin.label,
      lat: bin.lat,
      lng: bin.lng,
      radiusMeters: bin.radiusMeters,
      qrPayload: `chokro:bin:${bin.id}`,
      active: true,
      createdBy: uids.admin,
      createdAt: admin.firestore.Timestamp.fromDate(daysAgo(30)),
    });
  }

  // ---- products ----
  for (const product of PRODUCTS) {
    const tags = [...new Set(product.tags.map(normalizeTag).filter(Boolean))]
      .sort()
      .slice(0, 8);

    await firestore.collection('products').doc(product.id).set({
      sellerId: uids[product.seller],
      shopName: product.shopName,
      title: product.title,
      titleLower: product.title.trim().toLowerCase(),
      searchTokens: searchTokensFor({
        title: product.title,
        category: product.category,
        tags: product.tags,
      }),
      description: product.description,
      category: product.category,
      tags,
      price: product.price,
      stock: product.stock,
      // No images. The rules validate an image URL against the seller's own
      // upload folder, and a seed cannot manufacture one that would pass — so it
      // writes none rather than something that would have to be excused.
      imageUrls: [],
      active: true,
      createdAt: admin.firestore.Timestamp.fromDate(daysAgo(20)),
      updatedAt: admin.firestore.Timestamp.fromDate(daysAgo(20)),
    });
  }

  // ---- disposals, in every state the machine has ----
  const disposals = [
    { id: 'seed_d_1', user: 'buyer1', bin: BINS[0], status: 'autoApproved', days: 9 },
    { id: 'seed_d_2', user: 'buyer1', bin: BINS[1], status: 'manualApproved', days: 6 },
    { id: 'seed_d_3', user: 'buyer2', bin: BINS[0], status: 'autoApproved', days: 5 },
    { id: 'seed_d_4', user: 'buyer2', bin: BINS[2], status: 'rejected', days: 4 },
    { id: 'seed_d_5', user: 'seller1', bin: BINS[1], status: 'autoApproved', days: 3 },
    { id: 'seed_d_6', user: 'buyer1', bin: BINS[2], status: 'pending', days: 0 },
  ];

  let disposalsApproved = 0;
  let disposalsRejected = 0;

  for (const item of disposals) {
    const uid = uids[item.user];
    const at = admin.firestore.Timestamp.fromDate(daysAgo(item.days));
    const approved = item.status === 'autoApproved' || item.status === 'manualApproved';

    if (approved) {
      disposalsApproved += 1;
      ledger.post({
        uid,
        delta: POLICY.disposalAward,
        source: 'disposal',
        refId: item.id,
        at,
      });
    } else if (item.status === 'rejected') {
      disposalsRejected += 1;
    }

    await firestore.collection('disposals').doc(item.id).set({
      userId: uid,
      binId: item.bin.id,
      // A seeded photo URL cannot satisfy the provenance check, and pretending
      // otherwise would make the demonstration data lie about the one thing the
      // verification pipeline exists to prove. Left empty and stated.
      photoUrl: '',
      photoPublicId: '',
      capturedLat: item.bin.lat,
      capturedLng: item.bin.lng,
      distanceMeters: 12,
      declaredItemCount: 5,
      itemType: 'plasticBottle',
      status: item.status,
      flags: item.status === 'manualApproved' ? ['lowConfidence'] : [],
      pointsAwarded: approved ? POLICY.disposalAward : item.status === 'rejected' ? 0 : null,
      rejectionReason:
        item.status === 'rejected'
          ? 'The photograph did not show the declared items at the bin.'
          : null,
      reviewedBy: item.status === 'manualApproved' || item.status === 'rejected'
        ? uids.admin
        : null,
      reviewedAt: item.status === 'manualApproved' || item.status === 'rejected' ? at : null,
      verificationCompleted: item.status !== 'pending',
      createdAt: at,
    });
  }

  // ---- one claim of each outcome ----
  const claims = [
    { id: 'seed_c_1', user: 'buyer1', action: 'treePlanting', status: 'approved', days: 7 },
    { id: 'seed_c_2', user: 'buyer2', action: 'composting', status: 'rejected', days: 2 },
    { id: 'seed_c_3', user: 'buyer2', action: 'communityCleanup', status: 'pending', days: 0 },
  ];

  let claimsApproved = 0;
  let claimsRejected = 0;

  for (const claim of claims) {
    const uid = uids[claim.user];
    const at = admin.firestore.Timestamp.fromDate(daysAgo(claim.days));

    if (claim.status === 'approved') {
      claimsApproved += 1;
      ledger.post({
        uid,
        delta: POLICY.claimAward,
        source: 'claim',
        refId: claim.id,
        at,
      });
    } else if (claim.status === 'rejected') {
      claimsRejected += 1;
    }

    await firestore.collection('claims').doc(claim.id).set({
      userId: uid,
      actionType: claim.action,
      photoUrl: '',
      photoPublicId: '',
      status: claim.status,
      pointsAwarded: claim.status === 'approved' ? POLICY.claimAward : null,
      rejectionReason:
        claim.status === 'rejected'
          ? 'The photograph does not show a compost heap or bin.'
          : null,
      reviewedBy: claim.status === 'pending' ? null : uids.admin,
      reviewedAt: claim.status === 'pending' ? null : at,
      createdAt: at,
    });
  }

  // ---- orders, one in each state a demonstration needs ----
  //
  // Written through the same arithmetic the server uses: subtotal from the line
  // snapshots, discount from the redemption rate, purchase award from payable.
  const orderPlans = [
    {
      id: 'seed_o_confirmed',
      checkoutId: 'seed_checkout_1',
      buyer: 'buyer1',
      seller: 'seller1',
      shopName: 'Green Corner',
      lines: [{ product: 'seed_p_bottle', qty: 1 }],
      pointsApplied: 300,
      status: 'confirmed',
      days: 8,
    },
    {
      id: 'seed_o_delivered',
      checkoutId: 'seed_checkout_2',
      buyer: 'buyer2',
      seller: 'seller2',
      shopName: 'Shobuj Ghor',
      lines: [{ product: 'seed_p_seeds', qty: 2 }],
      pointsApplied: 0,
      status: 'delivered',
      days: 2,
    },
    {
      id: 'seed_o_pending',
      checkoutId: 'seed_checkout_3',
      buyer: 'buyer1',
      seller: 'seller2',
      shopName: 'Shobuj Ghor',
      lines: [{ product: 'seed_p_notebook', qty: 3 }],
      pointsApplied: 0,
      status: 'pending',
      days: 1,
    },
  ];

  const productById = new Map(PRODUCTS.map((p) => [p.id, p]));
  const nameByKey = new Map(PEOPLE.map((p) => [p.key, p.name]));

  let ordersCreated = 0;
  let ordersConfirmed = 0;
  let salesPayable = 0;

  for (const plan of orderPlans) {
    const at = admin.firestore.Timestamp.fromDate(daysAgo(plan.days));
    const buyerUid = uids[plan.buyer];

    const items = plan.lines.map((line) => {
      const product = productById.get(line.product);
      return {
        productId: product.id,
        title: product.title,
        unitPrice: product.price,
        qty: line.qty,
      };
    });

    const subtotal = items.reduce((sum, i) => sum + i.unitPrice * i.qty, 0);
    const discount = policyModule.takaForPoints(POLICY, plan.pointsApplied);
    const payable = subtotal - discount;

    if (plan.pointsApplied > 0) {
      ledger.post({
        uid: buyerUid,
        delta: -plan.pointsApplied,
        source: 'redemption',
        refId: plan.checkoutId,
        at,
      });
    }

    let pointsAwarded = null;
    if (plan.status === 'confirmed') {
      pointsAwarded = policyModule.purchaseAward(POLICY, payable);
      if (pointsAwarded > 0) {
        ledger.post({
          uid: buyerUid,
          delta: pointsAwarded,
          source: 'purchase',
          refId: plan.id,
          at,
        });
      }
      ordersConfirmed += 1;
    }

    ordersCreated += 1;
    salesPayable += payable;

    await firestore.collection('orders').doc(plan.id).set({
      buyerId: buyerUid,
      buyerName: nameByKey.get(plan.buyer),
      sellerId: uids[plan.seller],
      sellerName: nameByKey.get(plan.seller),
      shopName: plan.shopName,
      checkoutId: plan.checkoutId,
      items,
      subtotal,
      pointsApplied: plan.pointsApplied,
      discount,
      payable,
      settlementMethod: 'cashOnDelivery',
      paymentStatus: plan.status === 'pending' ? 'pending' : 'paid',
      status: plan.status,
      pointsAwarded,
      createdAt: at,
      shippedAt: plan.status === 'pending' ? null : at,
      deliveredAt: plan.status === 'pending' ? null : at,
      confirmedAt: plan.status === 'confirmed' ? at : null,
    });
  }

  // ---- one appeal, so the queue is not empty at the demonstration ----
  await firestore.collection('appeals').doc('seed_a_1').set({
    userId: uids.buyer2,
    subjectType: 'disposal',
    subjectId: 'seed_d_4',
    message:
      'I was standing at the Gulshan bin and the photograph shows four bottles '
      + 'and a jar in my hand. Please look at it again.',
    status: 'pending',
    createdAt: admin.firestore.Timestamp.fromDate(daysAgo(3)),
  });

  // ---- the ledger, and the wallets it implies ----
  //
  // Written last, and derived, so the two cannot disagree.
  const existing = await firestore.collection('transactions').get();
  const stale = existing.docs.filter((doc) =>
    String(doc.data().refId || '').startsWith('seed_'),
  );
  for (const doc of stale) await doc.ref.delete();

  for (const entry of ledger.entries) {
    await firestore.collection('transactions').add(entry);
  }

  for (const person of PEOPLE) {
    const uid = uids[person.key];
    await firestore.collection('users').doc(uid).set({
      name: person.name,
      email: person.email,
      role: person.role,
      status: 'active',
      createdAt: admin.firestore.Timestamp.fromDate(daysAgo(30)),
    });
    await firestore.collection('wallets').doc(uid).set({
      userId: uid,
      balance: ledger.balanceOf(uid),
      updatedAt: admin.firestore.Timestamp.fromDate(daysAgo(0)),
    });
  }

  // ---- counters, derived from what was actually written ----
  await firestore.collection('stats').doc('platform').set({
    disposalsApproved,
    disposalsRejected,
    claimsApproved,
    claimsRejected,
    pointsIssued: ledger.pointsIssued,
    pointsRedeemed: ledger.pointsRedeemed,
    ordersCreated,
    ordersConfirmed,
    salesPayable,
  });

  console.log('\nSeeded.');
  console.log(`  accounts   ${PEOPLE.length} (password from SEED_PASSWORD)`);
  console.log(`  bins       ${BINS.length}`);
  console.log(`  products   ${PRODUCTS.length}`);
  console.log(`  disposals  ${disposals.length}`);
  console.log(`  claims     ${claims.length}`);
  console.log(`  orders     ${orderPlans.length}`);
  console.log(`  ledger     ${ledger.entries.length} entries, `
    + `${ledger.pointsIssued} issued, ${ledger.pointsRedeemed} redeemed`);
  console.log('\nSign in as:');
  for (const person of PEOPLE) {
    console.log(`  ${person.role.padEnd(6)} ${person.email}`);
  }
  console.log(
    '\nOne order is already delivered and awaiting confirmation, so the spend '
      + 'loop can be closed on stage without waiting for a seller.',
  );
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error('\nSeed failed:', err.message);
    process.exit(1);
  });
