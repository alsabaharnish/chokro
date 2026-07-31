"""Wire F5.2 / F5.3 — admin account management and lazy suspension expiry.

Run from the repository root:  python3 patch_suspension.py

Four edits across four files, applied all-or-nothing: every anchor is checked
before anything is written. Idempotent.
"""

import sys

# ---------------------------------------------------------------------------
# 1. firestore.rules — isActive() learns about suspendedUntil
# ---------------------------------------------------------------------------

RULES = 'firestore.rules'

RULES_ANCHOR = """    function isActive() {
      return get(/databases/$(database)/documents/users/$(request.auth.uid)).data.status == 'active';
    }"""

RULES_NEW = """    function userData() {
      return get(/databases/$(database)/documents/users/$(request.auth.uid)).data;
    }

    // Whether this account may act (F5.3).
    //
    // A suspension is either indefinite or timed. Nothing in this system runs
    // on a schedule — Cloud Functions need a billing card and the free Render
    // instance sleeps — so no process exists that could flip `status` back to
    // 'active' when a timed suspension runs out. The expiry is therefore
    // resolved here, at request time, exactly as lockoutActive() resolves its
    // own window a few lines below.
    //
    // A missing `suspendedUntil` means the suspension is indefinite, so its
    // absence must never read as "expired" — hence the explicit key check
    // rather than a comparison against a null.
    //
    // Mirrored by UserModel.isActiveAt, and proven by
    // rules_test/suspension.rules.test.js.
    function isActive() {
      return isSignedIn() && (
        userData().status == 'active'
        || (
          userData().status == 'suspended'
          && 'suspendedUntil' in userData()
          && userData().suspendedUntil < request.time
        )
      );
    }"""

# ---------------------------------------------------------------------------
# 2. user_service.dart — suspend with an optional expiry
# ---------------------------------------------------------------------------

SERVICE = 'lib/services/user_service.dart'

SERVICE_ANCHOR = """  Future<void> suspendUser(String uid) =>
      _db.collection('users').doc(uid).update({
        'status': AppConstants.statusSuspended,
        'suspendedAt': FieldValue.serverTimestamp(),
      });

  Future<void> reinstateUser(String uid) =>
      _db.collection('users').doc(uid).update({
        'status': AppConstants.statusActive,
        'reinstatedAt': FieldValue.serverTimestamp(),
      });"""

SERVICE_NEW = """  /// Suspends [uid], indefinitely when [until] is null (F5.2, F5.3).
  ///
  /// A timed suspension stores its expiry and nothing further happens. No job
  /// lifts it later — readers resolve the date themselves, in
  /// `UserModel.isActiveAt` and in `isActive()` in the rules.
  ///
  /// LIMITATION: [until] is computed from the administrator's device clock,
  /// because Firestore cannot offset a server timestamp within a single write.
  /// A skewed admin clock produces a skewed expiry. The comparison it is later
  /// checked against is server-side (`request.time`), so this affects how long
  /// a suspension lasts — never whether the suspended user can shorten it.
  Future<void> suspendUser(String uid, {DateTime? until}) =>
      _db.collection('users').doc(uid).update({
        'status': AppConstants.statusSuspended,
        'suspendedAt': FieldValue.serverTimestamp(),
        'suspendedUntil':
            until == null ? FieldValue.delete() : Timestamp.fromDate(until),
      });

  /// Lifts a suspension and clears any expiry, so a later indefinite
  /// suspension cannot inherit a stale date.
  Future<void> reinstateUser(String uid) =>
      _db.collection('users').doc(uid).update({
        'status': AppConstants.statusActive,
        'reinstatedAt': FieldValue.serverTimestamp(),
        'suspendedUntil': FieldValue.delete(),
      });"""

# ---------------------------------------------------------------------------
# 3. router.dart — /admin/users
# ---------------------------------------------------------------------------

ROUTER = 'lib/routing/router.dart'

ROUTER_IMPORT_ANCHOR = "import '../views/admin/points_policy_view.dart';"
ROUTER_IMPORT_NEW = "import '../views/admin/admin_users_view.dart';"

ROUTE_ANCHOR = "      GoRoute(\n        path: '/admin/points',"
ROUTE_NEW = """      GoRoute(
        path: '/admin/users',
        builder: (context, state) => const AdminUsersView(),
        redirect: (context, state) {
          final user = currentUser.value;
          if (user == null) return '/login';
          if (!user.isAdmin) return '/home';
          return null;
        },
      ),
"""

# ---------------------------------------------------------------------------
# 4. home_view.dart — admin card
# ---------------------------------------------------------------------------

HOME = 'lib/views/home/home_view.dart'

HOME_ANCHOR = """                      const SizedBox(height: 16),
                      Card(
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => context.push('/admin/points'),"""

HOME_NEW = """                      const SizedBox(height: 16),
                      Card(
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => context.push('/admin/users'),
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 24,
                                  backgroundColor:
                                      theme.colorScheme.secondaryContainer,
                                  child: Icon(
                                    Icons.people_outline,
                                    color:
                                        theme.colorScheme.onSecondaryContainer,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Accounts',
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                                fontWeight: FontWeight.bold),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Suspend or reinstate an account.',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right),
                              ],
                            ),
                          ),
                        ),
                      ),
"""


EDITS = [
    (RULES, [(RULES_ANCHOR, RULES_NEW, 'isActive() in firestore.rules')]),
    (SERVICE, [(SERVICE_ANCHOR, SERVICE_NEW, 'suspendUser / reinstateUser')]),
    (ROUTER, [
        (ROUTER_IMPORT_ANCHOR, ROUTER_IMPORT_NEW + '\n' + ROUTER_IMPORT_ANCHOR,
         'points policy import'),
        (ROUTE_ANCHOR, ROUTE_NEW + ROUTE_ANCHOR, '/admin/points route'),
    ]),
    (HOME, [(HOME_ANCHOR, HOME_NEW + HOME_ANCHOR, 'admin points policy card')]),
]

SENTINEL = (ROUTER, ROUTER_IMPORT_NEW)


def main() -> int:
    sources = {}

    # Read everything and verify every anchor before writing anything.
    for path, edits in EDITS:
        try:
            source = open(path).read()
        except FileNotFoundError:
            print(f'not found: {path} — run from the repository root')
            return 1

        if path == SENTINEL[0] and SENTINEL[1] in source:
            print('already patched, nothing to do')
            return 0

        for anchor, _, description in edits:
            if anchor not in source:
                print(f'anchor missing in {path}: {description}')
                print('nothing was written — the file has diverged')
                return 1
        sources[path] = source

    for path, edits in EDITS:
        source = sources[path]
        for anchor, replacement, _ in edits:
            source = source.replace(anchor, replacement, 1)
        open(path, 'w').write(source)

    print('patched:')
    print('  firestore.rules       isActive() resolves suspendedUntil')
    print('  user_service.dart     suspendUser({until}), reinstate clears it')
    print('  router.dart           /admin/users, admin-guarded')
    print('  home_view.dart        Accounts card')
    return 0


if __name__ == '__main__':
    sys.exit(main())
