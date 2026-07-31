import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../controllers/auth_controller.dart';
import '../views/auth/login_view.dart';
import '../views/auth/register_view.dart';
import '../views/home/home_view.dart';
import '../views/seller_application/seller_application_view.dart';
import '../views/admin/admin_applications_view.dart';
import '../views/admin/points_policy_view.dart';
import '../views/history/submission_history_view.dart';
import '../views/wallet/wallet_ledger_view.dart';
import '../views/disposal/scan_view.dart';
import '../views/disposal/photo_view.dart';
import '../views/disposal/location_view.dart';
import '../views/disposal/declare_view.dart';
import '../views/admin/admin_disposals_view.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(firebaseAuthStateProvider);
  final currentUser = ref.watch(currentUserProvider);

  return GoRouter(
    initialLocation: '/home',
    redirect: (context, state) {
      final isSignedIn = authState.value != null;
      final isAuthRoute =
          state.matchedLocation == '/login' ||
          state.matchedLocation == '/register';

      if (!isSignedIn && !isAuthRoute) return '/login';
      if (isSignedIn && isAuthRoute) return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (context, state) => const LoginView()),
      GoRoute(
        path: '/register',
        builder: (context, state) => const RegisterView(),
      ),
      GoRoute(path: '/home', builder: (context, state) => const HomeView()),
      GoRoute(
        path: '/apply-seller',
        builder: (context, state) => const SellerApplicationView(),
        redirect: (context, state) {
          final user = currentUser.value;
          if (user == null) return '/login';
          if (user.isSeller) return '/home';
          return null;
        },
      ),
      GoRoute(
        path: '/admin/applications',
        builder: (context, state) => const AdminApplicationsView(),
        redirect: (context, state) {
          final user = currentUser.value;
          if (user == null) return '/login';
          if (!user.isAdmin) return '/home';
          return null;
        },
      ),
      GoRoute(
        path: '/admin/points',
        builder: (context, state) => const PointsPolicyView(),
        redirect: (context, state) {
          final user = currentUser.value;
          if (user == null) return '/login';
          if (!user.isAdmin) return '/home';
          return null;
        },
      ),
      GoRoute(
        path: '/history',
        builder: (context, state) => const SubmissionHistoryView(),
        redirect: (context, state) {
          final user = currentUser.value;
          if (user == null) return '/login';
          return null;
        },
      ),
      GoRoute(
        path: '/wallet',
        builder: (context, state) => const WalletLedgerView(),
        redirect: (context, state) {
          final user = currentUser.value;
          if (user == null) return '/login';
          return null;
        },
      ),
      GoRoute(
        path: '/dispose/scan',
        builder: (context, state) => const ScanView(),
        redirect: (context, state) {
          final user = currentUser.value;
          if (user == null) return '/login';
          return null;
        },
      ),
      GoRoute(
        path: '/dispose/photo',
        builder: (context, state) => const DisposalPhotoView(),
        redirect: (context, state) {
          final user = currentUser.value;
          if (user == null) return '/login';
          return null;
        },
      ),
      GoRoute(
        path: '/dispose/location',
        builder: (context, state) => const DisposalLocationView(),
        redirect: (context, state) {
          final user = currentUser.value;
          if (user == null) return '/login';
          return null;
        },
      ),
      GoRoute(
        path: '/dispose/declare',
        builder: (context, state) => const DisposalDeclareView(),
        redirect: (context, state) {
          final user = currentUser.value;
          if (user == null) return '/login';
          return null;
        },
      ),
      GoRoute(
        path: '/admin/disposals',
        builder: (context, state) => const AdminDisposalsView(),
        redirect: (context, state) {
          final user = currentUser.value;
          if (user == null) return '/login';
          if (!user.isAdmin) return '/home';
          return null;
        },
      ),
    ],
  );
});
