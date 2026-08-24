import 'package:flutter/material.dart';

import '../../core/eco_action_photocard.dart';
import '../../core/label_format.dart';

/// The single square rendering used for preview, PNG export and printing.
class EcoActionPhotocard extends StatelessWidget {
  EcoActionPhotocard({
    super.key,
    required this.data,
    required this.actionPhoto,
    this.championPhoto,
  }) : assert(
         data.publishesIdentity == (championPhoto != null),
         'Named cards require a profile photo; anonymous cards must not receive one.',
       );

  /// Logical size. Export captures this at 2x for a 1080 × 1080 image.
  static const double logicalSize = 540;
  static const String brandAsset = 'assets/brand/chokro_app_icon.png';

  final EcoActionPhotocardData data;
  final ImageProvider actionPhoto;

  /// Must remain null for an anonymous card.
  final ImageProvider? championPhoto;

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF07583F);
    const ink = Color(0xFF10231B);
    const paper = Color(0xFFF4F8F4);
    const gold = Color(0xFFF0B94A);

    // Export dimensions and typography must not change with the admin's local
    // accessibility text scale. The surrounding dialog still scales normally.
    return MediaQuery.withNoTextScaling(
      child: Semantics(
        label: data.publishesIdentity
            ? 'Named eco-action photocard for ${data.championName}'
            : 'Anonymous eco-action photocard',
        image: true,
        child: Material(
          color: paper,
          child: SizedBox.square(
            dimension: logicalSize,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: 62,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  color: green,
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(9),
                        child: Image.asset(
                          brandAsset,
                          width: 38,
                          height: 38,
                          fit: BoxFit.cover,
                          filterQuality: FilterQuality.high,
                        ),
                      ),
                      const SizedBox(width: 11),
                      const Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'CHOKRO',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 19,
                                height: 1,
                                letterSpacing: 2.1,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              '3ZERO ACTIONS',
                              style: TextStyle(
                                color: Color(0xFFD8EFE5),
                                fontSize: 9,
                                height: 1,
                                letterSpacing: 1.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: gold,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.verified_rounded, size: 14, color: ink),
                            SizedBox(width: 5),
                            Text(
                              'ADMIN APPROVED',
                              style: TextStyle(
                                color: ink,
                                fontSize: 9,
                                letterSpacing: .65,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 260,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image(
                        image: actionPhoto,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.high,
                        errorBuilder: (_, _, _) => const ColoredBox(
                          color: Color(0xFFDDE9E1),
                          child: Center(
                            child: Icon(
                              Icons.eco_outlined,
                              color: green,
                              size: 52,
                            ),
                          ),
                        ),
                      ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Color(0xB8002418)],
                            stops: [.48, 1],
                          ),
                        ),
                      ),
                      Positioned(
                        left: 20,
                        right: 20,
                        bottom: 18,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'ECO-ACTION',
                              style: TextStyle(
                                color: Color(0xFFD9F2E7),
                                fontSize: 10,
                                letterSpacing: 1.8,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              data.actionLabel,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                height: 1.08,
                                letterSpacing: -.5,
                                fontWeight: FontWeight.w900,
                                shadows: [
                                  Shadow(color: Colors.black38, blurRadius: 8),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(22, 15, 22, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'THE STORY',
                          style: TextStyle(
                            color: green,
                            fontSize: 9,
                            letterSpacing: 1.7,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 7),
                        Expanded(
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: _FittedStory(
                              text: data.story.isEmpty
                                  ? 'Small actions today create a cleaner, greener tomorrow.'
                                  : '“${data.photocardStory}”',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Container(
                  height: 94,
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(top: BorderSide(color: Color(0xFFD8E5DD))),
                  ),
                  child: Row(
                    children: [
                      _ChampionAvatar(
                        publishesIdentity: data.publishesIdentity,
                        championPhoto: championPhoto,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _FittedChampionName(
                              name: data.publishesIdentity
                                  ? data.championName!
                                  : 'Anonymous 3ZERO Champion',
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Building a world of zero waste',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Color(0xFF587166),
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (data.createdAt != null)
                        Text(
                          formatDate(data.createdAt),
                          style: const TextStyle(
                            color: Color(0xFF587166),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Fits the complete stored name into at most two lines without ellipsis.
class _FittedChampionName extends StatelessWidget {
  const _FittedChampionName({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    const baseStyle = TextStyle(
      color: Color(0xFF10231B),
      fontSize: 15,
      height: 1.08,
      fontWeight: FontWeight.w900,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        var size = baseStyle.fontSize!;
        while (size > 6) {
          final painter = TextPainter(
            text: TextSpan(
              text: name,
              style: baseStyle.copyWith(fontSize: size),
            ),
            maxLines: 2,
            textDirection: Directionality.of(context),
          )..layout(maxWidth: constraints.maxWidth);
          if (!painter.didExceedMaxLines) break;
          size -= .5;
        }

        return Text(
          name,
          maxLines: 2,
          style: baseStyle.copyWith(fontSize: size),
        );
      },
    );
  }
}

class _FittedStory extends StatelessWidget {
  const _FittedStory({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    const baseStyle = TextStyle(
      color: Color(0xFF10231B),
      fontSize: 15,
      height: 1.18,
      fontWeight: FontWeight.w600,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        var size = baseStyle.fontSize!;
        while (size > 8) {
          final painter = TextPainter(
            text: TextSpan(
              text: text,
              style: baseStyle.copyWith(fontSize: size),
            ),
            maxLines: 5,
            textDirection: Directionality.of(context),
          )..layout(maxWidth: constraints.maxWidth);
          if (!painter.didExceedMaxLines &&
              painter.height <= constraints.maxHeight) {
            break;
          }
          size -= .5;
        }

        return Text(
          text,
          maxLines: 5,
          style: baseStyle.copyWith(fontSize: size),
        );
      },
    );
  }
}

class _ChampionAvatar extends StatelessWidget {
  const _ChampionAvatar({
    required this.publishesIdentity,
    required this.championPhoto,
  });

  final bool publishesIdentity;
  final ImageProvider? championPhoto;

  @override
  Widget build(BuildContext context) {
    if (!publishesIdentity) {
      return const CircleAvatar(
        radius: 24,
        backgroundColor: Color(0xFFD9ECE2),
        child: Icon(Icons.eco_rounded, color: Color(0xFF07583F), size: 25),
      );
    }

    return CircleAvatar(
      radius: 24,
      backgroundColor: const Color(0xFFD9ECE2),
      foregroundImage: championPhoto,
      child: const Icon(Icons.person, color: Color(0xFF07583F)),
    );
  }
}
