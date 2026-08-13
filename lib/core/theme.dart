import 'package:flutter/material.dart';

/// The app's single source of visual truth.
///
/// Before this existed, every screen reached for its own colours — `Colors.red`
/// for an error snackbar, `Colors.green` for a tick — which meant the palette
/// was whatever each screen happened to pick, and none of it survived a switch
/// to dark mode. Component styling was duplicated too: `border:
/// OutlineInputBorder()` was written out at every single `TextFormField`.
///
/// Everything here derives from one seed, so the light and dark schemes stay in
/// step by construction rather than by somebody remembering to update both.
class AppTheme {
  const AppTheme._();

  /// Green 800. The recycling association is the point.
  static const Color seed = Color(0xFF2E7D32);

  /// Standard gaps, so vertical rhythm is a choice from a set rather than a
  /// number typed at each call site. The home screen had a doubled `16` and a
  /// missing one, which is what happens when spacing is ad hoc.
  static const double gapXs = 4;
  static const double gapSm = 8;
  static const double gapMd = 16;
  static const double gapLg = 24;
  static const double gapXl = 32;

  /// Content stops stretching past this and centres. Long lines of text are
  /// hard to read, and a 1600 px-wide form looks broken.
  static const double maxContentWidth = 720;
  static const double maxFormWidth = 440;

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,

      // Fill the surface rather than leaving cards floating on white: with
      // Material 3's low-contrast surfaces, elevation alone does not read as a
      // boundary in dark mode.
      scaffoldBackgroundColor: scheme.surface,

      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: scheme.surfaceTint,
        elevation: 0,
        scrolledUnderElevation: 2,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),

      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          // A hairline outline instead of a shadow. It survives dark mode,
          // where a shadow on a dark surface is invisible.
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),

      // Every form field in the app was repeating `OutlineInputBorder()`.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
      ),

      // 48 dp minimum height on every button: the Material accessibility floor
      // for a touch target, and several of these are tapped one-handed while
      // standing over a bin.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size.fromHeight(44),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),

      // Floating so it clears the bottom navigation bar. A fixed snackbar sat
      // behind it, which hid half the message on the admin screens.
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        insetPadding: const EdgeInsets.all(gapMd),
      ),

      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.secondaryContainer,
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),

      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.secondaryContainer,
      ),

      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: gapMd, vertical: gapXs),
      ),

      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),

      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
      ),
    );
  }
}

/// Semantic colours that Material's [ColorScheme] has no slot for.
///
/// `Colors.green` was scattered through the views for "this succeeded". That
/// reads as a hardcoded value in light mode and as a glare in dark mode, so it
/// is derived from the scheme instead.
extension AppSemanticColors on ColorScheme {
  /// A positive outcome: a resolved bin, an approved application, a good fix.
  Color get success => brightness == Brightness.light
      ? const Color(0xFF1B5E20)
      : const Color(0xFF81C784);

  Color get onSuccessContainer => brightness == Brightness.light
      ? const Color(0xFF0B2F0D)
      : const Color(0xFFC8E6C9);

  Color get successContainer => brightness == Brightness.light
      ? const Color(0xFFC8E6C9)
      : const Color(0xFF1B3D1E);

  /// Something needing attention but not an error — a flagged submission.
  Color get warning => brightness == Brightness.light
      ? const Color(0xFF8D6E00)
      : const Color(0xFFE8C547);
}
