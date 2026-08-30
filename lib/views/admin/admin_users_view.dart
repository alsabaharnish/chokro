import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/admin_users_controller.dart';
import '../../controllers/current_user_provider.dart';
import '../../core/constants.dart';
import '../../core/label_format.dart';
import '../../core/theme.dart';
import '../../models/user_model.dart';
import '../shared/app_shell.dart';
import '../shared/app_snackbar.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';
import '../shared/notice_card.dart';
import '../../core/network_errors.dart';

/// Administrator account management (F5.2) with temporary suspension (F5.3).
///
/// The list distinguishes four states, not two. "Suspended" and "suspension
/// lapsed" look identical in the `status` field — both read `suspended` — and
/// telling them apart is the whole point of the screen: it explains why an
/// account marked suspended is submitting again.
class AdminUsersView extends ConsumerStatefulWidget {
  const AdminUsersView({super.key});

  static const double _maxContentWidth = 820;

  @override
  ConsumerState<AdminUsersView> createState() => _AdminUsersViewState();
}

enum _Filter { all, active, suspended }

class _AdminUsersViewState extends ConsumerState<AdminUsersView> {
  final TextEditingController _search = TextEditingController();
  _Filter _filter = _Filter.all;
  final Set<String> _busyUids = <String>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<UserModel> _visible(List<UserModel> users) {
    final query = _search.text.trim().toLowerCase();
    final now = DateTime.now();

    final filtered = users.where((user) {
      final matchesQuery =
          query.isEmpty ||
          user.name.toLowerCase().contains(query) ||
          user.email.toLowerCase().contains(query);
      if (!matchesQuery) return false;

      return switch (_filter) {
        _Filter.all => true,
        _Filter.active => user.isActiveAt(now),
        _Filter.suspended => !user.isActiveAt(now),
      };
    }).toList();

    // Blocked accounts first — the reason to open this screen is usually one of
    // them — then lapsed suspensions, then everyone else by name.
    filtered.sort((a, b) {
      int rank(UserModel u) {
        if (!u.isActiveAt(now)) return 0;
        if (u.hasLapsedSuspension) return 1;
        return 2;
      }

      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return filtered;
  }

  bool _looksLikeEmail(String value) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value.trim());

  void _clearSearchAndFilter() {
    setState(() {
      _search.clear();
      _filter = _Filter.all;
    });
  }

  Future<void> _suspend(UserModel user) async {
    final consequences = <String>[
      if (user.isSeller)
        'Their listings will be hidden from the shop while this lasts, and '
            'restored when you reinstate them.',
      if (user.isAdmin)
        'This is a 3ZERO Admin. Suspending them revokes every administrative '
            'privilege until reinstated.',
    ];
    final choice = await showDialog<Duration?>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Suspend ${user.name}'),
        children: [
          if (consequences.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text(
                consequences.join('\n\n'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          for (final option in const [
            (label: '24 hours', duration: Duration(hours: 24)),
            (label: '7 days', duration: Duration(days: 7)),
            (label: '30 days', duration: Duration(days: 30)),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(option.duration),
              child: Text(option.label),
            ),
          const Divider(),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(const Duration()),
            child: Text(
              'Indefinitely',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
            child: Text(
              'A timed suspension lifts itself when the date passes. Nothing '
              'has to run for that to happen — the expiry is checked whenever '
              'the account tries to act.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (choice == null || !mounted) return;

    // Duration.zero is the sentinel for "indefinitely" — SimpleDialogOption
    // cannot return null and be distinguished from a dismissal.
    final until = choice == const Duration()
        ? null
        : DateTime.now().add(choice);

    await _run(
      user.uid,
      () => ref
          .read(adminUserActionsProvider)
          .suspend(user.uid, until: until, isSeller: user.isSeller),
      name: user.name,
      success: until == null
          ? '${user.name} suspended indefinitely.'
          : '${user.name} suspended until ${formatDateTime(until)}.',
      hiding: true,
    );
  }

  Future<void> _reinstate(UserModel user) async {
    await _run(
      user.uid,
      () => ref
          .read(adminUserActionsProvider)
          .reinstate(user.uid, isSeller: user.isSeller),
      name: user.name,
      success: '${user.name} reinstated.',
      hiding: false,
    );
  }

  /// Runs an account action and reports on **both** halves of it.
  ///
  /// Suspending a seller writes the account and then sweeps their catalogue
  /// (§7.4). The two cannot be atomic — one is a Firestore write from here, the
  /// other an HTTP call — so a partial result is possible and is stated rather
  /// than smoothed over. "Suspended, but their shop is still open" is precisely
  /// the sentence an administrator needs, and it comes with a way to retry.
  /// The account whose suspend/reinstate is still in flight.
  ///
  /// The action is two operations — a Firestore write, then an HTTP catalogue
  /// sweep bounded by `ApiConfig.coldStartTimeout` (90 s). The Firestore half
  /// echoes straight back through `allUsersProvider`, so without this the card
  /// flipped to the opposite state and offered the *opposite* button while the
  /// sweep was still running: an admin could press Reinstate on an account
  /// whose listings were still being hidden.
  Future<void> _run(
    String uid,
    Future<SuspensionOutcome> Function() action, {
    required String name,
    required String success,
    required bool hiding,
  }) async {
    if (_busyUids.contains(uid)) return;
    setState(() => _busyUids.add(uid));
    final notify = AppSnackBar.of(context);
    try {
      final outcome = await action();
      if (!mounted) return;

      final message = StringBuffer(success);
      if (!outcome.sweptCleanly) {
        message.write(
          hiding
              ? ' Their listings are STILL VISIBLE — ${outcome.listingsProblem}'
              : ' Their hidden listings were not restored — '
                    '${outcome.listingsProblem}',
        );
      } else if (outcome.listingsChanged > 0) {
        final n = outcome.listingsChanged;
        message.write(
          hiding
              ? ' ${n == 1 ? '1 listing' : '$n listings'} hidden from the shop.'
              : ' ${n == 1 ? '1 listing' : '$n listings'} back on the shop.',
        );
      }

      if (outcome.sweptCleanly) {
        notify.success(message.toString());
      } else {
        // The account write landed but its security-related catalogue sweep
        // did not. That is a partial failure, not a success with a footnote.
        notify.failure(message.toString());
      }
    } catch (error) {
      if (!mounted) return;
      notify.failure(
        '$name was not ${hiding ? 'suspended' : 'reinstated'}. '
        '${friendlyErrorMessage(error)}',
      );
    } finally {
      if (mounted) setState(() => _busyUids.remove(uid));
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(allUsersProvider);
    final currentUid = ref.watch(currentUidProvider);

    return AppShell(
      title: 'Accounts',
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AdminUsersView._maxContentWidth,
          ),
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => ErrorRetry(
              error: error,
              title: 'Accounts',
              onRetry: () => ref.invalidate(allUsersProvider),
            ),
            data: (page) {
              final exactQuery = _search.text.trim();
              final query = exactQuery.toLowerCase();
              final searchesWholeDirectory =
                  page.truncated && _looksLikeEmail(exactQuery);
              final exactAsync = searchesWholeDirectory
                  ? ref.watch(adminUserByEmailProvider(exactQuery))
                  : null;
              final candidates = [...page.users];
              final exactMatch = exactAsync?.value;
              if (exactMatch != null &&
                  candidates.every((user) => user.uid != exactMatch.uid)) {
                candidates.add(exactMatch);
              }
              final visible = _visible(candidates);
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        hintText: 'Search by name or exact email',
                        isDense: true,
                        suffixIcon: _search.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear search',
                                onPressed: () {
                                  setState(_search.clear);
                                },
                                icon: const Icon(Icons.clear),
                              ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _FilterBar(
                      selected: _filter,
                      visibleCount: visible.length,
                      totalCount: page.users.length,
                      atCap: page.truncated,
                      onSelected: (filter) => setState(() => _filter = filter),
                    ),
                  ),
                  if (page.truncated)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: NoticeCard(
                        icon: Icons.info_outline,
                        title: 'The account directory is capped',
                        message:
                            'Showing the first 200 accounts in name order. '
                            'Enter a complete email address to search every '
                            'account.',
                      ),
                    ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: exactAsync?.isLoading == true && visible.isEmpty
                        ? const ContentLoading(label: 'Searching all accounts…')
                        : exactAsync?.hasError == true && visible.isEmpty
                        ? ErrorRetry(
                            error: exactAsync!.error!,
                            title: 'Account search',
                            onRetry: () => ref.invalidate(
                              adminUserByEmailProvider(exactQuery),
                            ),
                          )
                        : visible.isEmpty
                        ? ContentEmpty(
                            icon: Icons.person_search_outlined,
                            title: 'No accounts match',
                            message: page.truncated && query.isNotEmpty
                                ? _looksLikeEmail(query)
                                      ? 'No account has that exact email address.'
                                      : 'No loaded account matches. Enter a '
                                            'complete email address to search '
                                            'the full directory.'
                                : 'No account matches this search and filter.',
                            actionLabel: 'Clear search and filter',
                            onAction: _clearSearchAndFilter,
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                            itemCount: visible.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) => _UserCard(
                              isBusy: _busyUids.contains(visible[index].uid),
                              user: visible[index],
                              isSelf: visible[index].uid == currentUid,
                              onSuspend: () => _suspend(visible[index]),
                              onReinstate: () => _reinstate(visible[index]),
                            ),
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.selected,
    required this.visibleCount,
    required this.totalCount,
    required this.atCap,
    required this.onSelected,
  });

  final _Filter selected;
  final int visibleCount;
  final int totalCount;
  final bool atCap;
  final ValueChanged<_Filter> onSelected;

  @override
  Widget build(BuildContext context) {
    final filters = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final filter in _Filter.values)
          ChoiceChip(
            label: Text(humanise(filter.name)),
            selected: selected == filter,
            onSelected: (_) => onSelected(filter),
          ),
      ],
    );
    final count = Text(
      '$visibleCount of $totalCount${atCap ? '+' : ''}',
      style: Theme.of(context).textTheme.labelSmall,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 520) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              filters,
              const SizedBox(height: 6),
              Align(alignment: Alignment.centerRight, child: count),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: filters),
            const SizedBox(width: 12),
            count,
          ],
        );
      },
    );
  }
}

class _UserCard extends StatelessWidget {
  const _UserCard({
    required this.user,
    required this.isSelf,
    required this.isBusy,
    required this.onSuspend,
    required this.onReinstate,
  });

  final UserModel user;
  final bool isSelf;

  /// True while this account's suspend or reinstate is still running.
  final bool isBusy;

  final VoidCallback onSuspend;
  final VoidCallback onReinstate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocked = !user.isActive;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: blocked
                  ? theme.colorScheme.errorContainer
                  : theme.colorScheme.surfaceContainerHighest,
              child: Text(
                user.name.isEmpty ? '?' : user.name[0].toUpperCase(),
                style: TextStyle(
                  color: blocked
                      ? theme.colorScheme.onErrorContainer
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          user.name,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (isSelf) ...[
                        const SizedBox(width: 6),
                        Text('(you)', style: theme.textTheme.labelSmall),
                      ],
                    ],
                  ),
                  Text(
                    user.email,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _Pill(
                        label: AppConstants.roleLabel(user.role),
                        background: theme.colorScheme.surfaceContainerHighest,
                        foreground: theme.colorScheme.onSurfaceVariant,
                      ),
                      _StateChip(user: user),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (isSelf)
              Tooltip(
                message: 'You cannot suspend your own account',
                child: Icon(
                  Icons.block,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else if (isBusy)
              // Named, not a bare spinner: the sweep can run for 90 seconds and
              // the admin needs to know the account write already landed.
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: AppTheme.gapSm),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: AppTheme.gapSm),
                    Text('Updating…'),
                  ],
                ),
              )
            else if (blocked)
              TextButton(onPressed: onReinstate, child: const Text('Reinstate'))
            else
              TextButton(
                onPressed: onSuspend,
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                child: const Text('Suspend'),
              ),
          ],
        ),
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.user});

  final UserModel user;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (user.isSuspendedIndefinitely) {
      return _Pill(
        label: 'Suspended indefinitely',
        background: scheme.errorContainer,
        foreground: scheme.onErrorContainer,
      );
    }

    if (user.isSuspendedTemporarily) {
      return _Pill(
        label: 'Suspended until ${formatDateTime(user.suspendedUntil)}',
        background: scheme.errorContainer,
        foreground: scheme.onErrorContainer,
      );
    }

    if (user.hasLapsedSuspension) {
      // Status still reads 'suspended' in Firestore. Saying so prevents an
      // administrator re-suspending someone whose time is already served.
      return _Pill(
        label: 'Suspension lapsed ${formatAge(user.suspendedUntil)}',
        background: scheme.tertiaryContainer,
        foreground: scheme.onTertiaryContainer,
      );
    }

    return _Pill(
      label: 'Active',
      background: scheme.secondaryContainer,
      foreground: scheme.onSecondaryContainer,
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
