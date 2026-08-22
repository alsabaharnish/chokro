/// Chokro — points policy (§7.3 of the project brief).
///
/// This is the single source of truth for every number that governs the points
/// economy. Nothing in this file imports Firebase. It is plain Dart so that all
/// of the arithmetic below is unit-testable without an emulator.
///
/// Values are admin-tunable at runtime: they live in the Firestore document
/// `config/points` and are read into a [PointsPolicy] via [PointsPolicy.fromJson].
/// The constants declared here are the *defaults* — used on first run, when the
/// config document is missing, and as the fallback for any individual field the
/// document omits or stores with a bad type.
///
/// IMPORTANT INVARIANT — snapshot on award.
/// When a disposal, claim or purchase is approved, the awarded amount must be
/// written onto that record (`pointsAwarded`) at that moment. Never re-derive a
/// past award from the current policy. An admin lowering the disposal award from
/// 50 to 40 must not silently rewrite what last month's disposals were worth.
/// This mirrors the order line-item price snapshot rule in §6.
library;

/// Default values, straight from §7.3 of the brief.
class PointsPolicyDefaults {
  const PointsPolicyDefaults._();

  /// Points credited for one approved disposal submission.
  static const int disposalAward = 50;

  /// Points credited for one approved self-reported eco-action claim.
  /// Must stay strictly below [disposalAward] — see [PointsPolicy.validate].
  static const int claimAward = 15;

  /// Maximum approved claims per user per ISO week.
  static const int claimQuotaPerWeek = 3;

  /// Purchase award as a whole percentage of the order's payable amount.
  static const int purchaseAwardPercent = 5;

  /// Redemption rate, expressed as a block: [redemptionPointsPerBlock] points
  /// are worth [redemptionTakaPerBlock] taka. Default: 100 points = ৳10.
  static const int redemptionPointsPerBlock = 100;
  static const int redemptionTakaPerBlock = 10;

  /// Ceiling on how much of an order's subtotal may be paid with points,
  /// as a whole percentage. Points supplement payment; they do not replace it.
  static const int maxRedemptionPercentOfSubtotal = 50;

  /// Hours a user is locked out of re-submitting at the same bin.
  static const int lockoutHours = 6;

  /// Maximum approved disposal submissions per user per calendar day.
  static const int dailyDisposalCap = 3;
}

/// A resolved, validated set of points-economy parameters.
///
/// Immutable. Obtain one from [PointsPolicy.defaults] or [PointsPolicy.fromJson],
/// and produce modified copies with [copyWith] (used by the admin config screen).
class PointsPolicy {
  final int disposalAward;
  final int claimAward;
  final int claimQuotaPerWeek;
  final int purchaseAwardPercent;
  final int redemptionPointsPerBlock;
  final int redemptionTakaPerBlock;
  final int maxRedemptionPercentOfSubtotal;
  final int lockoutHours;
  final int dailyDisposalCap;

  const PointsPolicy({
    required this.disposalAward,
    required this.claimAward,
    required this.claimQuotaPerWeek,
    required this.purchaseAwardPercent,
    required this.redemptionPointsPerBlock,
    required this.redemptionTakaPerBlock,
    required this.maxRedemptionPercentOfSubtotal,
    required this.lockoutHours,
    required this.dailyDisposalCap,
  });

  /// The §7.3 baseline.
  static const PointsPolicy defaults = PointsPolicy(
    disposalAward: PointsPolicyDefaults.disposalAward,
    claimAward: PointsPolicyDefaults.claimAward,
    claimQuotaPerWeek: PointsPolicyDefaults.claimQuotaPerWeek,
    purchaseAwardPercent: PointsPolicyDefaults.purchaseAwardPercent,
    redemptionPointsPerBlock: PointsPolicyDefaults.redemptionPointsPerBlock,
    redemptionTakaPerBlock: PointsPolicyDefaults.redemptionTakaPerBlock,
    maxRedemptionPercentOfSubtotal:
        PointsPolicyDefaults.maxRedemptionPercentOfSubtotal,
    lockoutHours: PointsPolicyDefaults.lockoutHours,
    dailyDisposalCap: PointsPolicyDefaults.dailyDisposalCap,
  );

  // ---------------------------------------------------------------------------
  // Serialization — `config/points`
  // ---------------------------------------------------------------------------

  /// Reads a policy from the `config/points` document.
  ///
  /// Deliberately forgiving: any field that is missing, null, or not an integer
  /// falls back to its default rather than throwing. A malformed config document
  /// must never be able to take the app down — worst case it runs on defaults.
  ///
  /// Note this does NOT validate cross-field invariants. Call [validate] before
  /// writing a policy back; reads are tolerant, writes are strict.
  factory PointsPolicy.fromJson(Map<String, dynamic>? json) {
    final map = json ?? const <String, dynamic>{};

    int read(String key, int fallback) {
      final value = map[key];
      if (value is int) return value;
      if (value is num && value.isFinite && value.truncateToDouble() == value) {
        return value.toInt();
      }
      return fallback;
    }

    return PointsPolicy(
      disposalAward: read('disposalAward', defaults.disposalAward),
      claimAward: read('claimAward', defaults.claimAward),
      claimQuotaPerWeek: read('claimQuotaPerWeek', defaults.claimQuotaPerWeek),
      purchaseAwardPercent: read(
        'purchaseAwardPercent',
        defaults.purchaseAwardPercent,
      ),
      redemptionPointsPerBlock: read(
        'redemptionPointsPerBlock',
        defaults.redemptionPointsPerBlock,
      ),
      redemptionTakaPerBlock: read(
        'redemptionTakaPerBlock',
        defaults.redemptionTakaPerBlock,
      ),
      maxRedemptionPercentOfSubtotal: read(
        'maxRedemptionPercentOfSubtotal',
        defaults.maxRedemptionPercentOfSubtotal,
      ),
      lockoutHours: read('lockoutHours', defaults.lockoutHours),
      dailyDisposalCap: read('dailyDisposalCap', defaults.dailyDisposalCap),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'disposalAward': disposalAward,
    'claimAward': claimAward,
    'claimQuotaPerWeek': claimQuotaPerWeek,
    'purchaseAwardPercent': purchaseAwardPercent,
    'redemptionPointsPerBlock': redemptionPointsPerBlock,
    'redemptionTakaPerBlock': redemptionTakaPerBlock,
    'maxRedemptionPercentOfSubtotal': maxRedemptionPercentOfSubtotal,
    'lockoutHours': lockoutHours,
    'dailyDisposalCap': dailyDisposalCap,
  };

  PointsPolicy copyWith({
    int? disposalAward,
    int? claimAward,
    int? claimQuotaPerWeek,
    int? purchaseAwardPercent,
    int? redemptionPointsPerBlock,
    int? redemptionTakaPerBlock,
    int? maxRedemptionPercentOfSubtotal,
    int? lockoutHours,
    int? dailyDisposalCap,
  }) {
    return PointsPolicy(
      disposalAward: disposalAward ?? this.disposalAward,
      claimAward: claimAward ?? this.claimAward,
      claimQuotaPerWeek: claimQuotaPerWeek ?? this.claimQuotaPerWeek,
      purchaseAwardPercent: purchaseAwardPercent ?? this.purchaseAwardPercent,
      redemptionPointsPerBlock:
          redemptionPointsPerBlock ?? this.redemptionPointsPerBlock,
      redemptionTakaPerBlock:
          redemptionTakaPerBlock ?? this.redemptionTakaPerBlock,
      maxRedemptionPercentOfSubtotal:
          maxRedemptionPercentOfSubtotal ?? this.maxRedemptionPercentOfSubtotal,
      lockoutHours: lockoutHours ?? this.lockoutHours,
      dailyDisposalCap: dailyDisposalCap ?? this.dailyDisposalCap,
    );
  }

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  /// Returns a list of human-readable problems with this policy. Empty means OK.
  ///
  /// Call this in the admin config screen before saving, and again on the server
  /// before writing `config/points`. The client is not trusted to have called it.
  ///
  /// The load-bearing rule here is the last one: **award value must track
  /// verification strength** (§7.3). A claim rests on an administrator's read of
  /// a photograph and nothing else; a disposal is geofenced, time-locked and
  /// hash-checked. If a claim ever pays more than a disposal, users optimise into
  /// the weaker route and the entire verification design stops meaning anything.
  List<String> validate() {
    final problems = <String>[];

    void positive(String label, int value) {
      if (value <= 0) problems.add('$label must be greater than zero.');
    }

    positive('Disposal award', disposalAward);
    positive('Claim award', claimAward);
    positive('Claim quota per week', claimQuotaPerWeek);
    positive('Redemption points per block', redemptionPointsPerBlock);
    positive('Redemption taka per block', redemptionTakaPerBlock);
    positive('Lockout window', lockoutHours);
    positive('Daily disposal cap', dailyDisposalCap);

    if (purchaseAwardPercent < 0 || purchaseAwardPercent > 100) {
      problems.add('Purchase award percent must be between 0 and 100.');
    }
    if (maxRedemptionPercentOfSubtotal < 0 ||
        maxRedemptionPercentOfSubtotal > 100) {
      problems.add('Max redemption percent must be between 0 and 100.');
    }
    if (lockoutHours > 24 * 7) {
      problems.add('Lockout window may not exceed one week.');
    }

    if (claimAward >= disposalAward) {
      problems.add(
        'Claim award ($claimAward) must be lower than disposal award '
        '($disposalAward): the weaker verification route must pay less.',
      );
    }

    return problems;
  }

  bool get isValid => validate().isEmpty;

  // ---------------------------------------------------------------------------
  // Redemption arithmetic
  // ---------------------------------------------------------------------------

  /// Points required to buy one taka of value. With the defaults, 10.
  ///
  /// Redemption is always transacted in whole taka, so points are spent in
  /// multiples of this number. This avoids ever owing a buyer ৳2.7.
  int get pointsPerTaka {
    final ratio = redemptionPointsPerBlock ~/ redemptionTakaPerBlock;
    return ratio < 1 ? 1 : ratio;
  }

  /// Taka value of [points], rounded down. Points that don't fill a whole taka
  /// are not spent — see [pointsToSpendForTaka].
  int takaForPoints(int points) {
    if (points <= 0) return 0;
    return points ~/ pointsPerTaka;
  }

  /// Points actually deducted to deliver [taka] of discount. Always an exact
  /// multiple of [pointsPerTaka], so the ledger never records a partial block.
  int pointsToSpendForTaka(int taka) {
    if (taka <= 0) return 0;
    return taka * pointsPerTaka;
  }

  /// The most points a buyer may apply to an order with this [subtotal],
  /// given their current wallet [balance].
  ///
  /// Bounded by three things at once: the wallet balance, the
  /// [maxRedemptionPercentOfSubtotal] ceiling, and whole-taka granularity.
  /// Always returns an exact multiple of [pointsPerTaka].
  int maxRedeemablePoints({required int subtotal, required int balance}) {
    if (subtotal <= 0 || balance <= 0) return 0;

    final takaCeiling = (subtotal * maxRedemptionPercentOfSubtotal) ~/ 100;
    if (takaCeiling <= 0) return 0;

    final pointsCeiling = pointsToSpendForTaka(takaCeiling);
    final usable = balance < pointsCeiling ? balance : pointsCeiling;

    // Round down to a whole-taka block.
    return (usable ~/ pointsPerTaka) * pointsPerTaka;
  }

  /// Applies [pointsRequested] to an order and returns the resulting split.
  ///
  /// Clamps the request to [maxRedeemablePoints] rather than throwing — the UI
  /// should prevent an over-request, but the arithmetic must be safe if it
  /// doesn't. The server recomputes this at checkout; the client's figure is
  /// display only.
  RedemptionOutcome applyRedemption({
    required int subtotal,
    required int balance,
    required int pointsRequested,
  }) {
    final cap = maxRedeemablePoints(subtotal: subtotal, balance: balance);
    var pointsApplied = pointsRequested < 0 ? 0 : pointsRequested;
    if (pointsApplied > cap) pointsApplied = cap;

    // Never spend points that don't buy a whole taka.
    pointsApplied = (pointsApplied ~/ pointsPerTaka) * pointsPerTaka;

    final discount = takaForPoints(pointsApplied);
    return RedemptionOutcome(
      subtotal: subtotal,
      pointsApplied: pointsApplied,
      discount: discount,
      payable: subtotal - discount,
    );
  }

  // ---------------------------------------------------------------------------
  // Award arithmetic
  // ---------------------------------------------------------------------------

  /// Points credited to the buyer when an order is confirmed received.
  ///
  /// Computed from the *payable* amount, not the subtotal — points already
  /// redeemed do not earn points back, which would otherwise be a slow leak.
  int purchaseAward(int payable) {
    if (payable <= 0) return 0;
    return (payable * purchaseAwardPercent) ~/ 100;
  }

  // ---------------------------------------------------------------------------
  // Lockout and cap arithmetic
  // ---------------------------------------------------------------------------

  /// When a lockout opened at [from] expires.
  ///
  /// In production [from] is always a server timestamp (§7.4, client clock
  /// manipulation). This function is pure so it can be tested; it does not read
  /// the clock itself.
  DateTime lockoutExpiry(DateTime from) =>
      from.add(Duration(hours: lockoutHours));

  /// Whether a lockout expiring at [expiresAt] is still in force at [now].
  /// A null [expiresAt] means no lockout document exists — not locked out.
  bool isLockedOut({required DateTime? expiresAt, required DateTime now}) {
    if (expiresAt == null) return false;
    return now.isBefore(expiresAt);
  }

  /// Whether another disposal may be approved today, given how many already were.
  bool canApproveAnotherDisposalToday(int approvedToday) =>
      approvedToday < dailyDisposalCap;

  /// Whether another claim may be approved this ISO week.
  bool canApproveAnotherClaimThisWeek(int approvedThisWeek) =>
      approvedThisWeek < claimQuotaPerWeek;

  @override
  String toString() => 'PointsPolicy(${toJson()})';

  @override
  bool operator ==(Object other) =>
      other is PointsPolicy &&
      other.disposalAward == disposalAward &&
      other.claimAward == claimAward &&
      other.claimQuotaPerWeek == claimQuotaPerWeek &&
      other.purchaseAwardPercent == purchaseAwardPercent &&
      other.redemptionPointsPerBlock == redemptionPointsPerBlock &&
      other.redemptionTakaPerBlock == redemptionTakaPerBlock &&
      other.maxRedemptionPercentOfSubtotal == maxRedemptionPercentOfSubtotal &&
      other.lockoutHours == lockoutHours &&
      other.dailyDisposalCap == dailyDisposalCap;

  @override
  int get hashCode => Object.hash(
    disposalAward,
    claimAward,
    claimQuotaPerWeek,
    purchaseAwardPercent,
    redemptionPointsPerBlock,
    redemptionTakaPerBlock,
    maxRedemptionPercentOfSubtotal,
    lockoutHours,
    dailyDisposalCap,
  );
}

/// The result of applying points to an order. All amounts in whole taka.
class RedemptionOutcome {
  final int subtotal;
  final int pointsApplied;
  final int discount;
  final int payable;

  const RedemptionOutcome({
    required this.subtotal,
    required this.pointsApplied,
    required this.discount,
    required this.payable,
  });

  @override
  String toString() =>
      'RedemptionOutcome(subtotal: $subtotal, pointsApplied: $pointsApplied, '
      'discount: $discount, payable: $payable)';
}

/// ISO-8601 week keys, used as the document ID for `claimQuotas/{userId}_{isoWeek}`.
///
/// Kept here rather than in a date utility because the weekly quota is a points
/// policy concern, and because getting this wrong silently corrupts quota
/// enforcement at year boundaries. ISO weeks start on Monday, and week 1 is the
/// week containing the first Thursday of the year — which is why a date in early
/// January can legitimately belong to the previous ISO year.
class IsoWeek {
  const IsoWeek._();

  /// The ISO week number (1–53) containing [date].
  static int weekNumber(DateTime date) {
    final thursday = _thursdayOfWeek(date);
    final firstOfYear = DateTime.utc(thursday.year, 1, 1);
    return (thursday.difference(firstOfYear).inDays ~/ 7) + 1;
  }

  /// The ISO week-numbering year containing [date]. Not always [DateTime.year].
  static int weekYear(DateTime date) => _thursdayOfWeek(date).year;

  /// Document-ID-safe key, e.g. `2026-W31`. Zero-padded so keys sort correctly.
  static String key(DateTime date) {
    final week = weekNumber(date).toString().padLeft(2, '0');
    return '${weekYear(date)}-W$week';
  }

  /// Full quota document ID for a user in the week containing [date].
  static String quotaDocId(String userId, DateTime date) =>
      '${userId}_${key(date)}';

  /// The Thursday of the ISO week containing [date]. ISO week numbering is
  /// anchored on Thursday, so this single step resolves both week and year.
  static DateTime _thursdayOfWeek(DateTime date) {
    final utc = DateTime.utc(date.year, date.month, date.day);
    return utc.add(Duration(days: 4 - utc.weekday));
  }
}

/// Who last changed the points policy, and when (F3.3).
///
/// The server has recorded `updatedAt` and `updatedBy` on every policy write
/// since the endpoint existed, and `fromDoc` strips both because `validate()`
/// depends on an exact key set — so neither ever reached a person.
///
/// It matters because of what this screen is. The policy defines the economy, any
/// administrator can change it, and the values give no hint of their own history:
/// a disposal award of 50 looks identical whether it is the untouched default
/// from §7.3 or something a colleague set an hour ago. An administrator about to
/// change it should be able to tell those apart.
class PolicyProvenance {
  const PolicyProvenance({this.updatedAt, this.updatedBy, this.updatedByName});

  /// Server time of the last write. Null when nothing has ever been saved.
  final DateTime? updatedAt;

  /// The editing administrator's uid, kept for the case where their name cannot
  /// be resolved — a deleted account, or a failed lookup.
  final String? updatedBy;

  /// Resolved on the server, because a uid is not something to show a person.
  final String? updatedByName;

  static const unknown = PolicyProvenance();

  factory PolicyProvenance.fromJson(Map<String, dynamic> json) {
    final raw = json['updatedAt'];
    return PolicyProvenance(
      updatedAt: raw is String ? DateTime.tryParse(raw) : null,
      updatedBy: json['updatedBy'] is String
          ? json['updatedBy'] as String
          : null,
      updatedByName: json['updatedByName'] is String
          ? json['updatedByName'] as String
          : null,
    );
  }

  /// True when the policy document does not exist, so these are the defaults.
  ///
  /// Worth stating outright on the screen: "nobody has changed this" is different
  /// information from "somebody set it to exactly the defaults".
  bool get isUntouched => updatedAt == null;

  /// Whoever made the last change, as well as it can be named.
  String get editor => updatedByName ?? updatedBy ?? 'a 3ZERO Admin';
}

/// A policy read together with the provenance of its last change.
///
/// One object so the editor gets both from a single request. Fetching provenance
/// separately would double a call that every award calculation depends on.
class PolicySnapshot {
  const PolicySnapshot({required this.policy, required this.provenance});

  final PointsPolicy policy;
  final PolicyProvenance provenance;

  factory PolicySnapshot.fromJson(Map<String, dynamic> json) => PolicySnapshot(
    policy: PointsPolicy.fromJson(json),
    provenance: PolicyProvenance.fromJson(json),
  );
}
