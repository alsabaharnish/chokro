import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'controllers/push_controller.dart';
import 'core/theme.dart';
import 'firebase_options.dart';
import 'routing/router.dart';
import 'services/push_service.dart';

/// Handles a push that arrives while the app is backgrounded or dead (F7.1).
///
/// This runs in a **separate isolate** with none of the app's state: no
/// Riverpod container, no navigator, no Firestore listeners. That is why it has
/// to be a top-level function and why it initialises Firebase for itself —
/// nothing from `main` is in scope here.
///
/// `@pragma('vm:entry-point')` keeps it from being tree-shaken out of a release
/// build. Without it this works in debug and silently disappears from the APK,
/// which is the kind of bug that only shows up on the demo device.
///
/// Deliberately does almost nothing. Android renders the tray notification from
/// the `notification` block in the message without our help; the only reason to
/// have a handler at all is that FCM requires one registered before any
/// background message can be delivered. Doing real work here — writing
/// Firestore, updating a badge — would mean a second code path for state that
/// the app already rebuilds from its streams the moment it resumes.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  debugPrint('[push] Background message: ${message.messageId}');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Must be registered before `runApp`, and before any message can arrive.
  // Guarded by `isSupported` because the web build has no background isolate and
  // the call throws there.
  if (PushService.isSupported) {
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  }

  runApp(const ProviderScope(child: ChokroApp()));
}

class ChokroApp extends ConsumerStatefulWidget {
  const ChokroApp({super.key});

  @override
  ConsumerState<ChokroApp> createState() => _ChokroAppState();
}

class _ChokroAppState extends ConsumerState<ChokroApp> {
  /// Lets a SnackBar be shown from outside any particular `Scaffold`.
  ///
  /// The four disposal step screens build a bare `Scaffold` rather than sitting
  /// inside `AppShell`, so there is no single subtree that covers every screen a
  /// notification might land on. A messenger key on `MaterialApp` covers all of
  /// them, including those.
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();

    // Starts the token registrar. Nothing reads its value — only its effect —
    // so it needs an explicit read to come into existence.
    ref.read(pushRegistrarProvider);

    // A notification that launched the app from a terminated state is not
    // delivered as an event, because nothing was running to receive it. It has
    // to be collected once, here, or the tap is lost.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final message = await ref.read(pushServiceProvider).initialMessage();
      if (message != null) _openFromMessage(message);
    });
  }

  void _openFromMessage(RemoteMessage message) {
    final route = routeForMessage(message);
    if (route == null) return;
    if (!mounted) return;
    ref.read(routerProvider).go(route);
  }

  void _showBanner(RemoteMessage message) {
    final messenger = _messengerKey.currentState;
    if (messenger == null) return;

    final route = routeForMessage(message);

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(bannerTextFor(message)),
          duration: const Duration(seconds: 6),
          action: route == null
              ? null
              : SnackBarAction(
                  label: 'View',
                  onPressed: () => ref.read(routerProvider).go(route),
                ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);

    // Foreground messages. Android raises no tray notification while the app is
    // on screen — correct, but it means nothing at all appears unless the app
    // draws it. A SnackBar is the right weight for "50 points added" arriving
    // while the user is already looking at the app, and it avoids taking on
    // flutter_local_notifications purely to duplicate a message the user can
    // already see.
    ref.listen<AsyncValue<RemoteMessage>>(pushMessageProvider, (_, next) {
      final message = next.value;
      if (message != null) _showBanner(message);
    });

    // A tray notification tapped while the app was backgrounded.
    ref.listen<AsyncValue<RemoteMessage>>(pushOpenedProvider, (_, next) {
      final message = next.value;
      if (message != null) _openFromMessage(message);
    });

    return MaterialApp.router(
      title: 'Chokro',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _messengerKey,
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
