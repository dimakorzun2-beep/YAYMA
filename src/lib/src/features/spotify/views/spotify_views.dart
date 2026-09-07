import 'dart:async';

import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/core/views/widgets/responsive.dart';
import 'package:yayma/src/features/core/views/widgets/rust_cached_image.dart';
import 'package:yayma/src/features/spotify/providers/spotify_provider.dart';

class SpotifySearchResults extends StatelessWidget {
  final List<SpotifyTrack> tracks;

  const SpotifySearchResults({required this.tracks, super.key});

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) {
      return Center(
        child: Text(
          'Ничего не найдено',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 18,
          ),
        ),
      );
    }
    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(
          child: CommonSectionTitle(title: 'Треки из Spotify'),
        ),
        SliverM3ECardList(
          haptic: M3EHapticFeedback.light,
          itemCount: tracks.length,
          color: Colors.transparent,
          padding: EdgeInsets.symmetric(
            horizontal: context.isNarrow ? 0 : 32,
            vertical: 4,
          ),
          itemBuilder: (context, i) =>
              SpotifyTrackTile(track: tracks[i], index: i + 1),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
        const SliverPadding(padding: EdgeInsets.only(bottom: 140)),
      ],
    );
  }
}

class SpotifyTrackTile extends StatelessWidget {
  final SpotifyTrack track;
  final int? index;

  const SpotifyTrackTile({required this.track, this.index, super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isNarrow = context.isNarrow;
    final liked = SignalBuilder(
      builder: (context) {
        final isLiked = SpotifyController.isLiked(track);
        return IconButton(
          onPressed: () => unawaited(SpotifyController.toggleLike(track)),
          icon: Icon(
            isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            color: isLiked ? const Color(0xFF1DB954) : cs.onSurfaceVariant,
            size: 22,
          ),
        );
      },
    );

    return InkWell(
      onTap: () => unawaited(SpotifyController.playSpotifyTrack(track)),
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: isNarrow ? 8 : 12,
          vertical: isNarrow ? 6 : 8,
        ),
        child: Row(
          children: [
            if (index != null) ...[
              SizedBox(
                width: 24,
                child: Text(
                  '$index',
                  style: TextStyle(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(width: 8),
            ],
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: track.coverUrl != null
                  ? RustCachedImage(
                      imageUrl: track.coverUrl!,
                      width: 52,
                      height: 52,
                    )
                  : Container(
                      width: 52,
                      height: 52,
                      color: cs.onSurface.withValues(alpha: 0.08),
                      child: Icon(
                        Icons.music_note_rounded,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    track.artists,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatDuration(track.durationMs),
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
            ),
            liked,
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}
