/**
 * Chokro — security rules tests for the marketplace (F4.x), appeals (F5.4) and
 * the dashboard counters (F5.1).
 *
 * Own `projectId`: suites sharing one run against the same emulator namespace in
 * parallel and clear each other's seed data mid-test.
 *
 * Two properties carry this file.
 *
 * 1. `products` is the one M3 collection a client genuinely writes, so every
 *    boundary on it is tested from the outside: another seller's listing, a
 *    buyer without the role, a suspended seller, an image URL pointing somewhere
 *    else, and the server-owned suspension flag.
 *
 * 2. `orders` is where points move, so no client may write one at all — an
 *    administrator included. That is the same guarantee `m2.rules.test.js`
 *    proves for wallets and disposals, extended to the spend path.
 */

const fs = require('fs');
const path = require('path');
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require('@firebase/rules-unit-testing');

const {
  setDoc,
  getDoc,
  updateDoc,
  deleteDoc,
  doc,
  serverTimestamp,
  setLogLevel,
} = require('firebase/firestore');

let testEnv;

const SELLER = 'seller_uid';
const SELLER2 = 'seller2_uid';
const BUYER = 'buyer_uid';
const ADMIN = 'admin_uid';

async function seedUser(uid, role, status = 'active', extra = {}) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'users', uid), {
      name: uid,
      email: `${uid}@test.com`,
      role,
      status,
      createdAt: new Date(),
      ...extra,
    });
  });
}

function imageUrl(uid, name = 'photo1') {
  return (
    'https://res.cloudinary.com/chokro-test/image/upload/v1/chokro/products/' +
    `${uid}/${name}.jpg`
  );
}

/** A listing satisfying every rule, so a failure names exactly one constraint. */
function validProduct(uid, overrides = {}) {
  return {
    sellerId: uid,
    shopName: 'Green Corner',
    title: 'Bamboo Toothbrush',
    titleLower: 'bamboo toothbrush',
    searchTokens: ['bamboo', 'toothbrush', 'personalcare'],
    description: 'A biodegradable brush with soft bristles.',
    category: 'personalCare',
    tags: ['eco-friendly'],
    price: 250,
    stock: 12,
    imageUrls: [imageUrl(uid)],
    active: true,
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    ...overrides,
  };
}

async function seedProduct(productId, uid, overrides = {}) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'products', productId), {
      ...validProduct(uid, overrides),
      createdAt: new Date(2026, 0, 1),
      updatedAt: new Date(2026, 0, 1),
    });
  });
}

async function seedOrder(orderId, extra = {}) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'orders', orderId), {
      buyerId: BUYER,
      buyerName: 'Buyer',
      sellerId: SELLER,
      sellerName: 'Seller',
      shopName: 'Green Corner',
      checkoutId: 'checkout_1',
      items: [{ productId: 'p1', title: 'Bamboo Toothbrush', unitPrice: 250, qty: 2 }],
      subtotal: 500,
      pointsApplied: 0,
      discount: 0,
      payable: 500,
      settlementMethod: 'cashOnDelivery',
      paymentStatus: 'pending',
      status: 'pending',
      createdAt: new Date(),
      ...extra,
    });
  });
}

async function seedRejectedDisposal(id, uid) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'disposals', id), {
      userId: uid,
      binId: 'bin_1',
      status: 'rejected',
      rejectionReason: 'The photograph did not show the declared items.',
      createdAt: new Date(),
    });
  });
}

async function seedRejectedClaim(id, uid) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'claims', id), {
      userId: uid,
      actionType: 'treePlanting',
      status: 'rejected',
      createdAt: new Date(),
    });
  });
}

function validAppeal(uid, subjectId, overrides = {}) {
  return {
    userId: uid,
    subjectType: 'disposal',
    subjectId,
    message: 'The photograph clearly shows six bottles beside the bin.',
    status: 'pending',
    createdAt: serverTimestamp(),
    ...overrides,
  };
}

function appealId(uid, subjectId, subjectType = 'disposal') {
  return `${uid}_${subjectType}_${subjectId}`;
}

beforeAll(async () => {
  setLogLevel('error');
  testEnv = await initializeTestEnvironment({
    projectId: 'chokro-rules-test-market',
    firestore: {
      rules: fs.readFileSync(path.resolve(__dirname, '../firestore.rules'), 'utf8'),
      host: '127.0.0.1',
      port: 8080,
    },
  });
});

afterAll(async () => {
  await testEnv.cleanup();
});

beforeEach(async () => {
  await testEnv.clearFirestore();
  await seedUser(ADMIN, 'admin');
  await seedUser(SELLER, 'seller');
  await seedUser(SELLER2, 'seller');
  await seedUser(BUYER, 'buyer');
});

// ---------------------------------------------------------------------------
// products (F4.1)
// ---------------------------------------------------------------------------

describe('creating a product', () => {
  it('a seller may create their own listing', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertSucceeds(setDoc(doc(db, 'products', 'p1'), validProduct(SELLER)));
  });

  it('an administrator may sell too, matching UserModel.isSeller', async () => {
    const db = testEnv.authenticatedContext(ADMIN).firestore();
    await assertSucceeds(setDoc(doc(db, 'products', 'p2'), validProduct(ADMIN)));
  });

  it('a buyer without the seller role may not list anything', async () => {
    const db = testEnv.authenticatedContext(BUYER).firestore();
    await assertFails(setDoc(doc(db, 'products', 'p3'), validProduct(BUYER)));
  });

  it('a seller may not list under another seller id', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(setDoc(doc(db, 'products', 'p4'), validProduct(SELLER2)));
  });

  it('a suspended seller may not list', async () => {
    await seedUser('susp_seller', 'seller', 'suspended');
    const db = testEnv.authenticatedContext('susp_seller').firestore();
    await assertFails(
      setDoc(doc(db, 'products', 'p5'), validProduct('susp_seller')),
    );
  });

  it('a seller whose timed suspension has lapsed may list again', async () => {
    // Nothing rewrites `status` back to active when the clock runs out (F5.3),
    // so the lapse has to resolve at request time or the account is barred
    // forever.
    const yesterday = new Date(Date.now() - 24 * 60 * 60 * 1000);
    await seedUser('lapsed_seller', 'seller', 'suspended', {
      suspendedUntil: yesterday,
    });
    const db = testEnv.authenticatedContext('lapsed_seller').firestore();
    await assertSucceeds(
      setDoc(doc(db, 'products', 'p6'), validProduct('lapsed_seller')),
    );
  });

  it('an anonymous caller may not list', async () => {
    const db = testEnv.unauthenticatedContext().firestore();
    await assertFails(setDoc(doc(db, 'products', 'p7'), validProduct(SELLER)));
  });

  it('the search index must describe the title buyers see', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(
      setDoc(
        doc(db, 'products', 'p8'),
        validProduct(SELLER, { titleLower: 'organic honey' }),
      ),
    );
  });

  it('every search token must be a bounded normalized string', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(
      setDoc(
        doc(db, 'products', 'bad_token_type'),
        validProduct(SELLER, { searchTokens: ['bamboo', { nested: true }] }),
      ),
    );
    await assertFails(
      setDoc(
        doc(db, 'products', 'bad_last_token'),
        validProduct(SELLER, {
          searchTokens: [
            ...Array.from({ length: 29 }, (_, i) => `token${i}`),
            'X'.repeat(200),
          ],
        }),
      ),
    );
  });

  it('every tag must be a bounded normalized string', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(
      setDoc(
        doc(db, 'products', 'bad_tag'),
        validProduct(SELLER, { tags: ['eco-friendly', 7] }),
      ),
    );
    await assertFails(
      setDoc(
        doc(db, 'products', 'bad_last_tag'),
        validProduct(SELLER, {
          tags: ['one', 'two', 'three', 'four', 'five', 'six', 'seven', 'x'.repeat(41)],
        }),
      ),
    );
  });

  it('an image outside the seller own folder is refused', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(
      setDoc(
        doc(db, 'products', 'p9'),
        validProduct(SELLER, { imageUrls: [imageUrl(SELLER2)] }),
      ),
    );
  });

  it('an image on an arbitrary host is refused', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(
      setDoc(
        doc(db, 'products', 'p10'),
        validProduct(SELLER, { imageUrls: ['https://example.com/tracker.jpg'] }),
      ),
    );
  });

  it('a bad image in the last slot is caught, not just the first', async () => {
    // Rules cannot iterate a list, so each slot is checked by index. This is the
    // test that fails if a slot is ever forgotten.
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(
      setDoc(
        doc(db, 'products', 'p11'),
        validProduct(SELLER, {
          imageUrls: [imageUrl(SELLER, 'a'), imageUrl(SELLER, 'b'), imageUrl(SELLER2, 'c')],
        }),
      ),
    );
  });

  it('more images than the rules can check are refused', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(
      setDoc(
        doc(db, 'products', 'p12'),
        validProduct(SELLER, {
          imageUrls: [
            imageUrl(SELLER, 'a'),
            imageUrl(SELLER, 'b'),
            imageUrl(SELLER, 'c'),
            imageUrl(SELLER, 'd'),
          ],
        }),
      ),
    );
  });

  it('a listing with no images is fine', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertSucceeds(
      setDoc(doc(db, 'products', 'p13'), validProduct(SELLER, { imageUrls: [] })),
    );
  });

  it('an invented category is refused', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(
      setDoc(
        doc(db, 'products', 'p14'),
        validProduct(SELLER, { category: 'groceries' }),
      ),
    );
  });

  it('a fractional price is refused — the economy is integer arithmetic', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(
      setDoc(doc(db, 'products', 'p15'), validProduct(SELLER, { price: 250.5 })),
    );
  });

  it('a zero or negative price is refused', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(
      setDoc(doc(db, 'products', 'p16'), validProduct(SELLER, { price: 0 })),
    );
    await assertFails(
      setDoc(doc(db, 'products', 'p17'), validProduct(SELLER, { price: -100 })),
    );
  });

  it('negative stock is refused', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(
      setDoc(doc(db, 'products', 'p18'), validProduct(SELLER, { stock: -1 })),
    );
  });

  it('a listing cannot arrive claiming a suspension hid it', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(
      setDoc(
        doc(db, 'products', 'p19'),
        validProduct(SELLER, { hiddenBySuspension: true }),
      ),
    );
  });

  it('an extra key is refused — hasOnly, not hasAll', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(
      setDoc(
        doc(db, 'products', 'p20'),
        validProduct(SELLER, { featured: true }),
      ),
    );
  });

  it('a client-authored createdAt is refused', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(
      setDoc(
        doc(db, 'products', 'p21'),
        validProduct(SELLER, { createdAt: new Date(2020, 0, 1) }),
      ),
    );
  });

  it('a token array beyond the bound is refused', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(
      setDoc(
        doc(db, 'products', 'p22'),
        validProduct(SELLER, {
          searchTokens: Array.from({ length: 31 }, (_, i) => `t${i}`),
        }),
      ),
    );
  });
});

describe('editing a product', () => {
  beforeEach(async () => {
    await seedProduct('owned', SELLER);
  });

  it('the owning seller may change price and stock', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertSucceeds(
      updateDoc(doc(db, 'products', 'owned'), {
        price: 300,
        stock: 5,
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('another seller may not touch it', async () => {
    const db = testEnv.authenticatedContext(SELLER2).firestore();
    await assertFails(
      updateDoc(doc(db, 'products', 'owned'), {
        price: 1,
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('an administrator may not edit somebody else listing either', async () => {
    // Not a payout rule — just ownership. An admin has moderation tools
    // (suspension) rather than an edit button on a stranger shop.
    const db = testEnv.authenticatedContext(ADMIN).firestore();
    await assertFails(
      updateDoc(doc(db, 'products', 'owned'), {
        price: 1,
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('the seller may not reassign the listing to someone else', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(
      updateDoc(doc(db, 'products', 'owned'), {
        sellerId: SELLER2,
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('the seller may not backdate the listing', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(
      updateDoc(doc(db, 'products', 'owned'), {
        createdAt: new Date(2020, 0, 1),
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('an edit must stamp the server clock', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(updateDoc(doc(db, 'products', 'owned'), { price: 300 }));
  });

  it('delisting is an update, and is how F4.1 deletes', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertSucceeds(
      updateDoc(doc(db, 'products', 'owned'), {
        active: false,
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('nobody may hard-delete a listing', async () => {
    const seller = testEnv.authenticatedContext(SELLER).firestore();
    const admin = testEnv.authenticatedContext(ADMIN).firestore();

    await assertFails(deleteDoc(doc(seller, 'products', 'owned')));
    await assertFails(deleteDoc(doc(admin, 'products', 'owned')));
  });

  it('a seller may not lift their own suspension hiding', async () => {
    // The server sets this when a suspension sweeps the catalogue. If a seller
    // could clear it, the sweep would be advisory.
    await seedProduct('hidden', SELLER, {
      active: false,
      hiddenBySuspension: true,
    });
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(
      updateDoc(doc(db, 'products', 'hidden'), {
        hiddenBySuspension: false,
        active: true,
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('a seller may still edit a listing the server has flagged', async () => {
    // hasOnly includes the flag so it survives in request.resource.data; the
    // affected-key set is what stops it changing. Without the first half, every
    // edit after a suspension would fail for no stated reason.
    await seedProduct('flagged', SELLER, {
      active: false,
      hiddenBySuspension: true,
    });
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertSucceeds(
      updateDoc(doc(db, 'products', 'flagged'), {
        price: 999,
        updatedAt: serverTimestamp(),
      }),
    );
  });
});

describe('reading products', () => {
  it('any signed-in user may browse', async () => {
    await seedProduct('p', SELLER);
    const db = testEnv.authenticatedContext(BUYER).firestore();
    await assertSucceeds(getDoc(doc(db, 'products', 'p')));
  });

  it('an anonymous visitor may not', async () => {
    await seedProduct('p', SELLER);
    const db = testEnv.unauthenticatedContext().firestore();
    await assertFails(getDoc(doc(db, 'products', 'p')));
  });
});

// ---------------------------------------------------------------------------
// carts (F4.3)
// ---------------------------------------------------------------------------

describe('carts', () => {
  const cart = (uid) => ({
    userId: uid,
    items: [{ productId: 'p1', qty: 2 }],
    updatedAt: serverTimestamp(),
  });

  it('a user may write their own cart', async () => {
    const db = testEnv.authenticatedContext(BUYER).firestore();
    await assertSucceeds(setDoc(doc(db, 'carts', BUYER), cart(BUYER)));
  });

  it('a user may not write somebody else cart', async () => {
    const db = testEnv.authenticatedContext(BUYER).firestore();
    await assertFails(setDoc(doc(db, 'carts', SELLER), cart(SELLER)));
  });

  it('a user may not read somebody else cart, admin included', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'carts', BUYER), {
        userId: BUYER,
        items: [],
        updatedAt: new Date(),
      });
    });

    const stranger = testEnv.authenticatedContext(SELLER).firestore();
    const admin = testEnv.authenticatedContext(ADMIN).firestore();

    await assertFails(getDoc(doc(stranger, 'carts', BUYER)));
    await assertFails(getDoc(doc(admin, 'carts', BUYER)));
  });

  it('a cart may not carry a cached total', async () => {
    // §6.2: the cart stores no prices. An extra key is refused outright, which
    // is what keeps a stale figure from becoming a quotation.
    const db = testEnv.authenticatedContext(BUYER).firestore();
    await assertFails(
      setDoc(doc(db, 'carts', BUYER), { ...cart(BUYER), subtotal: 1 }),
    );
  });

  it('a cart item may carry only a product id and whole bounded quantity', async () => {
    const db = testEnv.authenticatedContext(BUYER).firestore();
    for (const item of [
      { productId: 'p1', qty: 1, unitPrice: 1 },
      { productId: 'p1', qty: 1.5 },
      { productId: 'p1', qty: 0 },
      { productId: 'p1', qty: 21 },
      { productId: 'x'.repeat(129), qty: 1 },
    ]) {
      await assertFails(
        setDoc(doc(db, 'carts', BUYER), { ...cart(BUYER), items: [item] }),
      );
    }
  });

  it('validates the final slot of a full cart', async () => {
    const db = testEnv.authenticatedContext(BUYER).firestore();
    const items = Array.from({ length: 20 }, (_, i) => ({
      productId: `p${i}`,
      qty: 1,
    }));
    items[19] = { productId: 'p19', qty: 0 };
    await assertFails(
      setDoc(doc(db, 'carts', BUYER), { ...cart(BUYER), items }),
    );
  });

  it('a cart beyond the item ceiling is refused', async () => {
    const db = testEnv.authenticatedContext(BUYER).firestore();
    await assertFails(
      setDoc(doc(db, 'carts', BUYER), {
        ...cart(BUYER),
        items: Array.from({ length: 21 }, (_, i) => ({ productId: `p${i}`, qty: 1 })),
      }),
    );
  });

  it('a suspended user may not fill a cart', async () => {
    await seedUser('susp_buyer', 'buyer', 'suspended');
    const db = testEnv.authenticatedContext('susp_buyer').firestore();
    await assertFails(
      setDoc(doc(db, 'carts', 'susp_buyer'), cart('susp_buyer')),
    );
  });

  it('a client-authored updatedAt is refused', async () => {
    const db = testEnv.authenticatedContext(BUYER).firestore();
    await assertFails(
      setDoc(doc(db, 'carts', BUYER), {
        ...cart(BUYER),
        updatedAt: new Date(2020, 0, 1),
      }),
    );
  });

  it('a user may empty their own cart', async () => {
    const db = testEnv.authenticatedContext(BUYER).firestore();
    await setDoc(doc(db, 'carts', BUYER), cart(BUYER));
    await assertSucceeds(deleteDoc(doc(db, 'carts', BUYER)));
  });
});

// ---------------------------------------------------------------------------
// orders (F4.4, F4.6, F4.7) — the spend path's payout boundary
// ---------------------------------------------------------------------------

describe('orders are server-owned end to end', () => {
  beforeEach(async () => {
    await seedOrder('o1');
  });

  it('the buyer may read their own order', async () => {
    const db = testEnv.authenticatedContext(BUYER).firestore();
    await assertSucceeds(getDoc(doc(db, 'orders', 'o1')));
  });

  it('the seller may read the order they must fulfil', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertSucceeds(getDoc(doc(db, 'orders', 'o1')));
  });

  it('an administrator may read any order', async () => {
    const db = testEnv.authenticatedContext(ADMIN).firestore();
    await assertSucceeds(getDoc(doc(db, 'orders', 'o1')));
  });

  it('an unrelated user may not read it', async () => {
    const db = testEnv.authenticatedContext(SELLER2).firestore();
    await assertFails(getDoc(doc(db, 'orders', 'o1')));
  });

  it('a buyer may not create an order — checkout is the server', async () => {
    const db = testEnv.authenticatedContext(BUYER).firestore();
    await assertFails(
      setDoc(doc(db, 'orders', 'forged'), {
        buyerId: BUYER,
        sellerId: SELLER,
        subtotal: 0,
        payable: 0,
        status: 'confirmed',
        pointsAwarded: 99999,
        createdAt: serverTimestamp(),
      }),
    );
  });

  it('the seller may not advance the status from the client', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(
      updateDoc(doc(db, 'orders', 'o1'), { status: 'shipped' }),
    );
  });

  it('THE ONE THAT MATTERS: the buyer cannot confirm and self-credit', async () => {
    // `confirmed` is the transition that credits a wallet (F4.7). A rule that
    // let the buyer write it would be a rule that let a client trigger a payout.
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await updateDoc(doc(ctx.firestore(), 'orders', 'o1'), {
        status: 'delivered',
      });
    });

    const db = testEnv.authenticatedContext(BUYER).firestore();
    await assertFails(
      updateDoc(doc(db, 'orders', 'o1'), {
        status: 'confirmed',
        pointsAwarded: 5000,
      }),
    );
  });

  it('an administrator cannot write an order either', async () => {
    const db = testEnv.authenticatedContext(ADMIN).firestore();
    await assertFails(updateDoc(doc(db, 'orders', 'o1'), { status: 'confirmed' }));
    await assertFails(deleteDoc(doc(db, 'orders', 'o1')));
  });
});

// ---------------------------------------------------------------------------
// appeals (F5.4)
// ---------------------------------------------------------------------------

describe('raising an appeal', () => {
  beforeEach(async () => {
    await seedRejectedDisposal('d_rejected', BUYER);
  });

  it('a user may appeal their own rejected disposal', async () => {
    const db = testEnv.authenticatedContext(BUYER).firestore();
    await assertSucceeds(
      setDoc(
        doc(db, 'appeals', appealId(BUYER, 'd_rejected')),
        validAppeal(BUYER, 'd_rejected'),
      ),
    );
  });

  it('a user may appeal their own rejected claim', async () => {
    await seedRejectedClaim('c_rejected', BUYER);
    const db = testEnv.authenticatedContext(BUYER).firestore();
    await assertSucceeds(
      setDoc(
        doc(db, 'appeals', appealId(BUYER, 'c_rejected', 'claim')),
        validAppeal(BUYER, 'c_rejected', { subjectType: 'claim' }),
      ),
    );
  });

  it('a user may not appeal somebody else rejection', async () => {
    const db = testEnv.authenticatedContext(SELLER).firestore();
    await assertFails(
      setDoc(
        doc(db, 'appeals', appealId(SELLER, 'd_rejected')),
        validAppeal(SELLER, 'd_rejected'),
      ),
    );
  });

  it('a user may not appeal a submission that was not rejected', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'disposals', 'd_approved'), {
        userId: BUYER,
        binId: 'bin_1',
        status: 'autoApproved',
        createdAt: new Date(),
      });
    });

    const db = testEnv.authenticatedContext(BUYER).firestore();
    await assertFails(
      setDoc(
        doc(db, 'appeals', appealId(BUYER, 'd_approved')),
        validAppeal(BUYER, 'd_approved'),
      ),
    );
  });

  it('a user may not appeal a submission that does not exist', async () => {
    const db = testEnv.authenticatedContext(BUYER).firestore();
    await assertFails(
      setDoc(
        doc(db, 'appeals', appealId(BUYER, 'no_such_disposal')),
        validAppeal(BUYER, 'no_such_disposal'),
      ),
    );
  });

  it('an appeal cannot arrive already upheld', async () => {
    const db = testEnv.authenticatedContext(BUYER).firestore();
    await assertFails(
      setDoc(
        doc(db, 'appeals', appealId(BUYER, 'd_rejected')),
        validAppeal(BUYER, 'd_rejected', { status: 'upheld' }),
      ),
    );
  });

  it('an appeal cannot arrive carrying its own answer', async () => {
    const db = testEnv.authenticatedContext(BUYER).firestore();
    await assertFails(
      setDoc(
        doc(db, 'appeals', appealId(BUYER, 'd_rejected')),
        validAppeal(BUYER, 'd_rejected', {
          response: 'Reviewed and accepted.',
          reviewedBy: ADMIN,
        }),
      ),
    );
  });

  it('a one-word appeal is refused', async () => {
    const db = testEnv.authenticatedContext(BUYER).firestore();
    await assertFails(
      setDoc(
        doc(db, 'appeals', appealId(BUYER, 'd_rejected')),
        validAppeal(BUYER, 'd_rejected', { message: 'unfair' }),
      ),
    );
  });

  it('a suspended user may appeal their own rejection', async () => {
    await seedUser('susp', 'buyer', 'suspended');
    await seedRejectedDisposal('d_susp', 'susp');
    const db = testEnv.authenticatedContext('susp').firestore();
    await assertSucceeds(
      setDoc(
        doc(db, 'appeals', appealId('susp', 'd_susp')),
        validAppeal('susp', 'd_susp'),
      ),
    );
  });

  it('a user cannot raise a second appeal for the same rejection', async () => {
    const db = testEnv.authenticatedContext(BUYER).firestore();
    const ref = doc(db, 'appeals', appealId(BUYER, 'd_rejected'));
    await assertSucceeds(setDoc(ref, validAppeal(BUYER, 'd_rejected')));
    await assertFails(
      setDoc(
        ref,
        validAppeal(BUYER, 'd_rejected', {
          message: 'I am submitting another explanation for the same decision.',
        }),
      ),
    );
  });
});

describe('resolving an appeal', () => {
  beforeEach(async () => {
    await seedRejectedDisposal('d_rejected', BUYER);
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'appeals', 'a1'), {
        userId: BUYER,
        subjectType: 'disposal',
        subjectId: 'd_rejected',
        message: 'The photograph clearly shows six bottles beside the bin.',
        status: 'pending',
        createdAt: new Date(),
      });
    });
  });

  it('an administrator may uphold with a written answer', async () => {
    const db = testEnv.authenticatedContext(ADMIN).firestore();
    await assertSucceeds(
      updateDoc(doc(db, 'appeals', 'a1'), {
        status: 'upheld',
        response: 'You are right — please submit again at the same bin.',
        reviewedBy: ADMIN,
        reviewedAt: serverTimestamp(),
      }),
    );
  });

  it('an administrator may not resolve without saying anything', async () => {
    const db = testEnv.authenticatedContext(ADMIN).firestore();
    await assertFails(
      updateDoc(doc(db, 'appeals', 'a1'), {
        status: 'declined',
        reviewedBy: ADMIN,
        reviewedAt: serverTimestamp(),
      }),
    );
  });

  it('the appellant may not resolve their own appeal', async () => {
    const db = testEnv.authenticatedContext(BUYER).firestore();
    await assertFails(
      updateDoc(doc(db, 'appeals', 'a1'), {
        status: 'upheld',
        response: 'I have decided in my own favour.',
        reviewedBy: BUYER,
        reviewedAt: serverTimestamp(),
      }),
    );
  });

  it('an administrator may not attribute the decision to someone else', async () => {
    const db = testEnv.authenticatedContext(ADMIN).firestore();
    await assertFails(
      updateDoc(doc(db, 'appeals', 'a1'), {
        status: 'declined',
        response: 'The distance check was decisive.',
        reviewedBy: 'someone_else',
        reviewedAt: serverTimestamp(),
      }),
    );
  });

  it('an answered appeal cannot be revisited', async () => {
    const db = testEnv.authenticatedContext(ADMIN).firestore();
    await updateDoc(doc(db, 'appeals', 'a1'), {
      status: 'declined',
      response: 'The distance check was decisive.',
      reviewedBy: ADMIN,
      reviewedAt: serverTimestamp(),
    });

    await assertFails(
      updateDoc(doc(db, 'appeals', 'a1'), {
        status: 'upheld',
        response: 'Changed my mind.',
        reviewedBy: ADMIN,
        reviewedAt: serverTimestamp(),
      }),
    );
  });

  it('resolving cannot rewrite the case the user made', async () => {
    const db = testEnv.authenticatedContext(ADMIN).firestore();
    await assertFails(
      updateDoc(doc(db, 'appeals', 'a1'), {
        status: 'declined',
        response: 'The distance check was decisive.',
        reviewedBy: ADMIN,
        reviewedAt: serverTimestamp(),
        message: 'I admit I made this up.',
      }),
    );
  });

  it('the appellant may read their own appeal, a stranger may not', async () => {
    const owner = testEnv.authenticatedContext(BUYER).firestore();
    const stranger = testEnv.authenticatedContext(SELLER).firestore();

    await assertSucceeds(getDoc(doc(owner, 'appeals', 'a1')));
    await assertFails(getDoc(doc(stranger, 'appeals', 'a1')));
  });

  it('nobody may delete an appeal', async () => {
    const db = testEnv.authenticatedContext(ADMIN).firestore();
    await assertFails(deleteDoc(doc(db, 'appeals', 'a1')));
  });
});

// ---------------------------------------------------------------------------
// stats (F5.1)
// ---------------------------------------------------------------------------

describe('dashboard counters', () => {
  beforeEach(async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'stats', 'platform'), {
        disposalsApproved: 4,
        pointsIssued: 200,
      });
    });
  });

  it('an administrator may read them', async () => {
    const db = testEnv.authenticatedContext(ADMIN).firestore();
    await assertSucceeds(getDoc(doc(db, 'stats', 'platform')));
  });

  it('an ordinary user may not', async () => {
    const db = testEnv.authenticatedContext(BUYER).firestore();
    await assertFails(getDoc(doc(db, 'stats', 'platform')));
  });

  it('nobody may write them, administrator included', async () => {
    const db = testEnv.authenticatedContext(ADMIN).firestore();
    await assertFails(
      updateDoc(doc(db, 'stats', 'platform'), { pointsIssued: 0 }),
    );
    await assertFails(deleteDoc(doc(db, 'stats', 'platform')));
  });
});
