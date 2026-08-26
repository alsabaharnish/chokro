import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'controllers/push_controller.dart';
import 'core/theme.dart';
import 'services/server_warmup.dart';
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

  try {
    await _initialise();
  } catch (error, stack) {
    // Unguarded, a failure here left a black screen and nothing else: no
    // message, no retry, no clue. `DefaultFirebaseOptions.currentPlatform`
    // throws `UnsupportedError` on macOS, Windows and Linux — and macOS is one
    // of the run targets `core/api_config.dart` documents — and
    // `initializeApp` throws on a malformed or missing platform config.
    debugPrint('[startup] Initialisation failed: $error\n$stack');
    runApp(_StartupFailureApp(error: error));
    return;
  }

  runApp(const ProviderScope(child: ChokroApp()));
}

/// Everything that must succeed before the app can be shown.
Future<void> _initialise() async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Offline persistence, set explicitly rather than left to the platform
  // default (NFR-7).
  //
  // Mobile enables it by default and **web does not**, so the two targets were
  // silently behaving differently: on web every read went to the network and a
  // dropped connection emptied every screen. Stating it here makes the
  // behaviour one decision rather than two platform accidents.
  //
  // WHAT THIS DOES AND DOES NOT BUY.
  // It gives cached reads and queued *writes* — a cart change or a profile edit
  // made offline syncs on reconnection. It does **not** make the disposal flow
  // work offline, and NFR-7's roadside-bin scenario is still unmet: a submission
  // uploads its photograph to the trusted service over HTTP *before* the
  // Firestore document is created, so with no connection the upload throws and
  // no document is ever written for the queue to hold.
  //
  // Fixing that properly means writing the pending document first and attaching
  // the photograph afterwards — which the rules currently forbid, since
  // `validDisposalCreate` requires a trusted photo reference at creation and
  // that requirement is load-bearing. It is recorded as a known limitation
  // rather than worked around here.
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );

  // Must be registered before `runApp`, and before any message can arrive.
  // Guarded by `isSupported` because the web build has no background isolate and
  // the call throws there.
  if (PushService.isSupported) {
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  }

  // Starts Render's instance waking while the user is still signing in, so the
  // first screen that needs the service is not the one paying for the cold
  // start. Fire-and-forget: it never blocks startup and never surfaces an error.
  ServerWarmup.ping();
}

/// The last-resort screen: initialisation failed, so there is no Riverpod
/// container, no router and no Firebase to lean on.
///
/// Deliberately not `StartupErrorView` — that one lives inside the provider
/// scope and retries providers, neither of which exists yet here.
class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chokro',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: Builder(
        builder: (context) {
          final theme = Theme.of(context);
          return Scaffold(
            body: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(AppTheme.gapXl),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: AppTheme.maxFormWidth,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.cloud_off_outlined,
                          size: 56,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(height: AppTheme.gapMd),
                        Text(
                          'Chokro could not start',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: AppTheme.gapSm),
                        Text(
                          'The app could not set up its connection to Firebase. '
                          'This usually means the build is missing its '
                          'configuration for this platform, or this platform is '
                          'not one Chokro supports yet.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: AppTheme.gapLg),
                        // The technical detail, for whoever is running it —
                        // selectable, because the useful thing to do with it is
                        // paste it somewhere.
                        SelectableText(
                          '$error',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
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

  /// Built once rather than on every `build`.
  ///
  /// `AppTheme.light()` and `AppTheme.dark()` were called inline in the widget
  /// tree below, so each rebuild of this widget re-ran `ColorScheme.fromSeed`
  /// twice — that is the HCT colour-science pipeline, plus
  /// `Typography.material2021` and about twenty-five component themes, for a
  /// result that cannot change while the app is running.
  ///
  /// Held per instance rather than in a `static`, deliberately: `_build` reads
  /// `defaultTargetPlatform` for its typography and page transitions, and a
  /// process-wide cache would hand a stale theme to any test that overrides the
  /// platform.
  late final ThemeData _light = AppTheme.light();
  late final ThemeData _dark = AppTheme.dark();

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
      theme: _light,
      darkTheme: _dark,
      // Follows the device. The app is used outdoors at a bin and indoors at a
      // desk, and a user who has chosen dark mode system-wide has chosen it here
      // too — there was previously no dark theme at all, so every screen was a
      // full-brightness white panel at night.
      themeMode: ThemeMode.system,
      routerConfig: router,
    );
  }
}
