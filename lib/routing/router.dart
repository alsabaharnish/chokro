import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../controllers/auth_controller.dart';
import '../views/auth/login_view.dart';
import '../views/auth/register_view.dart';
import '../views/home/home_view.dart';
import '../views/seller_application/seller_application_view.dart';
import '../views/admin/admin_applications_view.dart';
import '../views/wallet/wallet_view.dart';
import '../views/disposal/scan_view.dart';
import '../views/disposal/photo_view.dart';

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
        path: '/wallet',
        builder: (context, state) => const WalletView(),
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
    ],
  );
});
