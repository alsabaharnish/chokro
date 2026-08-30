const { requestBodyErrorResponse } = require('../src/httpErrors');

describe('request body error responses', () => {
  test('malformed JSON is a client error with no parser detail leaked', () => {
    const response = requestBodyErrorResponse({
      type: 'entity.parse.failed',
      message: 'Unexpected token s in {"secret":"value"}',
    });

    expect(response).toEqual({
      status: 400,
      error: 'invalid_json',
      message: 'The request body is not valid JSON.',
    });
    expect(JSON.stringify(response)).not.toContain('secret');
  });

  test('an oversized body keeps its 413 semantics', () => {
    expect(requestBodyErrorResponse({ type: 'entity.too.large' })).toEqual({
      status: 413,
      error: 'payload_too_large',
      message: 'The request body is too large.',
    });
  });

  test('unsupported encodings return 415', () => {
    for (const type of ['charset.unsupported', 'encoding.unsupported']) {
      expect(requestBodyErrorResponse({ type }).status).toBe(415);
    }
  });

  test('unrelated application errors fall through to the generic handler', () => {
    expect(requestBodyErrorResponse(new Error('database failed'))).toBeNull();
  });
});
