import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/claim_model.dart';

/// The privacy-resolved data that may cross into a public eco-action card.
///
/// This is deliberately narrower than [ClaimModel]. In particular, the
/// anonymous branch never copies the Champion's name or profile-photo URL, so
/// the renderer and exporters cannot accidentally reveal either value later.
class EcoActionPhotocardData {
  const EcoActionPhotocardData._({
    required this.claimId,
    required this.actionLabel,
    required this.actionPhotoUrl,
    required this.story,
    required this.createdAt,
    this.championName,
    this.championPhotoUrl,
  });

  factory EcoActionPhotocardData.fromApprovedClaim(ClaimModel claim) {
    if (!claim.status.isApproved) {
      throw StateError('Only an approved eco-action can become a photocard.');
    }
    if (!claim.hasPublicationPermission) {
      throw StateError(
        'This eco-action has no recorded public sharing permission.',
      );
    }

    if (claim.isAnonymousPublication) {
      return EcoActionPhotocardData._(
        claimId: claim.id,
        actionLabel: claim.actionType.label,
        actionPhotoUrl: claim.photoUrl,
        story: claim.story.trim(),
        createdAt: claim.createdAt,
      );
    }

    return EcoActionPhotocardData._(
      claimId: claim.id,
      actionLabel: claim.actionType.label,
      actionPhotoUrl: claim.photoUrl,
      story: claim.story.trim(),
      createdAt: claim.createdAt,
      championName: claim.championName!.trim(),
      championPhotoUrl: claim.championPhotoUrl!.trim(),
    );
  }

  final String? claimId;
  final String actionLabel;
  final String actionPhotoUrl;
  final String story;
  final DateTime? createdAt;

  /// Null by construction for an anonymous card.
  final String? championName;

  /// Null by construction for an anonymous card.
  final String? championPhotoUrl;

  bool get publishesIdentity =>
      championName != null && championPhotoUrl != null;

  static const int maxPhotocardStoryRunes = 220;

  bool get storyIsCondensed => story.runes.length > maxPhotocardStoryRunes;

  /// A square social card needs a readable excerpt; the full story remains in
  /// the approved-action gallery for the administrator to review.
  String get photocardStory {
    if (!storyIsCondensed) return story;
    return '${String.fromCharCodes(story.runes.take(maxPhotocardStoryRunes - 1))}…';
  }

  /// Never includes a Champion's name, even for a named card.
  ///
  /// Apart from keeping downloads easy to recognise, this prevents filenames
  /// copied between systems from disclosing more than the card itself needs.
  String get fileStem {
    final safeId = (claimId ?? '')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return 'chokro-eco-action-${safeId.isEmpty ? 'photocard' : safeId}';
  }

  String get publicationLabel => publishesIdentity
      ? 'Name and profile photo permitted'
      : 'Saved name and profile photo hidden';

  String get shareText => publishesIdentity
      ? '${championName!} is taking action for a greener future with Chokro.'
      : 'A 3ZERO Champion is taking action for a greener future with Chokro.';
}

/// Places the captured square card on a printable A4 page.
///
/// The input is the exact PNG shown in the preview and shared to social media,
/// rather than a second PDF-only rendering of the same content. Preview, image
/// export and paper therefore cannot drift apart.
Future<Uint8List> buildEcoActionPhotocardPrintPdf(Uint8List pngBytes) async {
  if (pngBytes.isEmpty) {
    throw ArgumentError.value(pngBytes, 'pngBytes', 'The card image is empty.');
  }

  const margin = 18 * PdfPageFormat.mm;
  final image = pw.MemoryImage(pngBytes);
  final side = PdfPageFormat.a4.width - (margin * 2);
  final document = pw.Document(title: 'Chokro approved eco-action photocard');

  document.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(margin),
      build: (_) => pw.Center(
        child: pw.SizedBox.square(
          dimension: side,
          child: pw.Image(image, fit: pw.BoxFit.contain),
        ),
      ),
    ),
  );

  return document.save();
}
