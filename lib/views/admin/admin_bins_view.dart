import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../controllers/admin_bins_controller.dart';
import '../../core/bin_label_pdf.dart';
import '../../core/geo.dart';
import '../../core/label_format.dart';
import '../../core/pdf_fonts.dart';
import '../../core/theme.dart';
import '../../models/bin_model.dart';
import '../../services/bin_admin_service.dart';
import '../../services/location_service.dart';
import '../shared/content_state.dart';
import '../shared/app_shell.dart';
import '../shared/notice_card.dart';

/// Bin registration and printable QR generation (F2.1).
///
/// Two things make a registered bin usable, and both are here:
///
/// **The coordinates are captured on site.** The brief calls this feature
/// mobile-first for that reason — an administrator standing at the bin taps
/// "Use my location" rather than reading numbers off a map afterwards. Typed
/// entry stays available, because the web build has no useful GPS and because a
/// bin sometimes has to be corrected from a desk.
///
/// **The code goes onto paper.** See [buildBinLabelPdf]; printing the app's own
/// screen does not work on the web canvas and never produced a usable label.
class AdminBinsView extends ConsumerStatefulWidget {
  const AdminBinsView({super.key});

  @override
  ConsumerState<AdminBinsView> createState() => _AdminBinsViewState();
}

class _AdminBinsViewState extends ConsumerState<AdminBinsView> {
  final _label = TextEditingController();
  final _lat = TextEditingController();
  final _lng = TextEditingController();
  final _radius = TextEditingController(text: '50');

  bool _saving = false;
  bool _locating = false;
  bool _printingAll = false;
  List<String> _problems = const [];

  /// The last GPS fix, kept so its accuracy can be judged against the radius.
  LocationResult? _fix;

  /// What the fix wrote into the coordinate fields. Once an administrator edits
  /// either field by hand the fix no longer describes what is in the form, and
  /// continuing to show "accurate to ±8 m" beside typed numbers would be a lie.
  String? _fixLatText;
  String? _fixLngText;

  /// True while this class is writing the coordinate fields itself.
  ///
  /// [_onCoordinateEdited] must react only to a *person* typing. A programmatic
  /// write sets latitude and longitude one after the other, so there is an
  /// instant when latitude holds the new value and longitude still holds the old
  /// one — and a listener firing then sees a mismatch and throws away the very
  /// fix being recorded.
  bool _writingCoordinates = false;

  @override
  void initState() {
    super.initState();
    _lat.addListener(_onCoordinateEdited);
    _lng.addListener(_onCoordinateEdited);
    // The accuracy verdict is relative to the radius, so it has to be
    // re-rendered when the radius changes. Without this, an administrator told
    // their fix was too rough for 50 m would widen the radius to 200 m and still
    // be looking at the warning.
    _radius.addListener(_onRadiusEdited);
  }

  void _onRadiusEdited() {
    // Only the fix note depends on the radius; with no fix there is nothing on
    // screen that would change.
    if (_fix == null) return;
    setState(() {});
  }

  /// Writes the coordinate fields without the edit listener misreading it.
  void _writeCoordinates(void Function() write) {
    _writingCoordinates = true;
    try {
      write();
    } finally {
      _writingCoordinates = false;
    }
  }

  @override
  void dispose() {
    _lat.removeListener(_onCoordinateEdited);
    _lng.removeListener(_onCoordinateEdited);
    _radius.removeListener(_onRadiusEdited);
    _label.dispose();
    _lat.dispose();
    _lng.dispose();
    _radius.dispose();
    super.dispose();
  }

  void _onCoordinateEdited() {
    if (_writingCoordinates) return;
    if (_fix == null) return;
    if (_lat.text == _fixLatText && _lng.text == _fixLngText) return;
    setState(() {
      _fix = null;
      _fixLatText = null;
      _fixLngText = null;
    });
  }

  double? get _radiusValue => double.tryParse(_radius.text.trim());

  /// Whether the fix is too imprecise for the radius it will be the centre of.
  /// The rule itself is domain logic — see [isFixTooRoughForRadius].
  bool get _fixTooRoughForRadius => isFixTooRoughForRadius(
    accuracyMeters: _fix?.accuracyMeters,
    radiusMeters: _radiusValue,
  );

  Future<void> _useMyLocation() async {
    setState(() {
      _locating = true;
      _problems = const [];
    });

    final result = await ref.read(adminBinActionsProvider).captureLocation();
    if (!mounted) return;

    setState(() {
      _locating = false;
      _fix = result;

      if (result.hasFix) {
        // Five decimal places is about a metre — more than the fix itself is
        // worth, and less would throw away real precision.
        _fixLatText = result.latitude!.toStringAsFixed(5);
        _fixLngText = result.longitude!.toStringAsFixed(5);
        _writeCoordinates(() {
          _lat.text = _fixLatText!;
          _lng.text = _fixLngText!;
        });
      } else {
        _fixLatText = null;
        _fixLngText = null;
      }
    });
  }

  Future<void> _register() async {
    final lat = double.tryParse(_lat.text.trim());
    final lng = double.tryParse(_lng.text.trim());
    final radius = _radiusValue;

    final local = <String>[
      if (_label.text.trim().isEmpty) 'Bin label is required.',
      if (lat == null) 'Latitude must be a number.',
      if (lng == null) 'Longitude must be a number.',
      if (radius == null) 'Radius must be a number.',
    ];

    if (local.isNotEmpty) {
      setState(() => _problems = local);
      return;
    }

    setState(() {
      _saving = true;
      _problems = const [];
    });

    try {
      final bin = await ref
          .read(adminBinActionsProvider)
          .register(
            label: _label.text.trim(),
            lat: lat!,
            lng: lng!,
            radiusMeters: radius!,
          );

      if (!mounted) return;
      setState(() {
        _saving = false;
        _label.clear();
        _radius.text = '50';
        _fix = null;
        _fixLatText = null;
        _fixLngText = null;
        // Guarded for the same reason as the capture: clearing the two fields in
        // turn would otherwise re-enter the listener mid-reset.
        _writeCoordinates(() {
          _lat.clear();
          _lng.clear();
        });
      });

      await _showQr(bin);
    } on BinAdminException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _problems = error.problems.isEmpty ? [error.message] : error.problems;
      });
    }
  }

  Future<void> _showQr(BinModel bin) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _QrDialog(bin: bin),
    );
  }

  Future<void> _toggle(BinModel bin) async {
    final id = bin.id;
    if (id == null) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(adminBinActionsProvider)
          .setActive(binId: id, active: !bin.active);
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            bin.active ? '${bin.label} closed.' : '${bin.label} reopened.',
          ),
        ),
      );
    } on BinAdminException catch (error) {
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  /// Prints every open bin's label, four to a sheet.
  ///
  /// Closed bins are left out on purpose: a label on the street for a bin that
  /// refuses submissions produces a scan, a walk and a refusal.
  Future<void> _printAll(List<BinModel> bins) async {
    final open = [...bins.where((b) => b.active)]
      ..sort((a, b) => a.label.compareTo(b.label));

    final messenger = ScaffoldMessenger.of(context);
    if (open.isEmpty) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(content: Text('No open bins to print.')),
      );
      return;
    }

    setState(() => _printingAll = true);
    try {
      // Fetching fonts before the dialog opens is what makes this slow enough
      // to need a spinner at all.
      final theme = await labelTheme();
      await Printing.layoutPdf(
        onLayout: (_) => buildBinLabelSheetPdf(open, theme: theme),
        name: 'chokro-bin-labels',
      );
    } catch (error) {
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(content: Text('The labels could not be printed.')),
      );
    } finally {
      if (mounted) setState(() => _printingAll = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(allBinsProvider);
    final bins = async.value;
    final theme = Theme.of(context);

    return AppShell(
      title: 'Bins',
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppTheme.maxContentWidth),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.gapMd,
              AppTheme.gapMd,
              AppTheme.gapMd,
              AppTheme.gapXl,
            ),
            children: [
              Text(
                'Register a bin',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: AppTheme.gapXs),
              Text(
                'Stand at the bin and capture its position. The QR payload is '
                'generated by the server, so it is unique across every bin.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppTheme.gapMd),
              TextField(
                controller: _label,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Label',
                  hintText: 'Merul Badda — Block C gate',
                  isDense: true,
                ),
              ),
              const SizedBox(height: AppTheme.gapMd),

              _LocationField(
                lat: _lat,
                lng: _lng,
                radius: _radius,
                locating: _locating,
                onUseMyLocation: _useMyLocation,
              ),

              if (_fix != null) ...[
                const SizedBox(height: AppTheme.gapSm),
                _FixNote(
                  fix: _fix!,
                  tooRoughForRadius: _fixTooRoughForRadius,
                  radius: _radiusValue,
                  onOpenLocationSettings: ref
                      .read(adminBinActionsProvider)
                      .openLocationSettings,
                  onOpenAppSettings: ref
                      .read(adminBinActionsProvider)
                      .openAppSettings,
                ),
              ],

              const SizedBox(height: AppTheme.gapSm),
              Text(
                'A tight radius is a stronger proof of presence. 50 m suits a '
                'street bin; an open compound may need more.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),

              if (_problems.isNotEmpty) ...[
                const SizedBox(height: AppTheme.gapMd),
                for (final problem in _problems)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppTheme.gapXs),
                    child: Text(
                      '• $problem',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
              ],

              const SizedBox(height: AppTheme.gapMd),
              FilledButton.icon(
                onPressed: _saving ? null : _register,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_location_alt_outlined),
                label: Text(_saving ? 'Registering…' : 'Register bin'),
              ),
              // A bin registration is a server call, so it inherits the
              // ninety-second cold-start allowance. Without this the button says
              // "Registering…" for a minute and a half and the administrator
              // reasonably concludes the page is broken.
              if (_saving) const SlowServerNote(),

              const SizedBox(height: AppTheme.gapXl),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Registered bins',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (bins != null && bins.any((b) => b.active))
                    TextButton.icon(
                      onPressed: _printingAll ? null : () => _printAll(bins),
                      icon: _printingAll
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.print_outlined, size: 18),
                      label: Text(
                        _printingAll ? 'Preparing…' : 'Print all labels',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppTheme.gapSm),
              async.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(AppTheme.gapLg),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (error, _) => Text(
                  'Bins did not load. Check your connection and try again.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
                data: (bins) {
                  if (bins.isEmpty) {
                    return Text(
                      'No bins yet. Nothing can be scanned until one exists.',
                      style: theme.textTheme.bodySmall,
                    );
                  }
                  final sorted = [...bins]
                    ..sort((a, b) => a.label.compareTo(b.label));
                  return Column(
                    children: [
                      for (final bin in sorted)
                        _BinCard(
                          bin: bin,
                          onShowQr: () => _showQr(bin),
                          onToggle: () => _toggle(bin),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Coordinates and radius, with the on-site capture button.
class _LocationField extends StatelessWidget {
  const _LocationField({
    required this.lat,
    required this.lng,
    required this.radius,
    required this.locating,
    required this.onUseMyLocation,
  });

  final TextEditingController lat;
  final TextEditingController lng;
  final TextEditingController radius;
  final bool locating;
  final VoidCallback onUseMyLocation;

  @override
  Widget build(BuildContext context) {
    const coordinateKeyboard = TextInputType.numberWithOptions(
      decimal: true,
      signed: true,
    );
    final coordinateFilter = [
      FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: lat,
                keyboardType: coordinateKeyboard,
                inputFormatters: coordinateFilter,
                decoration: const InputDecoration(
                  labelText: 'Latitude',
                  hintText: '23.7808',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: AppTheme.gapMd),
            Expanded(
              child: TextField(
                controller: lng,
                keyboardType: coordinateKeyboard,
                inputFormatters: coordinateFilter,
                decoration: const InputDecoration(
                  labelText: 'Longitude',
                  hintText: '90.4074',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: AppTheme.gapMd),
            SizedBox(
              width: 110,
              child: TextField(
                controller: radius,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Radius',
                  suffixText: 'm',
                  isDense: true,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppTheme.gapSm),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: locating ? null : onUseMyLocation,
            icon: locating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.my_location, size: 18),
            label: Text(locating ? 'Locating…' : 'Use my location'),
          ),
        ),
      ],
    );
  }
}

/// What came back from the GPS, and whether it is good enough to build a
/// geofence on.
class _FixNote extends StatelessWidget {
  const _FixNote({
    required this.fix,
    required this.tooRoughForRadius,
    required this.radius,
    required this.onOpenLocationSettings,
    required this.onOpenAppSettings,
  });

  final LocationResult fix;
  final bool tooRoughForRadius;
  final double? radius;
  final VoidCallback onOpenLocationSettings;
  final VoidCallback onOpenAppSettings;

  @override
  Widget build(BuildContext context) {
    if (!fix.hasFix) {
      final needsAppSettings = fix.outcome == LocationOutcome.deniedForever;
      final needsLocationSettings =
          fix.outcome == LocationOutcome.serviceDisabled;

      return NoticeCard(
        icon: Icons.location_off_outlined,
        tone: NoticeTone.error,
        title: fix.displayMessage,
        message: 'You can still type the coordinates in by hand.',
        action: needsAppSettings || needsLocationSettings
            ? NoticeAction(
                label: 'Open settings',
                onPressed: needsAppSettings
                    ? onOpenAppSettings
                    : onOpenLocationSettings,
              )
            : null,
      );
    }

    final accuracy = fix.accuracyMeters;
    final accuracyText = accuracy == null
        ? 'accuracy unknown'
        : 'accurate to ±${accuracy.round()} m';

    if (tooRoughForRadius) {
      return NoticeCard(
        icon: Icons.gps_not_fixed,
        tone: NoticeTone.error,
        title: 'This fix is too rough for a ${radius?.round()} m radius',
        message:
            'The fix is $accuracyText, so the recorded centre could sit '
            'further from the bin than half the geofence. Residents standing '
            'at the bin would be refused, and nothing in their submission '
            'would show that the bin was the thing in the wrong place. Move '
            'into the open and capture again, or widen the radius.',
      );
    }

    return NoticeCard(
      icon: Icons.gps_fixed,
      tone: NoticeTone.success,
      title: 'Position captured, $accuracyText',
      message: 'Check the label names this bin, then register it.',
    );
  }
}

class _BinCard extends StatelessWidget {
  const _BinCard({
    required this.bin,
    required this.onShowQr,
    required this.onToggle,
  });

  final BinModel bin;
  final VoidCallback onShowQr;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: AppTheme.gapSm),
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Row(
          children: [
            Icon(
              bin.active ? Icons.delete_outline : Icons.block,
              color: bin.active
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppTheme.gapMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bin.label,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${bin.lat.toStringAsFixed(5)}, '
                    '${bin.lng.toStringAsFixed(5)} · '
                    '${bin.radiusMeters.round()} m'
                    '${bin.active ? '' : ' · closed'}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (bin.createdAt != null)
                    Text(
                      'Registered ${formatAge(bin.createdAt)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Show and print QR code',
              onPressed: onShowQr,
              icon: const Icon(Icons.qr_code_2),
            ),
            TextButton(
              onPressed: onToggle,
              child: Text(bin.active ? 'Close' : 'Reopen'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The code on screen, with the paths that get it onto paper.
class _QrDialog extends StatefulWidget {
  const _QrDialog({required this.bin});

  final BinModel bin;

  @override
  State<_QrDialog> createState() => _QrDialogState();
}

class _QrDialogState extends State<_QrDialog> {
  bool _busy = false;

  /// A filename an administrator can recognise in a downloads folder.
  String get _filename {
    final slug = widget.bin.label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return 'chokro-bin-${slug.isEmpty ? 'label' : slug}';
  }

  /// Runs a print or share action, reporting failure rather than dropping it.
  ///
  /// A cancelled print dialog is not a failure and returns normally, so only a
  /// thrown error is worth a message.
  Future<void> _run(Future<void> Function() action, String failure) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(failure)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _print() => _run(() async {
    final theme = await labelTheme();
    await Printing.layoutPdf(
      onLayout: (_) => buildBinLabelPdf(widget.bin, theme: theme),
      name: _filename,
    );
  }, 'The label could not be printed.');

  Future<void> _share() => _run(
    () async => Printing.sharePdf(
      bytes: await buildBinLabelPdf(widget.bin, theme: await labelTheme()),
      filename: '$_filename.pdf',
    ),
    'The label could not be shared.',
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bin = widget.bin;
    const qrSize = 200.0;
    const qrPlateSize = qrSize + (AppTheme.gapMd * 2);

    return AlertDialog(
      title: Text(bin.label),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // White plate regardless of theme. An inverted QR photographs badly
            // and some scanners refuse it outright, so the on-screen code keeps
            // the same polarity as the printed one.
            // AlertDialog measures its content with IntrinsicWidth. QrImageView
            // internally uses LayoutBuilder, which deliberately cannot answer
            // intrinsic-size queries. A tight box stops that query at this
            // boundary and gives the QR its real painted size immediately.
            // Without it the first layout failure cascades into the
            // parentDataDirty semantics and no-size hit-test errors.
            SizedBox.square(
              dimension: qrPlateSize,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppTheme.gapMd),
                  child: QrImageView(
                    data: bin.qrPayload,
                    version: QrVersions.auto,
                    size: qrSize,
                    backgroundColor: Colors.white,
                    semanticsLabel: 'QR code for ${bin.label}',
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppTheme.gapMd),
            SelectableText(
              bin.qrPayload,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppTheme.gapSm),
            Text(
              kIsWeb
                  ? 'Print the label and attach it to the bin.'
                  : 'Print the label, or share it to print from another '
                        'device.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy
              ? null
              : () {
                  final messenger = ScaffoldMessenger.of(context);
                  Clipboard.setData(ClipboardData(text: bin.qrPayload));
                  messenger.hideCurrentSnackBar();
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Payload copied.')),
                  );
                },
          child: const Text('Copy payload'),
        ),
        TextButton(
          onPressed: _busy ? null : _share,
          // On the web `sharePdf` hands the file to the browser, which saves
          // it; there is no share sheet to open.
          child: Text(kIsWeb ? 'Download PDF' : 'Share'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _print,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.print_outlined, size: 18),
          label: const Text('Print'),
        ),
      ],
    );
  }
}
