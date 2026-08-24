import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/sales_report.dart';
import '../models/order_model.dart';
import '../services/order_service.dart';
import 'current_user_provider.dart';
import 'orders_controller.dart';

/// The Greenpreneur's sales report (F4.6).
///
/// Reads deeper than the fulfilment list — see
/// [OrderService.watchSellerOrdersForReport] — because these orders are totalled
/// rather than listed, and a total over a truncated set is wrong rather than
/// merely short.

/// Which window the report is showing.
///
/// A `NotifierProvider` rather than a `StateProvider`, which Riverpod 3 no
/// longer defines — the catalogue filter is shaped the same way.
class SalesPeriodController extends Notifier<SalesPeriod> {
  @override
  SalesPeriod build() => SalesPeriod.today;

  void select(SalesPeriod period) => state = period;
}

final salesPeriodProvider =
    NotifierProvider<SalesPeriodController, SalesPeriod>(
      SalesPeriodController.new,
    );

/// Every order this seller has, up to the report cap.
///
/// One subscription serves all five periods: the windows are applied in Dart, so
/// tapping between "Today" and "All time" re-totals what is already in memory
/// and costs no Firestore read.
final sellerReportOrdersProvider =
    StreamProvider.autoDispose<SellerOrderPage>((ref) {
      final uid = ref.watch(currentUidProvider);
      if (uid == null) {
        return Stream<SellerOrderPage>.value(
          const SellerOrderPage(orders: <OrderModel>[], truncated: false),
        );
      }
      return ref.watch(orderServiceProvider).watchSellerOrdersForReport(uid);
    });

/// The report for the currently selected period.
///
/// `DateTime.now()` is read here rather than inside [SellerSalesReport], so the
/// arithmetic stays a pure function of its inputs and the tests can pin "now"
/// instead of working around the clock.
final sellerSalesReportProvider = Provider.autoDispose<AsyncValue<SellerSalesReport>>(
  (ref) {
    final period = ref.watch(salesPeriodProvider);
    return ref
        .watch(sellerReportOrdersProvider)
        .whenData(
          (page) => SellerSalesReport.from(
            page.orders,
            period: period,
            now: DateTime.now(),
            // A fact from the query, not an inference from the row count — the
            // service reads one document past the cap to establish it.
            truncated: page.truncated,
          ),
        );
  },
);
