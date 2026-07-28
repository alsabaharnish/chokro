import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/wallet_controller.dart';
import '../shared/app_shell.dart';

class HomeView extends ConsumerWidget {
  const HomeView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(currentUserProvider);
    final walletAsync = ref.watch(walletProvider);
    final theme = Theme.of(context);

    return AppShell(
      title: 'Chokro',
      child: userAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (user) {
          if (user == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Hello, ${user.name}',
                            style: theme.textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ),
                        Chip(
                          label: Text(user.role.toUpperCase()),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                    if (!user.isActive)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Card(
                          color: theme.colorScheme.errorContainer,
                          child: const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text(
                              'This account is suspended. '
                              'Most actions are unavailable.',
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 24),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Points balance',
                                style: theme.textTheme.labelLarge),
                            const SizedBox(height: 8),
                            walletAsync.when(
                              loading: () => const SizedBox(
                                height: 40,
                                child: Center(
                                  child: SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                ),
                              ),
                              error: (e, _) => Text('Unavailable: $e'),
                              data: (wallet) => Text(
                                '${wallet?.balance ?? 0}',
                                style: theme.textTheme.displaySmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Card(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: const Padding(
                        padding: EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Coming in the next milestone',
                                style: TextStyle(fontWeight: FontWeight.bold)),
                            SizedBox(height: 8),
                            Text('Scan a bin QR code, photograph your disposal, '
                                'and earn points once an admin approves it.'),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
