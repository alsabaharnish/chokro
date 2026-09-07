import 'package:chokro/controllers/admin_users_controller.dart';
import 'package:chokro/controllers/dashboard_controller.dart';
import 'package:chokro/core/constants.dart';
import 'package:chokro/models/user_model.dart';
import 'package:chokro/services/user_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'account totals re-evaluate a temporary suspension against the clock',
    () {
      final suspensionEnds = DateTime(2100, 1, 1, 12);
      final page = UserDirectoryPage(
        users: [
          UserModel(
            uid: 'temporarily-suspended',
            name: 'Temporary suspension',
            email: 'temporary@example.com',
            role: AppConstants.roleBuyer,
            status: AppConstants.statusSuspended,
            createdAt: DateTime(2099),
            suspendedUntil: suspensionEnds,
          ),
        ],
        truncated: false,
      );

      AccountTotals totalsAt(DateTime now) {
        final container = ProviderContainer(
          overrides: [
            dashboardClockProvider.overrideWithValue(AsyncData(now)),
            allUsersProvider.overrideWithValue(AsyncData(page)),
          ],
        );
        addTearDown(container.dispose);
        return container.read(accountTotalsProvider).requireValue;
      }

      expect(
        totalsAt(suspensionEnds.subtract(const Duration(seconds: 1))).suspended,
        1,
      );
      expect(
        totalsAt(suspensionEnds.add(const Duration(seconds: 1))).suspended,
        0,
      );
    },
  );
}
