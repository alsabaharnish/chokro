const {
  committedVerificationOutcome,
  persistReviewEvidence,
} = require('../src/verify');

function fakeTransaction(latest) {
  const update = jest.fn();
  const txn = {
    get: jest.fn().mockResolvedValue({
      exists: latest !== undefined,
      data: () => latest,
    }),
    update,
  };
  return {
    txn,
    update,
    firestore: { runTransaction: (body) => body(txn) },
  };
}

const disposalRef = { path: 'disposals/d1' };
const evidence = {
  verificationCompleted: true,
  flags: ['lowConfidence'],
  photoHash: 'abcd',
};

describe('review-evidence persistence race', () => {
  test('stores evidence when the submission is still pending and untouched', async () => {
    const fake = fakeTransaction({ userId: 'u1', status: 'pending' });

    await expect(
      persistReviewEvidence({
        firestore: fake.firestore,
        disposalRef,
        callerUid: 'u1',
        evidence,
      }),
    ).resolves.toEqual({ state: 'stored', disposal: null });

    expect(fake.update).toHaveBeenCalledWith(disposalRef, evidence);
  });

  test('does not overwrite an administrator decision that won the race', async () => {
    const decided = {
      userId: 'u1',
      status: 'rejected',
      flags: ['photoUntrusted'],
    };
    const fake = fakeTransaction(decided);

    await expect(
      persistReviewEvidence({
        firestore: fake.firestore,
        disposalRef,
        callerUid: 'u1',
        evidence,
      }),
    ).resolves.toEqual({ state: 'decided', disposal: decided });

    expect(fake.update).not.toHaveBeenCalled();
  });

  test('does not overwrite evidence written by another verify request', async () => {
    const verified = {
      userId: 'u1',
      status: 'pending',
      verificationCompleted: true,
      flags: ['outsideRadius'],
    };
    const fake = fakeTransaction(verified);

    await expect(
      persistReviewEvidence({
        firestore: fake.firestore,
        disposalRef,
        callerUid: 'u1',
        evidence,
      }),
    ).resolves.toEqual({ state: 'verified', disposal: verified });

    expect(fake.update).not.toHaveBeenCalled();
  });

  test('re-checks ownership before the final evidence write', async () => {
    const fake = fakeTransaction({ userId: 'someone_else', status: 'pending' });

    await expect(
      persistReviewEvidence({
        firestore: fake.firestore,
        disposalRef,
        callerUid: 'u1',
        evidence,
      }),
    ).rejects.toThrow(/belongs to someone else/i);
    expect(fake.update).not.toHaveBeenCalled();
  });
});

describe('automatic-award race recovery', () => {
  function latestRef(latest) {
    return {
      get: jest.fn().mockResolvedValue({
        exists: latest !== undefined,
        data: () => latest,
      }),
    };
  }

  test('returns a decision that committed while screening was in flight', async () => {
    const ref = latestRef({
      userId: 'u1',
      status: 'autoApproved',
      pointsAwarded: 50,
      flags: [],
    });

    await expect(
      committedVerificationOutcome({
        disposalId: 'd1',
        callerUid: 'u1',
        disposalRef: ref,
      }),
    ).resolves.toMatchObject({
      status: 'autoApproved',
      alreadyDecided: true,
      pointsAwarded: 50,
    });
  });

  test('returns the first flagged result instead of overwriting it', async () => {
    const ref = latestRef({
      userId: 'u1',
      status: 'pending',
      verificationCompleted: true,
      photoHash: 'winner',
      flags: ['lowConfidence'],
    });

    await expect(
      committedVerificationOutcome({
        disposalId: 'd1',
        callerUid: 'u1',
        disposalRef: ref,
      }),
    ).resolves.toMatchObject({
      status: 'pending',
      alreadyVerified: true,
      flags: ['lowConfidence'],
    });
  });

  test('does not hide an award failure when nothing else committed', async () => {
    const ref = latestRef({ userId: 'u1', status: 'pending' });

    await expect(
      committedVerificationOutcome({
        disposalId: 'd1',
        callerUid: 'u1',
        disposalRef: ref,
      }),
    ).resolves.toBeNull();
  });
});
