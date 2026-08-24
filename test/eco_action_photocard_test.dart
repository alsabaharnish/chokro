import 'dart:convert';
import 'dart:typed_data';

import 'package:chokro/core/eco_action_photocard.dart';
import 'package:chokro/models/claim_model.dart';
import 'package:chokro/views/admin/eco_action_photocard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

final Uint8List _pixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

ClaimModel _approvedClaim({
  ClaimPublicationMode publicationMode = ClaimPublicationMode.anonymous,
  String? championName,
  String? championPhotoUrl,
  String story = 'We cleaned the park together.',
  ClaimStatus status = ClaimStatus.approved,
}) => ClaimModel(
  id: 'claim-42',
  userId: 'private-user-id',
  actionType: ClaimActionType.communityCleanup,
  photoUrl: 'https://example.test/action.png',
  story: story,
  publicationMode: publicationMode,
  championName: championName,
  championPhotoUrl: championPhotoUrl,
  status: status,
  pointsAwarded: 15,
  reviewedBy: 'admin-1',
  reviewedAt: DateTime.utc(2026, 8, 24),
  createdAt: DateTime.utc(2026, 8, 23),
);

void main() {
  test(
    'anonymous payload drops identity even when malformed data contains it',
    () {
      final data = EcoActionPhotocardData.fromApprovedClaim(
        _approvedClaim(
          championName: 'DO NOT PUBLISH',
          championPhotoUrl: 'https://example.test/private-profile.png',
        ),
      );

      expect(data.publishesIdentity, isFalse);
      expect(data.championName, isNull);
      expect(data.championPhotoUrl, isNull);
      expect(data.shareText, isNot(contains('DO NOT PUBLISH')));
      expect(data.fileStem, isNot(contains('private-user-id')));
    },
  );

  test('named payload carries only the explicitly permitted identity', () {
    final data = EcoActionPhotocardData.fromApprovedClaim(
      _approvedClaim(
        publicationMode: ClaimPublicationMode.named,
        championName: 'Amina Rahman',
        championPhotoUrl: 'https://example.test/amina.png',
      ),
    );

    expect(data.publishesIdentity, isTrue);
    expect(data.championName, 'Amina Rahman');
    expect(data.championPhotoUrl, 'https://example.test/amina.png');
    expect(data.fileStem, 'chokro-eco-action-claim-42');
  });

  test('release-mode guards refuse unapproved or unpermitted claims', () {
    expect(
      () => EcoActionPhotocardData.fromApprovedClaim(
        _approvedClaim(status: ClaimStatus.pending),
      ),
      throwsStateError,
    );
    expect(
      () => EcoActionPhotocardData.fromApprovedClaim(
        _approvedClaim(publicationMode: ClaimPublicationMode.unspecified),
      ),
      throwsStateError,
    );
    expect(
      () => EcoActionPhotocardData.fromApprovedClaim(
        _approvedClaim(
          publicationMode: ClaimPublicationMode.named,
          championName: 'Amina Rahman',
          championPhotoUrl: '   ',
        ),
      ),
      throwsStateError,
    );
  });

  test('long stories are explicitly condensed to a readable card excerpt', () {
    final story = List.filled(100, 'পরিবেশ রক্ষা করি').join(' ');
    final data = EcoActionPhotocardData.fromApprovedClaim(
      _approvedClaim(story: story),
    );

    expect(data.story, story);
    expect(data.storyIsCondensed, isTrue);
    expect(
      data.photocardStory.runes.length,
      EcoActionPhotocardData.maxPhotocardStoryRunes,
    );
    expect(data.photocardStory, endsWith('…'));
  });

  test('print export embeds the captured card in a PDF', () async {
    final pdf = await buildEcoActionPhotocardPrintPdf(_pixelPng);

    expect(pdf, isNotEmpty);
    expect(ascii.decode(pdf.take(4).toList()), '%PDF');
  });

  testWidgets('anonymous card never renders identity left on the claim', (
    tester,
  ) async {
    final data = EcoActionPhotocardData.fromApprovedClaim(
      _approvedClaim(
        championName: 'DO NOT PUBLISH',
        championPhotoUrl: 'https://example.test/private-profile.png',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: EcoActionPhotocard(
              data: data,
              actionPhoto: MemoryImage(_pixelPng),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('DO NOT PUBLISH'), findsNothing);
    expect(find.text('Anonymous 3ZERO Champion'), findsOneWidget);
  });

  testWidgets('2x capture produces an exact 1080 square photocard', (
    tester,
  ) async {
    final captureKey = GlobalKey();
    final data = EcoActionPhotocardData.fromApprovedClaim(_approvedClaim());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: captureKey,
              child: EcoActionPhotocard(
                data: data,
                actionPhoto: MemoryImage(_pixelPng),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final boundary =
        captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    addTearDown(image.dispose);

    expect(image.width, 1080);
    expect(image.height, 1080);
  });

  testWidgets('complete long names fit without ellipsis at large text scale', (
    tester,
  ) async {
    final longName = List.filled(6, 'Amina Rahman').join(' ');
    final data = EcoActionPhotocardData.fromApprovedClaim(
      _approvedClaim(
        publicationMode: ClaimPublicationMode.named,
        championName: longName,
        championPhotoUrl: 'https://example.test/amina.png',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Center(
              child: EcoActionPhotocard(
                data: data,
                actionPhoto: MemoryImage(_pixelPng),
                championPhoto: MemoryImage(_pixelPng),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(longName), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
