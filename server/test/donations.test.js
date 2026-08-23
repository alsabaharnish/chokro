jest.mock('../src/firebase', () => {
  const increment = (n) => ({ __increment: n });
  return {
    db: jest.fn(),
    serverTimestamp: () => ({ __serverTimestamp: true }),
    admin: { firestore: { FieldValue: { increment } } },
  };
});

jest.mock('../src/push', () => ({}));

const firebase = require('../src/firebase');
const {
  DonationError,
  donatePoints,
  donatePrototypePayment,
  validateDonation,
  validatePrototypeDonation,
} = require('../src/donations');

function fakeFirestore(seed = {}) {
  const writes = [];
  let autoId = 0;

  const ref = (path) => ({ path, id: path.split('/').pop() });
  const txn = {
    get: async (target) => {
      const data = seed[target.path];
      return {
        exists: data !== undefined,
        data: () => data,
        ref: target,
      };
    },
    set: (target, data, options) =>
      writes.push({ op: 'set', path: target.path, data, options }),
    update: (target, data) =>
      writes.push({ op: 'update', path: target.path, data }),
  };
  const firestore = {
    collection: (name) => ({
      doc: (id) => ref(`${name}/${id ?? `auto_${(autoId += 1)}`}`),
    }),
    runTransaction: async (body) => body(txn),
  };
  firebase.db.mockReturnValue(firestore);

  return {
    writes,
    writesTo: (prefix) => writes.filter((write) => write.path.startsWith(prefix)),
  };
}

const request = {
  uid: 'champion_1',
  donationId: 'dn_request_12345',
  initiative: 'treePlanting',
  points: 100,
};

const prototypeRequest = {
  uid: 'champion_1',
  donationId: 'pdn_request_12345',
  initiative: 'wasteRecovery',
  amountTaka: 500,
  settlementMethod: 'prototypeBkash',
};

beforeEach(() => jest.clearAllMocks());

describe('donation validation', () => {
  it('accepts a supported initiative and whole-point amount', () => {
    expect(() => validateDonation(request)).not.toThrow();
  });

  it.each([
    [{ ...request, points: 0 }, 'invalid_points'],
    [{ ...request, points: 10.5 }, 'invalid_points'],
    [{ ...request, initiative: 'anything' }, 'invalid_initiative'],
    [{ ...request, donationId: '../wallets/user' }, 'invalid_donation_id'],
  ])('rejects malformed requests', (candidate, code) => {
    expect.assertions(2);
    try {
      validateDonation(candidate);
    } catch (error) {
      expect(error).toBeInstanceOf(DonationError);
      expect(error.code).toBe(code);
    }
  });
});

describe('donatePoints', () => {
  it('moves the wallet, ledger, receipt and stats in one transaction', async () => {
    const fake = fakeFirestore({ 'wallets/champion_1': { balance: 350 } });

    const result = await donatePoints(request);

    expect(result).toEqual({
      donationId: request.donationId,
      initiative: request.initiative,
      points: 100,
      balanceAfter: 250,
      repeated: false,
    });
    expect(fake.writesTo('wallets/champion_1')).toHaveLength(1);
    expect(fake.writesTo('wallets/champion_1')[0].data.balance).toBe(250);

    const ledger = fake.writesTo('transactions/');
    expect(ledger).toHaveLength(1);
    expect(ledger[0].data).toMatchObject({
      userId: 'champion_1',
      delta: -100,
      source: 'donation',
      refId: request.donationId,
      balanceAfter: 250,
    });

    expect(
      fake.writesTo(`donations/${request.uid}_${request.donationId}`)[0].data,
    ).toMatchObject({
      userId: 'champion_1',
      initiative: 'treePlanting',
      points: 100,
      balanceAfter: 250,
      status: 'received',
    });
    expect(fake.writesTo('stats/platform')[0].data).toEqual({
      pointsDonated: { __increment: 100 },
      donationsReceived: { __increment: 1 },
    });
  });

  it('refuses an overdraft without writing anything', async () => {
    const fake = fakeFirestore({ 'wallets/champion_1': { balance: 99 } });

    await expect(donatePoints(request)).rejects.toMatchObject({
      code: 'insufficient_points',
      status: 409,
    });
    expect(fake.writes).toHaveLength(0);
  });

  it('returns an identical existing receipt without a second debit', async () => {
    const fake = fakeFirestore({
      [`donations/${request.uid}_${request.donationId}`]: {
        userId: 'champion_1',
        initiative: 'treePlanting',
        points: 100,
        balanceAfter: 250,
      },
      'wallets/champion_1': { balance: 250 },
    });

    await expect(donatePoints(request)).resolves.toMatchObject({
      repeated: true,
      balanceAfter: 250,
    });
    expect(fake.writes).toHaveLength(0);
  });

  it('does not let an idempotency key be reused for another amount', async () => {
    const fake = fakeFirestore({
      [`donations/${request.uid}_${request.donationId}`]: {
        userId: 'champion_1',
        initiative: 'treePlanting',
        points: 50,
        balanceAfter: 300,
      },
    });

    await expect(donatePoints(request)).rejects.toMatchObject({
      code: 'donation_id_conflict',
      status: 409,
    });
    expect(fake.writes).toHaveLength(0);
  });
});

describe('prototype online donations', () => {
  it('accepts only bounded amounts and prototype methods', () => {
    expect(() => validatePrototypeDonation(prototypeRequest)).not.toThrow();
    expect(() =>
      validatePrototypeDonation({
        ...prototypeRequest,
        settlementMethod: 'cashOnDelivery',
      }),
    ).toThrow(expect.objectContaining({ code: 'invalid_settlement_method' }));
    expect(() =>
      validatePrototypeDonation({ ...prototypeRequest, amountTaka: 10.5 }),
    ).toThrow(expect.objectContaining({ code: 'invalid_amount' }));
  });

  it('writes a labelled receipt and prototype-only counters', async () => {
    const fake = fakeFirestore();

    const result = await donatePrototypePayment(prototypeRequest);

    expect(result).toMatchObject({
      donationId: prototypeRequest.donationId,
      initiative: 'wasteRecovery',
      amountTaka: 500,
      settlementMethod: 'prototypeBkash',
      paymentStatus: 'paid',
      paymentPrototype: true,
      repeated: false,
    });
    expect(result.paymentReference).toMatch(/^SIM-DON-BKASH-/);
    expect(
      fake.writesTo(
        `donations/${prototypeRequest.uid}_${prototypeRequest.donationId}`,
      )[0].data,
    ).toMatchObject({
      kind: 'prototypeOnline',
      userId: 'champion_1',
      amountTaka: 500,
      paymentStatus: 'paid',
      paymentPrototype: true,
    });
    expect(fake.writesTo('wallets/')).toHaveLength(0);
    expect(fake.writesTo('transactions/')).toHaveLength(0);
    expect(fake.writesTo('stats/platform')[0].data).toEqual({
      prototypeDonationTaka: { __increment: 500 },
      prototypeDonationsReceived: { __increment: 1 },
    });
  });

  it('returns the same receipt on an identical retry', async () => {
    const existing = {
      kind: 'prototypeOnline',
      userId: 'champion_1',
      initiative: 'wasteRecovery',
      amountTaka: 500,
      settlementMethod: 'prototypeBkash',
      paymentStatus: 'paid',
      paymentPrototype: true,
      paymentReference: 'SIM-DON-BKASH-EXISTING',
    };
    const fake = fakeFirestore({
      [`donations/${prototypeRequest.uid}_${prototypeRequest.donationId}`]:
        existing,
    });

    await expect(donatePrototypePayment(prototypeRequest)).resolves.toMatchObject({
      repeated: true,
      paymentReference: existing.paymentReference,
    });
    expect(fake.writes).toHaveLength(0);
  });

  it('rejects reuse of the key for a point donation or another amount', async () => {
    const fake = fakeFirestore({
      [`donations/${prototypeRequest.uid}_${prototypeRequest.donationId}`]: {
        kind: 'points',
        userId: 'champion_1',
        initiative: 'wasteRecovery',
        points: 500,
      },
    });

    await expect(donatePrototypePayment(prototypeRequest)).rejects.toMatchObject({
      code: 'donation_id_conflict',
      status: 409,
    });
    expect(fake.writes).toHaveLength(0);
  });
});
