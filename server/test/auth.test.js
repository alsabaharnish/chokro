jest.mock('../src/firebase', () => ({
  auth: jest.fn(),
  db: jest.fn(),
}));

const firebase = require('../src/firebase');
const { requireAuth } = require('../src/auth');

function request(header = 'Bearer valid-token') {
  return { get: jest.fn(() => header) };
}

function response() {
  const res = {
    status: jest.fn(),
    json: jest.fn(),
  };
  res.status.mockReturnValue(res);
  res.json.mockReturnValue(res);
  return res;
}

describe('requireAuth failure responses', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    firebase.auth.mockReturnValue({
      verifyIdToken: jest.fn().mockResolvedValue({ uid: 'user_1' }),
    });
  });

  test('a Firestore profile outage returns a retryable 503', async () => {
    firebase.db.mockReturnValue({
      collection: () => ({
        doc: () => ({
          get: jest.fn().mockRejectedValue(new Error('upstream unavailable')),
        }),
      }),
    });

    const res = response();
    const next = jest.fn();
    const errorSpy = jest.spyOn(console, 'error').mockImplementation(() => {});

    await requireAuth(request(), res, next);

    expect(res.status).toHaveBeenCalledWith(503);
    expect(res.json).toHaveBeenCalledWith({
      error: 'account_service_unavailable',
      message: 'The account service is temporarily unavailable. Try again.',
    });
    expect(next).not.toHaveBeenCalled();
    errorSpy.mockRestore();
  });

  test('a missing token is a 401 and does not touch Firebase', async () => {
    const res = response();
    await requireAuth(request(''), res, jest.fn());
    expect(res.status).toHaveBeenCalledWith(401);
    expect(firebase.auth).not.toHaveBeenCalled();
    expect(firebase.db).not.toHaveBeenCalled();
  });
});
