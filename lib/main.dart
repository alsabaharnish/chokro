import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme.dart';
import 'firebase_options.dart';
import 'routing/router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const ProviderScope(child: ChokroApp()));
}

class ChokroApp extends ConsumerWidget {
  const ChokroApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'Chokro',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      // Follows the device. The app is used outdoors at a bin and indoors at a
      // desk, and a user who has chosen dark mode system-wide has chosen it here
      // too — there was previously no dark theme at all, so every screen was a
      // full-brightness white panel at night.
      themeMode: ThemeMode.system,
      routerConfig: router,
    );
  }
}
