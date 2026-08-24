/// A Greenpreneur's sales, totalled over a period.
///
/// Pure Dart: no Flutter, no Firebase, no widgets. The arithmetic a seller will
/// read their income off is the last thing that should need an emulator to test.
///
/// ## What this can and cannot say
///
/// Chokro never pays a Greenpreneur. There is no seller wallet, no ledger entry
/// and no payout record anywhere in `server/src` — `award.js` credits Champions
/// only. A buyer settles with the seller directly: cash at the door, or one of
/// the prototype online methods, which are simulations that move nothing.
///
/// So this is a record of **order value**, not a balance the app is holding for
/// anyone. Every label the report renders has to keep that distinction, because
/// the difference between "you have earned ৳4,200" and "৳4,200 of orders were
/// placed with you" is the difference between a statement of fact and a promise
/// the app cannot keep.
///
/// ## Every period is "orders **placed** in this window"
///
/// One window, applied to `createdAt`, for every figure. The alternative was to
/// date each receipt by when it was actually received — which for cash on
/// delivery is `deliveredAt`, since `orders.js` flips `paymentStatus` to `paid`
/// inside that transition rather than at checkout.
///
/// That would be a truer cash-flow statement and a worse report. The totals stop
/// reconciling the moment the two dates differ: an order placed in June and
/// delivered in August would appear in June's sales and August's receipts, so
/// no period would satisfy `net == collected + simulated + outstanding` and a
/// seller checking the arithmetic would find it broken. Cohorting on the order
/// date keeps that identity exact, which is what makes the four figures readable
/// as one sentence — and the screen says "orders placed" rather than implying
/// otherwise.
///
/// ## What [outstanding] actually is
///
/// There is no cancellation, refund or reversal anywhere in this system, so an
/// unsettled order is never written off. Because cash on delivery settles at the
/// `delivered` transition, an outstanding balance is exactly the value of orders
/// the seller has not yet marked delivered. That makes it a to-do list rather
/// than a debt: the screen should say so, or a seller will read a figure that
/// only ever grows as money somebody owes them.
library;

import '../models/order_model.dart';

/// The windows the report can be read over.
///
/// Rolling windows anchored to local midnight rather than calendar months. Two
/// reasons: a seller asking "how did last week go" means the last seven days,
/// not "since Monday"; and anchoring to midnight keeps a total still while it is
/// being read, where a rolling 168-hour window would drop orders out of the
/// figure as the seller watched.
enum SalesPeriod {
  today,
  week,
  month,
  quarter,
  allTime;

  String get label => switch (this) {
    SalesPeriod.today => 'Today',
    SalesPeriod.week => 'Last 7 days',
    SalesPeriod.month => 'Last 30 days',
    SalesPeriod.quarter => 'Last 3 months',
    SalesPeriod.allTime => 'All time',
  };

  /// A short form for a segmented control on a narrow phone.
  String get shortLabel => switch (this) {
    SalesPeriod.today => 'Today',
    SalesPeriod.week => '7d',
    SalesPeriod.month => '30d',
    SalesPeriod.quarter => '3m',
    SalesPeriod.allTime => 'All',
  };

  /// How many whole days the window covers, counting today. Null for [allTime].
  int? get days => switch (this) {
    SalesPeriod.today => 1,
    SalesPeriod.week => 7,
    SalesPeriod.month => 30,
    SalesPeriod.quarter => 90,
    SalesPeriod.allTime => null,
  };

  /// The first instant included in this window, in the device's local zone, or
  /// null for [allTime].
  ///
  /// Built by constructing a date rather than subtracting a [Duration]: day
  /// arithmetic through the constructor normalises across month and year ends,
  /// and does not drift by an hour if this is ever run somewhere with daylight
  /// saving. Bangladesh has none, but the correctness should not depend on that.
  DateTime? startFrom(DateTime now) {
    final count = days;
    if (count == null) return null;
    final local = now.toLocal();
    return DateTime(local.year, local.month, local.day - (count - 1));
  }
}

/// One period's totals for one seller.
///
/// Every money field is whole taka, matching the order documents, which store
/// taka as `int` throughout — so nothing here rounds and nothing accumulates a
/// floating-point error across a hundred orders.
class SellerSalesReport {
  const SellerSalesReport({
    required this.period,
    required this.since,
    required this.orderCount,
    required this.itemCount,
    required this.gross,
    required this.pointsDiscount,
    required this.net,
    required this.collected,
    required this.simulated,
    required this.outstanding,
    required this.pointsRedeemed,
    required this.countByStatus,
    required this.truncated,
    required this.oldestOrder,
    required this.undated,
  });

  final SalesPeriod period;

  /// The first instant counted, or null for [SalesPeriod.allTime]. Rendered so
  /// the seller can see what "last 7 days" resolved to rather than trusting it.
  final DateTime? since;

  final int orderCount;

  /// Units sold, summed across every line of every counted order.
  final int itemCount;

  /// Σ `subtotal` — the listed value of what was ordered, before the buyer's
  /// points came off it.
  final int gross;

  /// Σ `discount` — the taka the buyer settled with points instead of money.
  ///
  /// The seller is **not** reimbursed this. `checkout.js` writes
  /// `payable = subtotal - discount` and nothing anywhere credits the difference
  /// back, so this is a reduction in what the seller is owed, not a receivable.
  /// It is reported because a seller comparing [gross] against [net] will
  /// otherwise think money has gone missing.
  final int pointsDiscount;

  /// Σ `payable` — what buyers actually owe this seller. `gross - pointsDiscount`.
  ///
  /// This, not [gross], is the seller's income for the period.
  final int net;

  /// Σ `payable` for settled orders paid in real money — cash on delivery that
  /// has reached at least `delivered`.
  final int collected;

  /// Σ `payable` for settled orders paid by a prototype online method.
  ///
  /// Kept apart from [collected] deliberately. `checkout.js` marks these `paid`
  /// at checkout, but `prototypePayments.js` contacts no processor and moves no
  /// money — folding them into a "received" figure would tell a seller they had
  /// been paid for something nobody paid for.
  final int simulated;

  /// Σ `payable` still unsettled: cash-on-delivery orders not yet delivered.
  final int outstanding;

  /// Σ `pointsApplied` — the points buyers spent against these orders.
  final int pointsRedeemed;

  final Map<OrderStatus, int> countByStatus;

  /// True when orders exist that this window should have counted and could not.
  ///
  /// Deliberately **per period**, not simply the query's own cap flag. A seller
  /// past the cap has an incomplete "all time" figure, but their "today" figure
  /// is still exact — the cap took the *oldest* orders, and today's are the
  /// newest. Passing the query flag straight through would put a warning on a
  /// number that is provably complete, which teaches a reader to ignore the
  /// warning on the number that is not.
  ///
  /// So a window is only truncated if the cap bound *and* the oldest order the
  /// query returned is not already older than the window start. If the query
  /// reached back past [since], this window is fully covered.
  ///
  /// Carried all the way to the screen. A total that silently omits orders is
  /// worse than no total, because there is nothing about it that looks wrong.
  final bool truncated;

  /// The oldest order date the query reached, or null if none was readable.
  ///
  /// Names the scope of a truncated figure — "your most recent 500 orders, back
  /// to 3 Feb 2026" — so a floor is a bounded statement rather than a shrug.
  final DateTime? oldestOrder;

  /// Orders counted whose `createdAt` could not be read.
  ///
  /// Not latency compensation. Firestore does surface a server timestamp as null
  /// on the local snapshot that precedes the acknowledgement — but only for a
  /// write this client made, and no client can write an order: `firestore.rules`
  /// denies the whole collection to buyers, sellers and administrators alike. So
  /// that mechanism cannot produce one here.
  ///
  /// What can is a stored value of the wrong type, which `_fromDoc` coerces to
  /// null, or a legacy document written before the field existed. Either is a
  /// damaged record rather than a pending one. It is excluded from every dated
  /// window — a date that cannot be read must not be guessed into today — and
  /// counted here so the discrepancy is visible instead of silently absorbed.
  final int undated;

  /// What the seller has been paid, by any means. Presented split, never as one
  /// number — see [simulated].
  int get settled => collected + simulated;

  bool get isEmpty => orderCount == 0;

  /// Totals [orders] over [period], relative to [now].
  ///
  /// [orders] is every order the seller's query returned; this filters. Pass
  /// [truncated] through from the query so the caller cannot forget it.
  static SellerSalesReport from(
    Iterable<OrderModel> orders, {
    required SalesPeriod period,
    required DateTime now,
    bool truncated = false,
  }) {
    final since = period.startFrom(now);

    var orderCount = 0;
    var itemCount = 0;
    var gross = 0;
    var pointsDiscount = 0;
    var net = 0;
    var collected = 0;
    var simulated = 0;
    var outstanding = 0;
    var pointsRedeemed = 0;
    var undated = 0;
    final byStatus = <OrderStatus, int>{};

    // The oldest date anywhere in the input, not merely in the counted subset —
    // it answers "how far back did the query reach", which is what decides
    // whether this window was fully covered.
    DateTime? oldest;

    for (final order in orders) {
      final placed = order.createdAt?.toLocal();

      if (placed != null && (oldest == null || placed.isBefore(oldest))) {
        oldest = placed;
      }

      if (placed == null) {
        // Only counts against the all-time window, where there is no boundary
        // for it to fall the wrong side of.
        undated += 1;
        if (since != null) continue;
      } else if (since != null && placed.isBefore(since)) {
        continue;
      }

      orderCount += 1;
      itemCount += order.itemCount;
      gross += order.subtotal;
      pointsDiscount += order.discount;
      net += order.payable;
      pointsRedeemed += order.pointsApplied;
      byStatus[order.status] = (byStatus[order.status] ?? 0) + 1;

      if (order.paymentStatus == PaymentStatus.paid) {
        if (order.settlementMethod.isPrototype) {
          simulated += order.payable;
        } else {
          collected += order.payable;
        }
      } else {
        outstanding += order.payable;
      }
    }

    return SellerSalesReport(
      period: period,
      since: since,
      orderCount: orderCount,
      itemCount: itemCount,
      gross: gross,
      pointsDiscount: pointsDiscount,
      net: net,
      collected: collected,
      simulated: simulated,
      outstanding: outstanding,
      pointsRedeemed: pointsRedeemed,
      countByStatus: Map.unmodifiable(byStatus),
      // The cap removed the oldest orders, so a window is only short if the
      // query did not already reach back past its start.
      truncated:
          truncated &&
          (since == null || oldest == null || !oldest.isBefore(since)),
      oldestOrder: oldest,
      undated: undated,
    );
  }
}
