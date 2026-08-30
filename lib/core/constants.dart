class AppConstants {
  // responsive breakpoint
  static const double webBreakpoint = 900.0;

  /// Minimum height before the wide layout's navigation rail is used.
  ///
  /// Width alone was not enough. A large phone in landscape (932x430, 915x412)
  /// clears 900 wide while being barely 430 tall, so it took the rail branch —
  /// and a rail sized for a desktop window cannot fit five destinations in
  /// 430 px, so the bottom ones were painted outside it and could not be
  /// tapped. Rotating the phone lost navigation destinations.
  static const double railMinHeight = 600.0;

  // user roles
  static const String roleAdmin = 'admin';
  static const String roleSeller = 'seller';
  static const String roleBuyer = 'buyer';

  // User-facing role names. The values above are stable database/API wire
  // values and must not be renamed in stored documents.
  static const String roleAdminLabel = '3ZERO Admin';
  static const String roleSellerLabel = '3ZERO Greenpreneur';
  static const String roleBuyerLabel = '3ZERO Champion';

  static String roleLabel(String role) => switch (role) {
    roleAdmin => roleAdminLabel,
    roleSeller => roleSellerLabel,
    roleBuyer => roleBuyerLabel,
    _ => role,
  };

  // user status
  static const String statusActive = 'active';
  static const String statusSuspended = 'suspended';

  // seller application status
  static const String statusPending = 'pending';
  static const String statusApproved = 'approved';
  static const String statusRejected = 'rejected';
}

/// Ceilings on every collection read (NFR-2).
///
/// ## Most are caps, not page sizes
///
/// There is no cursor-based `startAfter` paging in this codebase. Most values
/// are therefore the most their screen will ever show, and each realistic cap
/// is disclosed. [photocardPage], [ledger], [orders], and [sellerListings] are
/// page increments: those screens grow a bounded query only when the user asks
/// for older records, keeping history reachable without opening an unbounded
/// stream.
///
/// ## Why they exist at all
///
/// Eleven streams previously had no limit, including one over the whole `users`
/// collection and four over admin queues. Unbounded reads are a cost problem at
/// any size and a denial-of-service surface at this one: `claims` has no
/// lockout and no per-period creation limit in the rules, so an account can
/// inject unlimited pending claims, and an unbounded queue turns that into an
/// admin screen that will not load. A cap makes the queue degrade — showing the
/// oldest fifty — rather than fail.
///
/// The numbers are set well above a plausible demonstration and well below what
/// would hurt.
class QueryLimits {
  const QueryLimits._();

  /// Admin review queues: disposals, claims, appeals, seller applications.
  /// Oldest first, so a cap keeps the items that have waited longest.
  static const int reviewQueue = 50;

  /// Approved eco-actions load in bounded increments; unlike the review queue,
  /// this screen offers an explicit "load older" path.
  static const int photocardPage = 50;

  /// A user's own submissions, claims or appeals. Newest first.
  static const int ownHistory = 50;

  /// Ledger entries on the wallet screen.
  static const int ledger = 50;

  /// Orders, for either party.
  static const int orders = 40;

  /// Orders read for a Greenpreneur's sales report.
  ///
  /// Deliberately far above [orders]. The list screen shows the recent ones and
  /// a cap there costs a seller nothing; the report *totals* them, and a total
  /// computed over the most recent forty orders while claiming to cover "all
  /// time" is not a degraded answer but a wrong one, with nothing about it that
  /// looks wrong.
  ///
  /// Still a cap rather than an unbounded read, for the reason every other limit
  /// here exists. When it binds, `SellerSalesReport.truncated` carries that to
  /// the screen and the screen says so, so the figures are never quietly partial.
  static const int salesReport = 500;

  /// The buyer-facing catalogue.
  static const int catalog = 30;

  /// A seller's own listings, active and delisted.
  static const int sellerListings = 100;

  /// Registered bins. Comfortably above any real deployment of this project.
  static const int bins = 200;

  /// Accounts on the administrator's list.
  static const int accounts = 200;

  /// Decisions attributed to one administrator in one local day.
  static const int adminDailyReviews = 250;
}
