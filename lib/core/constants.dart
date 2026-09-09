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

  /// A company employee doing regulatory work in the EPR producer portal
  /// (EPR-1).
  ///
  /// ## This one is disjoint, and that is the whole point
  ///
  /// The three roles above are an *inclusive* hierarchy: an Admin holds the
  /// Greenpreneur and Champion profiles, and a Greenpreneur holds Champion,
  /// because those are progressive citizen profiles on one person's account.
  ///
  /// A producer is not a further step along that ladder. Granting it Champion
  /// capability by inheritance would give a corporate compliance account a
  /// points wallet it could earn into and spend from, which is meaningless as
  /// product and an integrity hole as engineering — the party whose collected
  /// kilograms Chokro certifies would also be able to submit the disposals that
  /// produce them.
  ///
  /// So the disjointness is stated explicitly in three places that must agree:
  /// [accountProfilesForRole] in `account_profile.dart`, `UserModel.isChampion`
  /// and `isGreenpreneur`, and `isProducer()` in `firestore.rules`. Emergent
  /// disjointness — "it happens not to match any case" — is what a later
  /// refactor removes by accident.
  static const String roleProducer = 'producer';

  // User-facing role names. The values above are stable database/API wire
  // values and must not be renamed in stored documents (QA-6).
  static const String roleAdminLabel = '3ZERO Admin';
  static const String roleSellerLabel = '3ZERO Greenpreneur';
  static const String roleBuyerLabel = '3ZERO Champion';
  static const String roleProducerLabel = 'EPR Producer';

  static String roleLabel(String role) => switch (role) {
    roleAdmin => roleAdminLabel,
    roleSeller => roleSellerLabel,
    roleBuyer => roleBuyerLabel,
    roleProducer => roleProducerLabel,
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

/// Organisation-scoped capabilities inside one producer company (EPR-3).
///
/// Distinct from [AppConstants.roleProducer], which is the platform role. The
/// platform role says which workspace a person may open; these say what they
/// may do inside their own company's workspace.
///
/// Three rather than one because the three jobs are genuinely held by three
/// different people: the packaging engineer knows a bottle's gram weight, the
/// compliance officer signs the regulatory declaration, and marketing wants the
/// SDG slide. One shared login for all three is how credentials end up pasted
/// into a group chat.
///
/// These are stored strings and are never renamed once written (QA-6).
class OrgRoles {
  const OrgRoles._();

  /// Everything [reporter] can do, plus membership management and submitting a
  /// put-on-market declaration — the attested figure that becomes the
  /// denominator of a regulatory percentage.
  static const String owner = 'orgOwner';

  /// Creates and edits SKUs, requests mass verification, generates reports and
  /// downloads passports. Cannot change who is in the organisation and cannot
  /// attest a declaration.
  static const String reporter = 'orgReporter';

  /// Reads dashboards and downloads already-issued documents. Writes nothing.
  static const String viewer = 'orgViewer';

  /// Most privileged first. Used for the "at least this role" comparison, which
  /// is the only ordering that exists between them.
  static const List<String> ordered = <String>[owner, reporter, viewer];

  static const String ownerLabel = 'Owner';
  static const String reporterLabel = 'Reporter';
  static const String viewerLabel = 'Viewer';

  static String label(String orgRole) => switch (orgRole) {
    owner => ownerLabel,
    reporter => reporterLabel,
    viewer => viewerLabel,
    _ => orgRole,
  };

  static String description(String orgRole) => switch (orgRole) {
    owner =>
      'Manages members and submits put-on-market declarations, plus everything a Reporter can do.',
    reporter =>
      'Registers products, requests mass verification and generates reports.',
    viewer => 'Reads dashboards and downloads issued documents.',
    _ => 'Unrecognised role. Treated as read-only.',
  };

  static bool isValid(String orgRole) => ordered.contains(orgRole);

  /// Whether [held] carries at least the capability of [required].
  ///
  /// Fails closed: an unrecognised held role satisfies nothing, so a document
  /// written by a future release with a role this build does not know about
  /// grants no capability rather than an unbounded one.
  static bool atLeast(String held, String required) {
    final heldRank = ordered.indexOf(held);
    final requiredRank = ordered.indexOf(required);
    if (heldRank < 0 || requiredRank < 0) return false;
    return heldRank <= requiredRank;
  }
}

/// Membership lifecycle states on `organizationMembers` (EPR-3).
class OrgMemberStatus {
  const OrgMemberStatus._();

  /// Invited by email; the invitation token has not been redeemed yet. Holds no
  /// capability at all — an invitation is not a membership.
  static const String invited = 'invited';
  static const String active = 'active';
  static const String removed = 'removed';

  static const List<String> all = <String>[invited, active, removed];
}

/// Organisation lifecycle states on `organizations` (EPR-40, EPR-41).
class OrgStatus {
  const OrgStatus._();

  static const String pendingReview = 'pendingReview';
  static const String active = 'active';

  /// Portal goes read-only and no new document is issued. History is kept —
  /// suspending a producer must never delete the evidence Chokro has already
  /// certified on its behalf (EPR-47).
  static const String suspended = 'suspended';
  static const String closed = 'closed';

  static const List<String> all = <String>[
    pendingReview,
    active,
    suspended,
    closed,
  ];

  static String label(String status) => switch (status) {
    pendingReview => 'Pending review',
    active => 'Active',
    suspended => 'Suspended',
    closed => 'Closed',
    _ => status,
  };
}

/// Gazette phase-in size classes (§1, EPR-41).
///
/// The 2026 EPR guidelines phase obligation in by industry size: large
/// industries in years 1–2, medium in years 3–4, small in year 5. The class is
/// therefore not a descriptive label — it decides which targets apply and from
/// when, so it is set by Chokro during onboarding review and is server-owned.
class OrgSizeClass {
  const OrgSizeClass._();

  static const String large = 'large';
  static const String medium = 'medium';
  static const String small = 'small';

  static const List<String> all = <String>[large, medium, small];

  static String label(String value) => switch (value) {
    large => 'Large industry',
    medium => 'Medium industry',
    small => 'Small industry',
    _ => value,
  };
}

/// How an obligated entity discharges its obligation (§1.1).
///
/// Present in v1 as a schema decision, not a claim: an entity may comply alone
/// or jointly through an approved Producer Responsibility Organisation. Chokro
/// is an evidence provider today, and modelling the route now means becoming a
/// PRO later is a registration question rather than a re-modelling one.
class ComplianceRoute {
  const ComplianceRoute._();

  static const String self = 'self';
  static const String pro = 'pro';

  static const List<String> all = <String>[self, pro];

  static String label(String value) => switch (value) {
    self => 'Self-compliance',
    pro => 'Through a PRO',
    _ => value,
  };
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

  /// The Admin producer directory (EPR-40).
  ///
  /// An obligated-producer list is a national register of large industries, not
  /// a consumer collection; a few hundred is the realistic ceiling for years.
  /// Above the cap the screen says the list is partial rather than silently
  /// showing a prefix of it, which is the same discipline `salesReport` follows.
  static const int producerDirectory = 200;

  /// Members of one organisation, on the members screen.
  ///
  /// A compliance team is a handful of people. Well above any real company and
  /// far below anything that would cost.
  static const int orgMembers = 50;

  /// One organisation's activity timeline (EPR-44), newest first.
  ///
  /// A cap rather than the whole log: the audit *pack* is a job (EPR-35), and
  /// this screen is the recent view of it.
  static const int producerAuditFeed = 100;
}
