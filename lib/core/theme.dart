import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
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

  /// A warm counterpoint to the emerald. Used sparingly for reward moments so
  /// the product feels like an impact platform rather than a monochrome utility.
  static const Color reward = Color(0xFFE4A11B);

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
    final generatedScheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      contrastLevel: .08,
    );
    final light = brightness == Brightness.light;
    final scheme = generatedScheme.copyWith(
      // Material's generated surfaces are deliberately close together. These
      // bespoke neutrals make the information hierarchy legible at a glance
      // while keeping the hue just warm enough to belong to the brand.
      surface: light ? const Color(0xFFF7FAF8) : const Color(0xFF0F1512),
      surfaceContainerLowest: light
          ? const Color(0xFFFFFFFF)
          : const Color(0xFF141C18),
      surfaceContainerLow: light
          ? const Color(0xFFF0F5F2)
          : const Color(0xFF18211C),
      surfaceContainer: light
          ? const Color(0xFFE8F0EB)
          : const Color(0xFF1D2822),
      outlineVariant: light ? const Color(0xFFD7E2DB) : const Color(0xFF39463F),
    );
    final typography = Typography.material2021(
      platform: defaultTargetPlatform,
      colorScheme: scheme,
    );
    final baseTextTheme = light ? typography.black : typography.white;
    final textTheme = baseTextTheme.copyWith(
      displayLarge: baseTextTheme.displayLarge?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -2.4,
      ),
      displayMedium: baseTextTheme.displayMedium?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -1.7,
      ),
      displaySmall: baseTextTheme.displaySmall?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -1.15,
      ),
      headlineLarge: baseTextTheme.headlineLarge?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -.8,
      ),
      headlineMedium: baseTextTheme.headlineMedium?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -.65,
      ),
      headlineSmall: baseTextTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -.4,
      ),
      titleLarge: baseTextTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -.25,
      ),
      titleMedium: baseTextTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -.1,
      ),
      bodyLarge: baseTextTheme.bodyLarge?.copyWith(height: 1.45),
      bodyMedium: baseTextTheme.bodyMedium?.copyWith(height: 1.45),
      bodySmall: baseTextTheme.bodySmall?.copyWith(height: 1.4),
      labelLarge: baseTextTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: .1,
      ),
    );

    return ThemeData(
      colorScheme: scheme,
      textTheme: textTheme,
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
        toolbarHeight: 68,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -.25,
          color: scheme.onSurface,
        ),
      ),

      cardTheme: CardThemeData(
        elevation: light ? .35 : 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        color: scheme.surfaceContainerLowest,
        shadowColor: scheme.shadow.withValues(alpha: .12),
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
        // `outline`, not `outlineVariant`. `enabledBorder` is the state every
        // field is in until it is touched, and against this theme's own
        // `surfaceContainerLowest` fill the variant measured 1.33:1 in light
        // and 1.75:1 in dark — under WCAG 1.4.11's 3:1 floor for the boundary
        // of a control. The fill offers no help either: white on a #F7FAF8
        // page is 1.09:1, so the field edge was the only thing marking where
        // to type. `outlineVariant` is Material's role for decorative
        // dividers; `outline` is the one specified for text-field outlines,
        // and `border` above already uses it.
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: BorderSide(color: scheme.outline),
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
        floatingLabelStyle: TextStyle(
          color: scheme.primary,
          fontWeight: FontWeight.w600,
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
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSm),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
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
        height: 76,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          return textTheme.labelMedium?.copyWith(
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w600,
          );
        }),
      ),

      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        indicatorColor: scheme.secondaryContainer,
        elevation: 0,
        minWidth: 88,
        useIndicator: true,
        selectedIconTheme: IconThemeData(color: scheme.onSecondaryContainer),
        selectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
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
        backgroundColor: scheme.surfaceContainerLow,
        selectedColor: scheme.secondaryContainer,
        labelStyle: textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
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

      badgeTheme: BadgeThemeData(
        backgroundColor: scheme.error,
        textColor: scheme.onError,
        textStyle: textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w800),
      ),

      textSelectionTheme: TextSelectionThemeData(
        cursorColor: scheme.primary,
        selectionColor: scheme.primary.withValues(alpha: .22),
        selectionHandleColor: scheme.primary,
      ),

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
  ///
  /// The light value was `#8D6E00`, which measures 4.58:1 on `surface` and
  /// therefore passed AA only on the two lightest of the four surfaces this app
  /// paints on: 4.37 on `surfaceContainerLow` and 4.15 on `surfaceContainer`
  /// both fail the 4.5 floor, and those are the surfaces cards and chips
  /// actually sit on. Darkened to clear AA everywhere with margin rather than
  /// leaving a colour whose legality depended on which container it landed in.
  /// Dark mode was already comfortable at 9–11:1 and is unchanged.
  Color get warning => brightness == Brightness.light
      ? const Color(0xFF6E5500)
      : const Color(0xFFE8C547);

  /// The tinted background for a warning, and its matching foreground.
  ///
  /// [success] had a container pair and [warning] did not, so "needs attention"
  /// had nothing consistent to sit on — `product_card.dart` reached for
  /// `errorContainer` to render a *warning* tone, which says "this failed" for
  /// a listing that is merely low on stock.
  Color get warningContainer => brightness == Brightness.light
      ? const Color(0xFFFFE08A)
      : const Color(0xFF453A00);

  Color get onWarningContainer => brightness == Brightness.light
      ? const Color(0xFF3D2F00)
      : const Color(0xFFFFE08A);
}
