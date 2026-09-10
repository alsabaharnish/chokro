import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../controllers/compliance_controller.dart';
import '../../core/api_config.dart';
import '../../core/epr_period.dart';
import '../../core/theme.dart';
import '../../models/plastic_passport_model.dart';
import '../../services/organization_service.dart' show OrgActionException;
import '../shared/app_shell.dart';
import '../shared/app_snackbar.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';
import '../shared/notice_card.dart';

/// The company's Plastic Passports (EPR-28 to EPR-31, NFR-E-4).
///
/// ## Why this screen downloads a PDF instead of rendering one
///
/// This app can build PDFs — `bin_label_pdf.dart` does, and the `printing`
/// package is already a dependency. Rendering the certificate here would have
/// been the shorter path and would have worked offline.
///
/// EPR-31 rules it out in one sentence: "a certificate a user's device produced
/// is a certificate a user's device can alter". The serial, the content hash
/// and the figure snapshot are minted server-side, and this screen fetches
/// bytes it did not compose. What it hands to the share sheet is the artefact
/// Chokro issued, byte for byte, and the hash printed inside it is the hash a
/// third party will check.
///
/// ## Why a superseded certificate is shown rather than hidden
///
/// The instinct is to list only current certificates — a superseded one is not
/// something the producer should be sending anyone. But it has already been
/// sent: reissue supersedes precisely because the old copy stays in
/// circulation. A producer that cannot see the superseded certificate cannot
/// answer the customer holding it, and cannot tell which of the two the
/// customer has.
///
/// So every certificate is listed, each says plainly whether it still stands,
/// and the ones that do not say why.
class PassportsView extends ConsumerWidget {
  const PassportsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final passports = ref.watch(passportsProvider);

    return AppShell(
      title: 'Plastic Passports',
      child: RefreshIndicator(
        onRefresh: () async => ref.invalidate(passportsProvider),
        child: passports.when(
          loading: () => const ContentLoading(
            label: 'Loading…',
            slowHint: ContentLoading.serverWakingHint,
          ),
          error: (error, _) => ErrorRetry(
            error: error,
            onRetry: () => ref.invalidate(passportsProvider),
          ),
          data: (rows) => ListView(
            padding: const EdgeInsets.all(AppTheme.gapMd),
            children: [
              const _Explainer(),
              const SizedBox(height: AppTheme.gapMd),
              if (rows.isEmpty)
                const NoticeCard(
                  icon: Icons.workspace_premium_outlined,
                  tone: NoticeTone.info,
                  title: 'No certificates yet',
                  message:
                      'Chokro issues a Plastic Passport for a period once its '
                      'figures are settled. File your put-on-market '
                      'declaration first — without it a certificate can state '
                      'the mass collected but no collection percentage.',
                )
              else
                for (final passport in rows) ...[
                  _PassportCard(passport: passport),
                  const SizedBox(height: AppTheme.gapMd),
                ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Explainer extends StatelessWidget {
  const _Explainer();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'What a Plastic Passport states',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppTheme.gapSm),
            Text(
              'It states what Chokro collected of your packaging in a period, '
              'and — if you filed a declaration — what share that is of what '
              'you placed on the market. It is not a statement of compliance '
              'with the 2024 gazette, and it does not state a recycling rate: '
              'Chokro records collection and holds no evidence of what was '
              'recycled downstream.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppTheme.gapSm),
            Text(
              'Anyone can verify a certificate from its serial without a '
              'Chokro account. They are shown only that it exists, whether it '
              'still stands, your trade name, the period, and the content '
              'hash — no figures and no evidence.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _PassportCard extends ConsumerStatefulWidget {
  const _PassportCard({required this.passport});

  final PlasticPassportModel passport;

  @override
  ConsumerState<_PassportCard> createState() => _PassportCardState();
}

class _PassportCardState extends ConsumerState<_PassportCard> {
  String? _downloading;

  @override
  Widget build(BuildContext context) {
    final passport = widget.passport;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        periodLabel(passport.periodId),
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        passport.serial,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
                _StatusPill(status: passport.status),
              ],
            ),

            // Why it no longer stands, when it does not. The producer's real
            // question about a superseded certificate is what to tell the
            // customer holding it.
            if (!passport.isCurrent) ...[
              const SizedBox(height: AppTheme.gapSm),
              NoticeCard(
                icon: passport.status == PassportStatus.revoked
                    ? Icons.gpp_bad_outlined
                    : Icons.history,
                tone: passport.status == PassportStatus.revoked
                    ? NoticeTone.error
                    : NoticeTone.warning,
                message: [
                  PassportStatus.explain(passport.status),
                  ?passport.withdrawalReason,
                ].join(' '),
              ),
            ],

            const SizedBox(height: AppTheme.gapMd),
            _HashRow(passport: passport),
            const SizedBox(height: AppTheme.gapSm),
            _VerifyRow(serial: passport.serial),
            const SizedBox(height: AppTheme.gapMd),

            // Both editions, side by side and equally weighted. NFR-E-4 asks
            // for Bangla; presenting it as a secondary option would make it
            // the afterthought the requirement exists to prevent.
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _downloading != null
                        ? null
                        : () => _download('en', 'English'),
                    icon: _downloading == 'en'
                        ? const _TinySpinner()
                        : const Icon(Icons.download_outlined),
                    label: const Text('English'),
                  ),
                ),
                const SizedBox(width: AppTheme.gapSm),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _downloading != null
                        ? null
                        : () => _download('bn', 'Bangla'),
                    icon: _downloading == 'bn'
                        ? const _TinySpinner()
                        : const Icon(Icons.download_outlined),
                    label: const Text('বাংলা'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _download(String locale, String label) async {
    final snack = AppSnackBar.of(context);
    setState(() => _downloading = locale);

    try {
      final bytes = await ref
          .read(complianceServiceProvider)
          .downloadPassport(serial: widget.passport.serial, locale: locale);

      await Printing.sharePdf(
        bytes: bytes,
        filename:
            'chokro-plastic-passport-${widget.passport.periodId}-$locale.pdf',
      );
    } on OrgActionException catch (error) {
      snack.failure(error.message);
    } catch (_) {
      snack.failure('The $label certificate could not be downloaded.');
    } finally {
      if (mounted) setState(() => _downloading = null);
    }
  }
}

/// The content hash, copyable.
///
/// Shown to the producer so it can be compared against the hash printed inside
/// the PDF — the same check a third party makes at the verification endpoint,
/// available without going through it.
class _HashRow extends StatelessWidget {
  const _HashRow({required this.passport});

  final PlasticPassportModel passport;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          Icons.tag,
          size: 16,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(width: AppTheme.gapSm),
        Expanded(
          child: Text(
            'Content hash ${passport.shortHash}…',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        IconButton(
          tooltip: 'Copy the full hash',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.copy, size: 16),
          onPressed: () {
            final snack = AppSnackBar.of(context);
            Clipboard.setData(ClipboardData(text: passport.contentHash));
            snack.success('Content hash copied.');
          },
        ),
      ],
    );
  }
}

class _VerifyRow extends StatelessWidget {
  const _VerifyRow({required this.serial});

  final String serial;

  /// The address printed on the certificate itself.
  ///
  /// Built from the same origin the app talks to, so a staging build shows its
  /// staging verification link rather than sending somebody to production for
  /// a certificate production has never heard of.
  String get _url => '${ApiConfig.baseUrl}/passports/verify/$serial';

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          Icons.verified_outlined,
          size: 16,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(width: AppTheme.gapSm),
        Expanded(
          child: Text(
            'Anyone can verify this at $_url',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        IconButton(
          tooltip: 'Copy the verification link',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.link, size: 16),
          onPressed: () {
            final snack = AppSnackBar.of(context);
            Clipboard.setData(ClipboardData(text: _url));
            snack.success('Verification link copied.');
          },
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (status) {
      PassportStatus.issued => (scheme.successContainer, scheme.onSuccessContainer),
      PassportStatus.superseded => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      // An unrecognised status reads as a problem rather than as fine. A future
      // state Chokro adds would almost certainly be another kind of withdrawal.
      _ => (scheme.errorContainer, scheme.onErrorContainer),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.gapSm,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        PassportStatus.label(status),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }
}

class _TinySpinner extends StatelessWidget {
  const _TinySpinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 16,
    height: 16,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}
