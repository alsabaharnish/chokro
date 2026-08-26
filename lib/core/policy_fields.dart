/// Field descriptors for the points policy editor (F3.3).
///
/// One list drives the form, the change summary and the per-field parsing. No
/// Flutter, no Firebase — pure, so the diff logic is unit-testable.
///
/// The alternative was nine near-identical form fields and a hand-written diff.
/// This keeps the definition of "what a policy parameter is" in exactly one
/// place, so adding a tenth parameter is one entry here rather than three edits
/// in three files.
library;

import 'points_policy.dart';

class PolicyField {
  const PolicyField({
    required this.key,
    required this.label,
    required this.help,
    required this.read,
    required this.write,
    this.suffix,
  });

  /// Matches the Firestore field name in `config/points`.
  final String key;

  final String label;

  /// Shown under the input. Explains *why* the value is what it is, because an
  /// administrator changing a number needs the reasoning, not a restatement.
  final String help;

  /// Unit shown after the input, where one clarifies the number.
  final String? suffix;

  final int Function(PointsPolicy policy) read;
  final PointsPolicy Function(PointsPolicy policy, int value) write;
}

/// Every tunable parameter, in the order the form presents them.
///
/// Grouped by concern: awards first, then redemption, then the anti-farming
/// limits.
const List<PolicyField> policyFields = <PolicyField>[
  PolicyField(
    key: 'disposalAward',
    label: 'Disposal award',
    suffix: 'points',
    help:
        'Credited for one approved disposal. The strongest verification '
        'route — geofenced, time-locked and hash-checked — so it pays most.',
    read: _readDisposalAward,
    write: _writeDisposalAward,
  ),
  PolicyField(
    key: 'claimAward',
    label: 'Claim award',
    suffix: 'points',
    help:
        'Credited for one approved self-reported action. Must stay strictly '
        'below the disposal award: the weaker route must pay less, or users '
        'optimise into it.',
    read: _readClaimAward,
    write: _writeClaimAward,
  ),
  PolicyField(
    key: 'purchaseAwardPercent',
    label: 'Purchase award',
    suffix: '% of payable',
    help:
        'Computed in points, not taka value. At 5%, a BDT 1000 order earns '
        '50 points — worth BDT 5. A light loyalty bonus, not an earn route.',
    read: _readPurchaseAwardPercent,
    write: _writePurchaseAwardPercent,
  ),
  PolicyField(
    key: 'redemptionPointsPerBlock',
    label: 'Redemption block — points',
    suffix: 'points',
    help:
        'With the taka figure below, sets the exchange rate. 100 points to '
        'BDT 10 means 10 points buys BDT 1.',
    read: _readRedemptionPoints,
    write: _writeRedemptionPoints,
  ),
  PolicyField(
    key: 'redemptionTakaPerBlock',
    label: 'Redemption block — taka',
    suffix: 'BDT',
    help:
        'Points are spent in whole-taka multiples, so a remainder stays in '
        'the wallet rather than leaving the ledger unable to reconcile.',
    read: _readRedemptionTaka,
    write: _writeRedemptionTaka,
  ),
  PolicyField(
    key: 'maxRedemptionPercentOfSubtotal',
    label: 'Maximum redemption',
    suffix: '% of subtotal',
    help:
        'Ceiling on how much of an order may be paid with points. Points '
        'supplement payment; they do not replace it.',
    read: _readMaxRedemption,
    write: _writeMaxRedemption,
  ),
  PolicyField(
    key: 'lockoutHours',
    label: 'Lockout window',
    suffix: 'hours',
    help:
        'How long a user is blocked from re-submitting at the same bin. '
        'Blocks trivial farming while permitting genuine twice-daily disposal.',
    read: _readLockoutHours,
    write: _writeLockoutHours,
  ),
  PolicyField(
    key: 'dailyDisposalCap',
    label: 'Daily disposal cap',
    suffix: 'per day',
    help:
        'Approved submissions per user per day. Second line of defence '
        'against farming across several bins.',
    read: _readDailyCap,
    write: _writeDailyCap,
  ),
  PolicyField(
    key: 'claimQuotaPerWeek',
    label: 'Claim quota',
    suffix: 'per ISO week',
    help:
        'Approved claims per user per week. For the self-reported route the '
        'rate limit is the safeguard, since nothing mechanical can verify it.',
    read: _readClaimQuota,
    write: _writeClaimQuota,
  ),
];

/// A single parameter that differs between two policies.
class PolicyChange {
  const PolicyChange({
    required this.field,
    required this.from,
    required this.to,
  });

  final PolicyField field;
  final int from;
  final int to;

  String get summary => '${field.label}: $from → $to';

  @override
  String toString() => summary;
}

/// Every parameter that differs, in form order. Empty means the policies match.
///
/// Used to show an administrator exactly what they are about to change before
/// they commit to it — a points policy edit alters the economy, so a silent
/// save is the wrong interaction.
List<PolicyChange> diffPolicies(PointsPolicy before, PointsPolicy after) {
  final changes = <PolicyChange>[];
  for (final field in policyFields) {
    final from = field.read(before);
    final to = field.read(after);
    if (from != to) {
      changes.add(PolicyChange(field: field, from: from, to: to));
    }
  }
  return changes;
}

// Top-level functions rather than closures so the descriptor list can be const.

int _readDisposalAward(PointsPolicy p) => p.disposalAward;
PointsPolicy _writeDisposalAward(PointsPolicy p, int v) =>
    p.copyWith(disposalAward: v);

int _readClaimAward(PointsPolicy p) => p.claimAward;
PointsPolicy _writeClaimAward(PointsPolicy p, int v) =>
    p.copyWith(claimAward: v);

int _readPurchaseAwardPercent(PointsPolicy p) => p.purchaseAwardPercent;
PointsPolicy _writePurchaseAwardPercent(PointsPolicy p, int v) =>
    p.copyWith(purchaseAwardPercent: v);

int _readRedemptionPoints(PointsPolicy p) => p.redemptionPointsPerBlock;
PointsPolicy _writeRedemptionPoints(PointsPolicy p, int v) =>
    p.copyWith(redemptionPointsPerBlock: v);

int _readRedemptionTaka(PointsPolicy p) => p.redemptionTakaPerBlock;
PointsPolicy _writeRedemptionTaka(PointsPolicy p, int v) =>
    p.copyWith(redemptionTakaPerBlock: v);

int _readMaxRedemption(PointsPolicy p) => p.maxRedemptionPercentOfSubtotal;
PointsPolicy _writeMaxRedemption(PointsPolicy p, int v) =>
    p.copyWith(maxRedemptionPercentOfSubtotal: v);

int _readLockoutHours(PointsPolicy p) => p.lockoutHours;
PointsPolicy _writeLockoutHours(PointsPolicy p, int v) =>
    p.copyWith(lockoutHours: v);

int _readDailyCap(PointsPolicy p) => p.dailyDisposalCap;
PointsPolicy _writeDailyCap(PointsPolicy p, int v) =>
    p.copyWith(dailyDisposalCap: v);

int _readClaimQuota(PointsPolicy p) => p.claimQuotaPerWeek;
PointsPolicy _writeClaimQuota(PointsPolicy p, int v) =>
    p.copyWith(claimQuotaPerWeek: v);
