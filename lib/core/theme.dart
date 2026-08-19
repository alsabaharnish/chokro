import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
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

  /// A deep emerald that still reads as trustworthy rather than fluorescent.
  /// The generated secondary and tertiary tones add enough blue to keep the
  /// interface from looking like a generic "green app".
  static const Color seed = Color(0xFF006C4C);

  /// Standard gaps, so vertical rhythm is a choice from a set rather than a
  /// number typed at each call site. The home screen had a doubled `16` and a
  /// missing one, which is what happens when spacing is ad hoc.
  static const double gapXs = 4;
  static const double gapSm = 8;
  static const double gapMd = 16;
  static const double gapLg = 24;
  static const double gapXl = 32;
  static const double gap2Xl = 48;

  static const double radiusSm = 12;
  static const double radiusMd = 18;
  static const double radiusLg = 28;

  /// Content stops stretching past this and centres. Long lines of text are
  /// hard to read, and a 1600 px-wide form looks broken.
  static const double maxContentWidth = 760;
  static const double maxDashboardWidth = 1120;
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
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,

      // Route changes are intentionally quiet. iOS keeps its familiar swipe
      // transition while the other targets share a short, low-motion fade.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.fuchsia: FadeUpwardsPageTransitionsBuilder(),
        },
      ),

      // Fill the surface rather than leaving cards floating on white: with
      // Material 3's low-contrast surfaces, elevation alone does not read as a
      // boundary in dark mode.
      scaffoldBackgroundColor: scheme.surface,

      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surface.withValues(alpha: .96),
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 64,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -.25,
          color: scheme.onSurface,
        ),
      ),

      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        color: scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          // A hairline outline instead of a shadow. It survives dark mode,
          // where a shadow on a dark surface is invisible.
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),

      // Every form field in the app was repeating `OutlineInputBorder()`.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: gapMd,
          vertical: 17,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: BorderSide(color: scheme.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
      ),

      // 48 dp minimum height on every button: the Material accessibility floor
      // for a touch target, and several of these are tapped one-handed while
      // standing over a bin.
      //
      // The width is Material's own default minimum of 64, and must stay a
      // finite number. `Size.fromHeight(48)` reads like "height only" but is
      // defined as `Size(double.infinity, 48)`, which sets an *infinite minimum
      // width*. Inside a Column that merely fills the available width, so the
      // forms looked correct — but a Row hands its non-flex children unbounded
      // width, so every button placed directly in a Row threw "BoxConstraints
      // forces an infinite width" and took the screen down with it. That is most
      // of the admin queues, where approve and reject sit side by side.
      //
      // Buttons that should span their container say so where they are used,
      // with `CrossAxisAlignment.stretch`.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSm),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSm),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(64, 44),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),

      // Floating so it clears the bottom navigation bar. A fixed snackbar sat
      // behind it, which hid half the message on the admin screens.
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSm),
        ),
        insetPadding: const EdgeInsets.all(gapMd),
        showCloseIcon: true,
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
        ),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        modalBackgroundColor: scheme.surfaceContainerLowest,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radiusLg)),
        ),
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        indicatorColor: scheme.secondaryContainer,
        elevation: 0,
        height: 72,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),

      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        indicatorColor: scheme.secondaryContainer,
        elevation: 0,
        minWidth: 88,
        useIndicator: true,
      ),

      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size.square(44)),
      ),

      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(
          horizontal: gapMd,
          vertical: gapXs,
        ),
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

      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),

      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(6),
        radius: const Radius.circular(999),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          final opacity = states.contains(WidgetState.hovered) ? .5 : .28;
          return scheme.onSurfaceVariant.withValues(alpha: opacity);
        }),
      ),

      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: TextStyle(color: scheme.onInverseSurface),
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
