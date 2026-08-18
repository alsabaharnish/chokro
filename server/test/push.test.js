/**
 * Unit tests for the push message composers (F7.1).
 *
 * Pure functions only — no Firebase, no network, no emulator. Per §9 of the
 * brief, the logic that can be tested without I/O is written and tested first,
 * and the parts that cannot (`sendToUser`, `tokensFor`) are kept deliberately
 * thin so there is little left in them to be wrong.
 *
 * What these prove, in order of how much they matter:
 *
 *   1. The two approved states stay distinguishable in the copy. §6.1 keeps
 *      autoApproved and manualApproved separate precisely so the system can
 *      answer "was this checked by a person?", and the notification is where a
 *      user is given that answer.
 *   2. A rejection always carries its reason, truncated to something a lock
 *      screen can show.
 *   3. Every value in a data payload is a string. FCM rejects the entire message
 *      otherwise, and it fails at send time on a real device rather than here.
 *   4. `screenNotes` never reaches a user.
 */

const push = require('../src/push');

describe('truncate', () => {
  test('leaves a short reason alone', () => {
    expect(push.truncate('Photo shows an empty pavement.')).toBe(
      'Photo shows an empty pavement.',
    );
  });

  test('collapses whitespace so a multi-line reason reads as one line', () => {
    expect(push.truncate('Photo shows\n\n  an empty   pavement.')).toBe(
      'Photo shows an empty pavement.',
    );
  });

  test('cuts an over-long reason to the limit, ellipsis included', () => {
    const long = 'x'.repeat(500);
    const result = push.truncate(long);
    expect(result).toHaveLength(push.MAX_BODY_CHARS);
    expect(result.endsWith('…')).toBe(true);
  });

  test('survives null and undefined rather than printing "null"', () => {
    expect(push.truncate(null)).toBe('');
    expect(push.truncate(undefined)).toBe('');
  });
});

describe('disposal approval messages', () => {
  test('an automatic approval says so, and names the award', () => {
    const message = push.disposalApprovedMessage({
      pointsAwarded: 50,
      status: 'autoApproved',
    });

    expect(message.body).toContain('50 points added');
    expect(message.body).toContain('automatically');
    expect(message.data.status).toBe('autoApproved');
  });

  test('a manual approval tells the user a person verified it', () => {
    // This is the assertion that carries §6.1. If both statuses produced the
    // same sentence there would be no point keeping them as separate states.
    const message = push.disposalApprovedMessage({
      pointsAwarded: 50,
      status: 'manualApproved',
    });

    expect(message.body).toMatch(/administrator|verified/i);
    expect(message.body).not.toContain('automatically');
    expect(message.data.status).toBe('manualApproved');
  });

  test('the two approved states never produce identical copy', () => {
    const auto = push.disposalApprovedMessage({
      pointsAwarded: 50,
      status: 'autoApproved',
    });
    const manual = push.disposalApprovedMessage({
      pointsAwarded: 50,
      status: 'manualApproved',
    });

    expect(auto.body).not.toBe(manual.body);
    expect(auto.title).not.toBe(manual.title);
  });

  test('the award snapshot is carried through, not re-derived', () => {
    // An administrator lowering the disposal award must not change what a past
    // submission was worth (§6.2). The message echoes whatever the transaction
    // recorded.
    const message = push.disposalApprovedMessage({
      pointsAwarded: 35,
      status: 'autoApproved',
    });

    expect(message.body).toContain('35');
    expect(message.data.pointsAwarded).toBe('35');
  });
});

describe('disposal rejection messages', () => {
  test('the reason is the body', () => {
    const message = push.disposalRejectedMessage({
      reason: 'The photograph does not show waste at the bin.',
    });

    expect(message.body).toBe('The photograph does not show waste at the bin.');
    expect(message.data.status).toBe('rejected');
    expect(message.data.pointsAwarded).toBe('0');
  });

  test('a long reason is truncated rather than dropped', () => {
    const message = push.disposalRejectedMessage({ reason: 'y'.repeat(400) });
    expect(message.body).toHaveLength(push.MAX_BODY_CHARS);
  });
});

describe('claim messages', () => {
  test('an approved claim names its award', () => {
    const message = push.claimApprovedMessage({ pointsAwarded: 15 });
    expect(message.body).toContain('15 points added');
    expect(message.data.kind).toBe('claimDecision');
  });

  test('a rejected claim carries its reason', () => {
    const message = push.claimRejectedMessage({
      reason: 'This photo was submitted last week.',
    });
    expect(message.body).toBe('This photo was submitted last week.');
    expect(message.data.pointsAwarded).toBe('0');
  });
});

describe('data payload shape', () => {
  const all = [
    push.disposalApprovedMessage({ pointsAwarded: 50, status: 'autoApproved' }),
    push.disposalApprovedMessage({ pointsAwarded: 50, status: 'manualApproved' }),
    push.disposalRejectedMessage({ reason: 'No.' }),
    push.claimApprovedMessage({ pointsAwarded: 15 }),
    push.claimRejectedMessage({ reason: 'No.' }),
  ];

  test('every data value is a string', () => {
    // FCM rejects the whole message if any data value is a number or a boolean,
    // and it does so at send time on a real device. Catching it here is the
    // difference between a failing test and a demo where nothing arrives.
    for (const message of all) {
      for (const [key, value] of Object.entries(message.data)) {
        expect(typeof value).toBe('string');
        expect(key).not.toBe('');
      }
    }
  });

  test('every message carries a title and a non-empty body', () => {
    for (const message of all) {
      expect(typeof message.title).toBe('string');
      expect(message.title.length).toBeGreaterThan(0);
      expect(typeof message.body).toBe('string');
      expect(message.body.length).toBeGreaterThan(0);
    }
  });

  test('every route is one the client will accept', () => {
    // routeForMessage in push_controller.dart refuses anything outside this set
    // rather than handing an arbitrary string to go_router, which would render
    // the route-error screen. The two lists have to agree.
    const known = ['/history', '/wallet', '/home', '/claims'];
    for (const message of all) {
      expect(known).toContain(message.data.route);
    }
  });

  test('screening notes never reach a user', () => {
    // screenNotes is admin-only (§6.1): it describes what the screen looked for,
    // and showing it would teach a user how to defeat it.
    for (const message of all) {
      expect(Object.keys(message.data)).not.toContain('screenNotes');
      expect(message.body).not.toMatch(/screenNotes/);
    }
  });
});

describe('dead-token classification', () => {
  test('permanent failures are pruned', () => {
    expect(
      push.DEAD_TOKEN_CODES.has('messaging/registration-token-not-registered'),
    ).toBe(true);
    expect(
      push.DEAD_TOKEN_CODES.has('messaging/invalid-registration-token'),
    ).toBe(true);
  });

  test('transient failures are not', () => {
    // Deleting a token on a network blip or a quota error would silently
    // unsubscribe a working device, and nothing would ever report it.
    expect(push.DEAD_TOKEN_CODES.has('messaging/server-unavailable')).toBe(false);
    expect(push.DEAD_TOKEN_CODES.has('messaging/internal-error')).toBe(false);
    expect(push.DEAD_TOKEN_CODES.has('messaging/quota-exceeded')).toBe(false);
  });
});

describe('sendToUser contract', () => {
  test('a missing uid is skipped, not thrown', () => {
    // The whole module's contract: a push failure must never turn a committed
    // award into a failed request.
    return expect(
      push.sendToUser({ uid: null, message: { title: 't', body: 'b', data: {} } }),
    ).resolves.toEqual({ sent: 0, failed: 0, skipped: true });
  });
});
