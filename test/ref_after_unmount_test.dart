/// Does `WidgetRef` really throw once the widget is gone?
///
/// A recovered finding said `declaration_view.dart`'s `_run` guards every
/// `setState` with `if (mounted)` but calls `ref.invalidate` after an await
/// without one, and that leaving the screen mid-save therefore produces an
/// uncaught error rather than a completed refresh.
///
/// That is a claim about Riverpod's behaviour rather than about our code, and
/// the remedy differs by the answer: a real throw needs a guard, a silent no-op
/// needs nothing at all. So it is established here instead of assumed — on the
/// smallest widget that reproduces the shape, because the screen it was found
/// on is nine hundred lines and would prove the same thing more slowly.
///
/// The answer is that it throws, which is why five call sites across the app
/// now check `mounted` before touching `ref` after an await.
library;

import 'dart:async';


import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _refreshed = Provider<int>((ref) => 1);

class _Saver extends ConsumerStatefulWidget {
  const _Saver({super.key, required this.work, required this.guard});

  final Future<void> Function() work;

  /// Whether to check `mounted` before touching `ref` — the fix under test.
  final bool guard;

  @override
  ConsumerState<_Saver> createState() => _SaverState();
}

class _SaverState extends ConsumerState<_Saver> {
  Object? caught;

  Future<void> run() async {
    try {
      await widget.work();
      if (widget.guard && !mounted) return;
      ref.invalidate(_refreshed);
    } catch (error) {
      caught = error;
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Future<_SaverState> _startSave(
  WidgetTester tester,
  Completer<void> completer, {
  required bool guard,
}) async {
  final key = GlobalKey<_SaverState>();

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: _Saver(key: key, work: () => completer.future, guard: guard),
      ),
    ),
  );

  final state = key.currentState!;
  // Deliberately not awaited: the save is meant to be in flight while the
  // widget is disposed, which is the situation under test.
  unawaited(state.run());
  return state;
}

/// Replaces the tree, disposing the widget while its save is still in flight.
Future<void> _navigateAway(WidgetTester tester) => tester.pumpWidget(
  const ProviderScope(child: MaterialApp(home: SizedBox.shrink())),
);

void main() {
  testWidgets('touching ref after the widget is gone throws', (tester) async {
    final completer = Completer<void>();
    final state = await _startSave(tester, completer, guard: false);

    await _navigateAway(tester);
    completer.complete();
    await tester.pumpAndSettle();

    // The finding's claim, confirmed. Not a debug-only assert: a real error,
    // which in production escapes into a Future nothing awaits.
    expect(state.caught, isNotNull);
    expect(
      state.caught.toString(),
      contains('unmounted'),
    );
  });

  testWidgets('the mounted guard makes it a no-op', (tester) async {
    final completer = Completer<void>();
    final state = await _startSave(tester, completer, guard: true);

    await _navigateAway(tester);
    completer.complete();
    await tester.pumpAndSettle();

    expect(state.caught, isNull);
  });

  testWidgets('the guard does not suppress the refresh while mounted', (
    tester,
  ) async {
    // The guard must not become "never refresh". A widget still on screen when
    // its save completes has to get its providers invalidated as before.
    final completer = Completer<void>();
    final state = await _startSave(tester, completer, guard: true);

    completer.complete();
    await tester.pumpAndSettle();

    expect(state.mounted, isTrue);
    expect(state.caught, isNull);
  });
}
