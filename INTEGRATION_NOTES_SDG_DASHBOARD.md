# SDG Admin Dashboard — Integration Notes

This revision adds an SDG-aligned reporting workspace to the existing 3ZERO
Admin dashboard. It is a presentation and reliability change: no new Firestore
collection, stored score, security-rule permission, server endpoint, or index is
required.

## Product shape

`/admin/dashboard` keeps one navigation destination and uses two internal tabs:

- **SDG impact** — all-time contribution signals, methodology, provenance, and
  explicit claim boundaries
- **Platform data** — operational counters, live inclusive profile totals, and
  existing Admin shortcuts

This preserves the tested five-item mobile Admin navigation while giving the
larger web layout enough room for comparative reporting. Both tabs remain usable
on mobile; cards collapse to one column and the tab labels remain visible at 320
logical pixels with 2× text scaling.

## SDG mapping and reporting contract

The dashboard uses selected UN targets as an alignment framework, not as a
certification or official measurement system.

| Alignment | Chokro signal | Source fields | Required interpretation |
|---|---|---|---|
| [Goal 8, Target 8.3](https://sdgs.un.org/goals/goal8) | Greenpreneur-capable accounts and marketplace activity | inclusive `users.role` count, `ordersCreated`, `salesPayable` | Accounts include Admins because profiles are inherited. Orders are placed, not necessarily completed. Payable value is recorded at checkout after points, not paid seller income or job creation. |
| [Goal 11, Target 11.6](https://sdgs.un.org/goals/goal11) | Use of the location-aware waste-verification flow | `disposalsApproved` | A submission is an approved activity record, not kilograms, tonnes, or proof of final processing. |
| [Goal 12, Target 12.5](https://sdgs.un.org/goals/goal12) | Approved disposal and sustainable-product ordering | `disposalsApproved`, `ordersCreated` | The disposal signal overlaps with Goal 11. Goal cards are not additive. |
| [Goal 13, Target 13.3](https://sdgs.un.org/goals/goal13) | Reviewed eco-actions and initiative participation | `claimsApproved`, `donationsReceived`, `pointsDonated` | These are participation records. Points are neither cash nor deployed funds, and the values do not estimate avoided emissions. |

All values are all-time because `stats/platform` has no reporting-period or
baseline dimensions. No progress bar or percentage-to-target is shown. Adding
verified weight, outcome, or period reporting later requires an auditable source
schema first; it must not be inferred from submission counts.

## Data and failure behaviour

- `SdgImpactSnapshot` centralises the conservative mapping from
  `PlatformStats`; the view contains no hidden impact arithmetic.
- Negative or malformed persisted counters parse to zero.
- `hasAnyCounterActivity` checks every counter, including claims, contributions,
  and prototype-payment-only records, before describing a snapshot as empty.
- Firestore snapshot metadata is exposed as `isFromCache`. A missing cache-only
  stats document becomes an unavailable state, not a false zero; a
  server-confirmed missing document remains a valid zero baseline.
- Profile totals are live inclusive counts. A bounded directory result uses a
  trailing `+` and is described as a floor.
- A low-frequency clock re-evaluates temporary suspensions every minute even
  when Firestore emits no account change.
- Platform-counter and account-directory states render independently. A failure
  in one does not erase valid data or navigation from the other.

## Main implementation files

- `lib/models/sdg_impact_model.dart` — testable signal derivation
- `lib/models/stats_model.dart` — safe counter parsing and activity detection
- `lib/services/stats_service.dart` — cache/server provenance and unavailable
  state
- `lib/controllers/dashboard_controller.dart` — live account totals and
  suspension clock
- `lib/views/admin/sdg_dashboard.dart` — SDG view and methodology
- `lib/views/admin/admin_dashboard_view.dart` — two-tab shell and resilient
  platform-data view

## Verification

Focused tests cover signal derivation, malformed/negative counters, grouped
number formatting, temporary-suspension expiry, methodology disclosure,
cache/bounded-source labels, independent error states, readable goal badges,
and 320-pixel large-text layout. At completion, `flutter analyze lib test` is
clean, all 687 Flutter tests pass, and `flutter build web` succeeds.
