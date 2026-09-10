/// Reporting periods in Asia/Dhaka (EPR-23, QA-3).
///
/// "A December/January boundary error in an annual filing is a compliance
/// error." Every test here is a boundary.
library;

import 'package:chokro/core/epr_period.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the period a moment falls in', () {
    test('the worked example lands in 2026-09', () {
      // Appendix A step 5: periodId 2026-09.
      expect(periodIdFor(DateTime.utc(2026, 9, 15, 10)), '2026-09');
    });

    test('a UTC evening is already the next Dhaka month', () {
      // 30 September 20:00 UTC is 1 October 02:00 in Dhaka. Taking the period
      // from the UTC timestamp would file this disposal in September — and both
      // months are reported to a regulator, one short and one long, with
      // nothing in either document that looks wrong.
      expect(periodIdFor(DateTime.utc(2026, 9, 30, 20)), '2026-10');
      expect(periodIdFor(DateTime.utc(2026, 9, 30, 17, 59)), '2026-09');
      // 18:00 UTC is exactly midnight in Dhaka.
      expect(periodIdFor(DateTime.utc(2026, 9, 30, 18)), '2026-10');
    });

    test('the December/January roll is handled in both directions', () {
      expect(periodIdFor(DateTime.utc(2026, 12, 31, 17, 59)), '2026-12');
      expect(periodIdFor(DateTime.utc(2026, 12, 31, 18)), '2027-01');
      expect(periodIdFor(DateTime.utc(2027, 1, 1, 0)), '2027-01');
    });

    test('a month start in UTC is still the previous Dhaka month at 00:00', () {
      // 1 October 00:00 UTC is 1 October 06:00 in Dhaka — same month. The trap
      // is the other side, tested above.
      expect(periodIdFor(DateTime.utc(2026, 10, 1, 0)), '2026-10');
    });

    test('a local DateTime resolves the same as its UTC instant', () {
      // A client in another timezone must not compute a different period from
      // the server. Conversion goes through UTC first.
      final instant = DateTime.utc(2026, 9, 30, 20);
      expect(periodIdFor(instant.toLocal()), periodIdFor(instant));
    });

    test('a leap-year February is a period like any other', () {
      expect(periodIdFor(DateTime.utc(2028, 2, 29, 12)), '2028-02');
      expect(periodIdFor(DateTime.utc(2028, 2, 29, 18)), '2028-03');
    });
  });

  group('validation', () {
    test('accepts a well-formed period', () {
      expect(isValidPeriodId('2026-09'), isTrue);
      expect(isValidPeriodId('2026-01'), isTrue);
      expect(isValidPeriodId('2026-12'), isTrue);
    });

    test('refuses a malformed or impossible period', () {
      // A malformed period would return an empty rollup, which a screen renders
      // as a month with no activity — indistinguishable from a real quiet month.
      for (final bad in [
        '',
        '2026',
        '2026-9',
        '2026-00',
        '2026-13',
        '26-09',
        '2026/09',
        '2026-09-01',
        'YYYY-MM',
      ]) {
        expect(isValidPeriodId(bad), isFalse, reason: '"$bad" must be refused');
      }
    });

    test('refuses a period before the gazette or absurdly far ahead', () {
      expect(isValidPeriodId('2025-12'), isFalse);
      expect(isValidPeriodId('2026-01'), isTrue);
      expect(isValidPeriodId('2101-01'), isFalse);
    });
  });

  group('period bounds are half-open', () {
    test('a period starts at Dhaka midnight, expressed in UTC', () {
      // Midnight on 1 September in Dhaka is 18:00 on 31 August in UTC.
      expect(periodStartUtc('2026-09'), DateTime.utc(2026, 8, 31, 18));
      expect(periodEndUtc('2026-09'), DateTime.utc(2026, 9, 30, 18));
    });

    test('one period ends exactly where the next begins', () {
      // Half-open ranges throughout: a closed range would need "the last
      // millisecond of the month", which nobody writes correctly twice.
      expect(periodEndUtc('2026-09'), periodStartUtc('2026-10'));
      expect(periodEndUtc('2026-12'), periodStartUtc('2027-01'));
    });

    test('the bounds agree with periodIdFor at both edges', () {
      // The two definitions must not disagree at a boundary, which is why
      // periodContains derives from periodIdFor rather than comparing ranges.
      for (final periodId in ['2026-09', '2026-12', '2027-02', '2028-02']) {
        final start = periodStartUtc(periodId);
        final end = periodEndUtc(periodId);

        expect(periodIdFor(start), periodId, reason: 'start of $periodId');
        expect(
          periodIdFor(start.subtract(const Duration(milliseconds: 1))),
          previousPeriodId(periodId),
          reason: 'just before $periodId',
        );
        expect(
          periodIdFor(end.subtract(const Duration(milliseconds: 1))),
          periodId,
          reason: 'last instant of $periodId',
        );
        expect(periodIdFor(end), nextPeriodId(periodId), reason: 'end of $periodId');
      }
    });

    test('periodContains agrees with periodIdFor', () {
      expect(periodContains('2026-09', DateTime.utc(2026, 9, 15)), isTrue);
      expect(periodContains('2026-09', DateTime.utc(2026, 9, 30, 20)), isFalse);
      expect(periodContains('2026-10', DateTime.utc(2026, 9, 30, 20)), isTrue);
    });
  });

  group('neighbours', () {
    test('previous and next roll the year', () {
      expect(previousPeriodId('2027-01'), '2026-12');
      expect(nextPeriodId('2026-12'), '2027-01');
      expect(previousPeriodId('2026-09'), '2026-08');
      expect(nextPeriodId('2026-09'), '2026-10');
    });

    test('they are inverses', () {
      for (final periodId in ['2026-01', '2026-09', '2026-12', '2027-01']) {
        expect(nextPeriodId(previousPeriodId(periodId)), periodId);
        expect(previousPeriodId(nextPeriodId(periodId)), periodId);
      }
    });

    test('a run of periods is bounded and oldest first', () {
      // A trend chart asks for twelve months, not "all of them", so it cannot
      // become an unbounded read (QA-10).
      expect(periodsEndingAt('2027-01', count: 3), [
        '2026-11',
        '2026-12',
        '2027-01',
      ]);
      expect(periodsEndingAt('2026-09', count: 1), ['2026-09']);
      expect(periodsEndingAt('2026-09', count: 0), isEmpty);
      expect(periodsEndingAt('2026-09', count: -1), isEmpty);
      expect(periodsEndingAt('2027-06', count: 12), hasLength(12));
      expect(periodsEndingAt('2027-06', count: 12).first, '2026-07');
    });
  });

  group('presentation', () {
    test('a period reads as a month and a year', () {
      expect(periodLabel('2026-09'), 'September 2026');
      expect(periodLabel('2026-01'), 'January 2026');
      expect(periodLabel('2026-12'), 'December 2026');
    });

    test('a malformed period is shown as itself rather than crashing', () {
      expect(periodLabel('nonsense'), 'nonsense');
      expect(periodLabel('2026-13'), '2026-13');
    });
  });

  group('the rollup document id', () {
    test('is orgId_periodId, composed in one place', () {
      expect(eprPeriodDocumentId('org_cola', '2026-09'), 'org_cola_2026-09');
    });
  });

  group('the fixed offset', () {
    test('is six hours, and the reasoning is recorded', () {
      // Bangladesh has observed DST exactly once, June–December 2009, at UTC+7.
      // Every timestamp in scope is 2026 or later. If that changes, this
      // constant is the one thing to change and historical periods must be
      // recomputed rather than reinterpreted.
      expect(dhakaOffset, const Duration(hours: 6));
    });
  });
}
