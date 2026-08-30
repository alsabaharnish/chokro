/**
 * Safe HTTP responses for errors raised while Express parses a request body.
 *
 * Body-parser errors are client/request failures, not server failures. Returning
 * the generic 500 from `index.js` for malformed JSON tells a client to retry a
 * request that can never succeed; returning it for an oversized body also hides
 * the upload limit that the client can act on.
 *
 * The parser's own message is never returned. Depending on the failure it may
 * contain a fragment of the request body, which can include user data.
 */

function requestBodyErrorResponse(error) {
  switch (error?.type) {
    case 'entity.parse.failed':
      return {
        status: 400,
        error: 'invalid_json',
        message: 'The request body is not valid JSON.',
      };

    case 'entity.too.large':
      return {
        status: 413,
        error: 'payload_too_large',
        message: 'The request body is too large.',
      };

    case 'charset.unsupported':
    case 'encoding.unsupported':
      return {
        status: 415,
        error: 'unsupported_body_encoding',
        message: 'The request body uses an unsupported encoding.',
      };

    case 'request.aborted':
    case 'request.size.invalid':
      return {
        status: 400,
        error: 'incomplete_request',
        message: 'The request body was incomplete. Try again.',
      };

    default:
      return null;
  }
}

module.exports = { requestBodyErrorResponse };
