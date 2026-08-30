import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/eco_action_photocard.dart';
import '../../models/claim_model.dart';
import '../shared/app_snackbar.dart';
import 'eco_action_photocard.dart';

/// Opens a WYSIWYG preview for an approved eco-action.
///
/// Pending and rejected claims return without opening anything. This guard is
/// repeated in the admin view by only offering its button on approved cards.
Future<void> showEcoActionPhotocardDialog(
  BuildContext context, {
  required ClaimModel claim,
}) async {
  if (!claim.status.isApproved || !claim.hasPublicationPermission) return;

  final data = EcoActionPhotocardData.fromApprovedClaim(claim);
  await showDialog<void>(
    context: context,
    useSafeArea: true,
    builder: (dialogContext) {
      final fullScreen = MediaQuery.sizeOf(dialogContext).width < 620;
      final content = _EcoActionPhotocardDialog(data: data);
      if (fullScreen) return Dialog.fullscreen(child: content);

      return Dialog(
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680, maxHeight: 820),
          child: content,
        ),
      );
    },
  );
}

class _EcoActionPhotocardDialog extends StatefulWidget {
  const _EcoActionPhotocardDialog({required this.data});

  final EcoActionPhotocardData data;

  @override
  State<_EcoActionPhotocardDialog> createState() =>
      _EcoActionPhotocardDialogState();
}

class _EcoActionPhotocardDialogState extends State<_EcoActionPhotocardDialog> {
  final _captureKey = GlobalKey();

  late final ImageProvider _actionPhoto;
  late final ImageProvider? _championPhoto;

  bool _preparing = true;
  bool _busy = false;
  bool _anonymousContentReviewed = false;
  String? _preparationError;
  Uint8List? _capturedPng;

  @override
  void initState() {
    super.initState();
    _actionPhoto = CachedNetworkImageProvider(widget.data.actionPhotoUrl);
    _championPhoto = widget.data.publishesIdentity
        ? CachedNetworkImageProvider(widget.data.championPhotoUrl!)
        : null;

    WidgetsBinding.instance.addPostFrameCallback((_) => _prepareImages());
  }

  Future<void> _prepareImages() async {
    if (!mounted) return;
    setState(() {
      _preparing = true;
      _preparationError = null;
      _capturedPng = null;
    });

    Object? loadError;
    Future<void> cache(ImageProvider provider) => precacheImage(
      provider,
      context,
      size: const Size.square(EcoActionPhotocard.logicalSize),
      onError: (error, _) => loadError ??= error,
    );

    await Future.wait([
      cache(_actionPhoto),
      cache(const AssetImage(EcoActionPhotocard.brandAsset)),
      if (_championPhoto != null) cache(_championPhoto),
    ]);

    if (!mounted) return;
    setState(() {
      _preparing = false;
      _preparationError = loadError == null
          ? null
          : widget.data.publishesIdentity
          ? 'The action or profile photo could not be loaded. Check the connection and retry.'
          : 'The action photo could not be loaded. Check the connection and retry.';
    });
  }

  Future<Uint8List> _capturePng() async {
    final cached = _capturedPng;
    if (cached != null) return cached;
    if (_preparing || _preparationError != null) {
      throw StateError('The photocard is not ready to export.');
    }

    // Ensure every decoded image has painted into the boundary before reading
    // it. At 540 logical pixels and a 2x capture this is exactly 1080 square.
    await WidgetsBinding.instance.endOfFrame;
    final boundary = _captureKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) {
      throw StateError('The photocard preview is not available.');
    }

    final image = await boundary.toImage(pixelRatio: 2);
    try {
      if (image.width != 1080 || image.height != 1080) {
        throw StateError(
          'The photocard rendered at ${image.width} × ${image.height}.',
        );
      }
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('The photocard could not be encoded.');
      final bytes = data.buffer.asUint8List();
      _capturedPng = bytes;
      return bytes;
    } finally {
      image.dispose();
    }
  }

  Future<void> _run(
    Future<void> Function() action, {
    required String failure,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    // Through AppSnackBar, so a failure is distinguishable from the success
    // above it by icon as well as colour.
    final notify = AppSnackBar.of(context);
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      notify.failure(failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Rect _shareOrigin(BuildContext buttonContext) {
    final box = buttonContext.findRenderObject();
    if (box is RenderBox && box.hasSize && !box.size.isEmpty) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    final size = MediaQuery.sizeOf(context);
    return Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: 1,
      height: 1,
    );
  }

  Future<void> _save() => _run(() async {
    final png = await _capturePng();
    final location = await FileSaver.instance.saveAs(
      name: widget.data.fileStem,
      bytes: png,
      fileExtension: 'png',
      mimeType: MimeType.png,
    );
    if (!mounted || location == null) return;
    AppSnackBar.of(context).success('PNG saved.');
  }, failure: 'The PNG could not be saved. Try again.');

  Future<void> _share(BuildContext buttonContext) => _run(() async {
    // Resolve the popover anchor before awaiting capture. The button may
    // leave the tree while a large card is being encoded.
    final shareOrigin = _shareOrigin(buttonContext);
    final png = await _capturePng();
    final filename = '${widget.data.fileStem}.png';
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(png, mimeType: 'image/png')],
        fileNameOverrides: [filename],
        title: 'Share eco-action',
        subject: 'A Chokro eco-action',
        text: widget.data.shareText,
        sharePositionOrigin: shareOrigin,
        // Browsers without file sharing download the PNG instead.
        downloadFallbackEnabled: true,
      ),
    );
  }, failure: 'The photocard could not be shared. Try again.');

  Future<void> _print() => _run(() async {
    final png = await _capturePng();
    final pdf = await buildEcoActionPhotocardPrintPdf(png);
    await Printing.layoutPdf(
      onLayout: (_) async => pdf,
      name: widget.data.fileStem,
    );
  }, failure: 'The photocard could not be printed. Try again.');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final privacyReady =
        widget.data.publishesIdentity || _anonymousContentReviewed;
    final ready =
        !_preparing && _preparationError == null && !_busy && privacyReady;

    // `ScaffoldMessenger` + `Scaffold` inside the dialog route, not around it.
    // Without them `ScaffoldMessenger.of(context)` resolved to the root
    // messenger installed on `MaterialApp`, which renders into the `Scaffold`
    // on the route *underneath* — and this dialog is `Dialog.fullscreen` over
    // an opaque `Material`, so every success and every failure was painted
    // behind it and never seen. An admin who failed to save a PNG was told
    // nothing at all.
    return ScaffoldMessenger(
      child: Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: SafeArea(
          child: Column(
            children: [
              // The chrome scrolls; the action bar stays pinned. As a bare
              // Column with an `Expanded` preview, the fixed children — a
              // ~100-character checkbox title, its subtitle, the header and
              // the privacy notice, all of which grow with the text scale —
              // consumed the whole height at Android "Large" on a small
              // phone. `Expanded` then clamped to zero, RenderFlex
              // overflowed, and Save, Share and Print were pushed off the
              // bottom with no way to reach them.
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 10, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Eco-action photocard',
                                  style: theme.textTheme.titleLarge,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'The exported PNG is 1080 × 1080.',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close preview',
                            onPressed: _busy
                                ? null
                                : () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: _PrivacyNotice(data: widget.data),
                    ),
                    if (!widget.data.publishesIdentity)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                        child: CheckboxListTile(
                          value: _anonymousContentReviewed,
                          onChanged: _busy
                              ? null
                              : (value) => setState(
                                  () => _anonymousContentReviewed =
                                      value ?? false,
                                ),
                          controlAffinity: ListTileControlAffinity.leading,
                          title: const Text(
                            'I checked the photo and story for names, faces, addresses, uniforms and other identifying details.',
                          ),
                          subtitle: const Text(
                            'The saved profile name and picture are hidden, but the submitted content may still identify someone.',
                          ),
                        ),
                      ),
                    if (widget.data.storyIsCondensed)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                        child: Text(
                          'The square card uses a readable excerpt of this long story; the full story remains in the admin gallery.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    // Bounded, not `Expanded`: this now lives inside a scroll
                    // view, whose main axis is unbounded, and `Expanded` there
                    // asserts. Square because the photocard itself is square, so
                    // the `FittedBox` inside has the aspect ratio it wants.
                    AspectRatio(
                      aspectRatio: 1,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Center(
                                child: FittedBox(
                                  fit: BoxFit.contain,
                                  child: RepaintBoundary(
                                    key: _captureKey,
                                    child: EcoActionPhotocard(
                                      data: widget.data,
                                      actionPhoto: _actionPhoto,
                                      championPhoto: _championPhoto,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (_preparing)
                            const Positioned.fill(
                              child: ColoredBox(
                                color: Color(0xA8FFFFFF),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              ),
                            ),
                          if (_preparationError != null)
                            Positioned.fill(
                              child: ColoredBox(
                                color: theme.colorScheme.surface.withValues(
                                  alpha: .94,
                                ),
                                child: Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(28),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.broken_image_outlined,
                                          size: 42,
                                          color: theme.colorScheme.error,
                                        ),
                                        const SizedBox(height: 12),
                                        Text(
                                          _preparationError!,
                                          textAlign: TextAlign.center,
                                        ),
                                        const SizedBox(height: 14),
                                        OutlinedButton.icon(
                                          onPressed: _prepareImages,
                                          icon: const Icon(Icons.refresh),
                                          label: const Text('Retry'),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              if (!privacyReady)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      'Confirm the privacy check above to export this anonymous card.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: ready ? _save : null,
                      icon: const Icon(Icons.download_outlined),
                      label: Text(kIsWeb ? 'Download PNG' : 'Save PNG'),
                    ),
                    Builder(
                      builder: (buttonContext) => OutlinedButton.icon(
                        onPressed: ready ? () => _share(buttonContext) : null,
                        icon: const Icon(Icons.share_outlined),
                        label: const Text('Share'),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: ready ? _print : null,
                      icon: const Icon(Icons.print_outlined),
                      label: const Text('Print'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrivacyNotice extends StatelessWidget {
  const _PrivacyNotice({required this.data});

  final EcoActionPhotocardData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final named = data.publishesIdentity;
    final background = named
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.secondaryContainer;
    final foreground = named
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSecondaryContainer;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            named ? Icons.person_pin : Icons.visibility_off_outlined,
            size: 18,
            color: foreground,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              data.publicationLabel,
              style: theme.textTheme.labelMedium?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
