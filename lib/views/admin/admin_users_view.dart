import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/admin_users_controller.dart';
import '../../controllers/current_user_provider.dart';
import '../../core/label_format.dart';
import '../../models/user_model.dart';
import '../shared/app_shell.dart';

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

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<UserModel> _visible(List<UserModel> users) {
    final query = _search.text.trim().toLowerCase();
    final now = DateTime.now();

    final filtered = users.where((user) {
      final matchesQuery = query.isEmpty ||
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

  Future<void> _suspend(UserModel user) async {
    final choice = await showDialog<Duration?>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Suspend ${user.name}'),
        children: [
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
        ],
      ),
    );

    if (choice == null || !mounted) return;

    // Duration.zero is the sentinel for "indefinitely" — SimpleDialogOption
    // cannot return null and be distinguished from a dismissal.
    final until =
        choice == const Duration() ? null : DateTime.now().add(choice);

    await _run(
      () => ref.read(adminUserActionsProvider).suspend(user.uid, until: until),
      success: until == null
          ? '${user.name} suspended indefinitely.'
          : '${user.name} suspended until ${formatDateTime(until)}.',
    );
  }

  Future<void> _reinstate(UserModel user) async {
    await _run(
      () => ref.read(adminUserActionsProvider).reinstate(user.uid),
      success: '${user.name} reinstated.',
    );
  }

  Future<void> _run(Future<void> Function() action,
      {required String success}) async {
    try {
      await action();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(success)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('That did not work: $error')),
      );
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
          constraints:
              const BoxConstraints(maxWidth: AdminUsersView._maxContentWidth),
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text('Accounts did not load: $error'),
              ),
            ),
            data: (users) {
              final visible = _visible(users);
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Search by name or email',
                        isDense: true,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        for (final filter in _Filter.values)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(humanise(filter.name)),
                              selected: _filter == filter,
                              onSelected: (_) =>
                                  setState(() => _filter = filter),
                            ),
                          ),
                        const Spacer(),
                        Text('${visible.length} of ${users.length}',
                            style: Theme.of(context).textTheme.labelSmall),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: visible.isEmpty
                        ? const Center(child: Text('No accounts match.'))
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                            itemCount: visible.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) => _UserCard(
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

class _UserCard extends StatelessWidget {
  const _UserCard({
    required this.user,
    required this.isSelf,
    required this.onSuspend,
    required this.onReinstate,
  });

  final UserModel user;
  final bool isSelf;
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
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
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
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _Pill(
                        label: humanise(user.role),
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
                child: Icon(Icons.block,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
              )
            else if (blocked)
              TextButton(onPressed: onReinstate, child: const Text('Reinstate'))
            else
              TextButton(
                onPressed: onSuspend,
                style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error),
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
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: foreground, fontWeight: FontWeight.w600),
      ),
    );
  }
}
