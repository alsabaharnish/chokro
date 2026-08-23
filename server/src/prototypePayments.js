/**
 * Shared vocabulary for simulated payments.
 *
 * These methods never contact a processor and must never accept credentials.
 * They exist so the product flow can be demonstrated before a real provider is
 * selected. A production integration must only mark a payment paid after a
 * provider-verified server callback.
 */

const PROTOTYPE_PAYMENT_METHODS = Object.freeze([
  'prototypeBkash',
  'prototypeNagad',
  'prototypeCard',
]);

function isPrototypePaymentMethod(method) {
  return PROTOTYPE_PAYMENT_METHODS.includes(method);
}

function prototypePaymentReference({ kind, id, method }) {
  const provider = method.replace('prototype', '').toUpperCase();
  const safeKind = kind === 'order' ? 'ORD' : 'DON';
  const suffix = String(id).replace(/[^A-Za-z0-9]/g, '').slice(-16).toUpperCase();
  return `SIM-${safeKind}-${provider}-${suffix}`;
}

module.exports = {
  PROTOTYPE_PAYMENT_METHODS,
  isPrototypePaymentMethod,
  prototypePaymentReference,
};
