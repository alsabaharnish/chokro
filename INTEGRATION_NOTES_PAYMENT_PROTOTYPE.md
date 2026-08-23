# Prototype online payments — integration notes

## Delivered surface

- Marketplace checkout keeps cash on delivery and adds bKash, Nagad, and card
  simulations. Simulated orders are recorded paid with one shared server-made
  `SIM-ORD-...` reference across a multi-Greenpreneur checkout.
- Initiative support keeps the transactional reward-point path and adds a
  separate online-prototype mode. Its `POST /donations/prototype-payments` route
  writes an idempotent server-only receipt without changing a wallet or ledger.
- A shared, scrollable review dialog states that no real money moves and exposes
  no input for a card number, wallet number, PIN, OTP, password, or token.
- Order, donation, and Admin interfaces label prototype values explicitly.
  `prototypeDonationTaka` and `prototypeDonationsReceived` cannot be confused
  with point donations or verified income.

## Wire values and records

Settlement methods are `cashOnDelivery`, `prototypeBkash`, `prototypeNagad`,
and `prototypeCard`. Prototype records include `paymentStatus=paid`,
`paymentPrototype=true`, and a non-secret server-generated `paymentReference`.
Point donation receipts now add `kind=points`; legacy receipts without `kind`
remain valid for idempotent retries. Money simulations use
`kind=prototypeOnline`.

## Deployment and production boundary

Deploy the trusted service before or with the Flutter client because the new
donation route and checkout settlement values are server-owned. This is a flow
prototype only. Production payment work still requires processor onboarding,
server-side payment creation, signed callback verification, pending/failed
states, reconciliation, refunds, secrets management, and operational support.
The current client confirmation must never be treated as payment proof.

## Verification focus

Tests cover allowed payment vocabulary, bounded donation amounts, receipt
labelling, no wallet/ledger writes for money simulations, idempotent retries,
client controller retry keys, model parsing, separated Admin counters, and the
narrow-screen/semantics-safe payment dialog.

Final verification: clean Flutter analysis, 470 Flutter tests, 279 Node tests,
222 Firestore rules tests, and a successful production web build.
