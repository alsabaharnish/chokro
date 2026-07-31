import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/geo.dart';
import '../../controllers/disposal_controller.dart';
import '../../services/location_service.dart';

/// Step 3 of the disposal flow (F2.4, F2.5): capture a location fix and check it
/// against the bin's geofence.
///
/// The distance shown here is computed on the device and is **feedback only**.
/// The server recomputes it from the stored coordinates when it decides. Showing
/// it anyway is worth the duplication: a user who is 200 m away should find out
/// before photographing a bag, not after submitting.
class DisposalLocationView extends ConsumerWidget {
  const DisposalLocationView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(disposalDraftProvider);
    final controller = ref.read(disposalDraftProvider.notifier);
    final theme = Theme.of(context);
    final bin = draft.bin;

    if (bin == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Check location')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Scan a bin code first.'),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Back'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final location = draft.location;
    final distance = draft.distanceMeters;
    final withinRadius = draft.isWithinRadius;

    return Scaffold(
      appBar: AppBar(title: const Text('Check location')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.delete_outline),
                    title: Text(bin.label),
                    subtitle: Text('Accepts submissions within '
                        '${bin.radiusMeters.round()} m'),
                  ),
                ),
                const SizedBox(height: 20),

                Text('Where you are', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Your position is checked against the bin. This is what makes '
                  'a disposal verifiable rather than just claimed.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 16),

                if (location == null || location.outcome == LocationOutcome.idle)
                  _Placeholder(theme: theme)
                else if (draft.isLocating)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (location.hasFix)
                  _FixResult(
                    theme: theme,
                    distance: distance,
                    withinRadius: withinRadius,
                    radius: bin.radiusMeters,
                    accuracy: location.accuracyMeters,
                    lowAccuracy: location.isLowAccuracy,
                  )
                else
                  _LocationProblem(
                    theme: theme,
                    location: location,
                    onOpenSettings: controller.openLocationSettings,
                  ),

                const SizedBox(height: 24),

                if (!draft.isLocating) ...[
                  FilledButton.icon(
                    onPressed: controller.captureLocation,
                    icon: const Icon(Icons.my_location),
                    label: Text(location != null && location.hasFix
                        ? 'Check again'
                        : 'Check my location'),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    // Only offered once the fix puts the user inside the bin's
                    // radius. The server checks this again and does not trust
                    // the client's answer (F2.5) — but letting someone walk
                    // through the rest of the flow only to be refused would be
                    // a poor experience.
                    onPressed: withinRadius
                        ? () => context.push('/dispose/declare')
                        : null,
                    icon: const Icon(Icons.checklist),
                    label: const Text('Continue'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  final ThemeData theme;
  const _Placeholder({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          children: [
            Icon(Icons.location_searching,
                color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                'Stand next to the bin, then check your location.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FixResult extends StatelessWidget {
  final ThemeData theme;
  final double? distance;
  final bool withinRadius;
  final double radius;
  final double? accuracy;
  final bool lowAccuracy;

  const _FixResult({
    required this.theme,
    required this.distance,
    required this.withinRadius,
    required this.radius,
    required this.accuracy,
    required this.lowAccuracy,
  });

  @override
  Widget build(BuildContext context) {
    final good = withinRadius;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          color: good
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Icon(
                  good ? Icons.check_circle : Icons.location_off,
                  size: 32,
                  color: good
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        distance == null
                            ? 'Distance unknown'
                            : '${formatDistance(distance!)} from the bin',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: good
                              ? theme.colorScheme.onPrimaryContainer
                              : theme.colorScheme.onErrorContainer,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        good
                            ? 'You are within the ${radius.round()} m radius.'
                            : 'Too far away. Move closer than ${radius.round()} m '
                                'and check again.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: good
                              ? theme.colorScheme.onPrimaryContainer
                              : theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (accuracy != null) ...[
          const SizedBox(height: 8),
          Text(
            'Fix accurate to about ${accuracy!.round()} m'
            '${lowAccuracy ? ' — move into the open for a better fix' : ''}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _LocationProblem extends StatelessWidget {
  final ThemeData theme;
  final LocationResult location;
  final VoidCallback onOpenSettings;

  const _LocationProblem({
    required this.theme,
    required this.location,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final needsSettings =
        location.outcome == LocationOutcome.deniedForever ||
            location.outcome == LocationOutcome.serviceDisabled;

    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline,
                    color: theme.colorScheme.onErrorContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    location.displayMessage,
                    style: TextStyle(
                        color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              ],
            ),
            if (needsSettings) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: onOpenSettings,
                child: const Text('Open settings'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
