import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/core/theme/app_tokens.dart';
import 'package:yayma/src/features/core/views/widgets/common_ui.dart';
import 'package:yayma/src/features/core/views/widgets/responsive.dart';
import 'package:yayma/src/features/core/views/widgets/rust_cached_image.dart';
import 'package:yayma/src/features/spotify/providers/spotify_provider.dart';

class SpotifySearchResults extends StatelessWidget {
  final List<SpotifyTrack> tracks;
  final bool isNarrow;

  const SpotifySearchResults({
    required this.tracks,
    required this.isNarrow,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(
          child: CommonSectionTitle(title: 'Треки из Spotify'),
        ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) => Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isNarrow ? 8 : 32,
                vertical: 2,
              ),
              child: SpotifyTrackTile(track: tracks[i]),
            ),
            childCount: tracks.length,
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 140)),
      ],
    );
  }
}

class SpotifyTrackTile extends SignalWidget {
  final SpotifyTrack track;

  const SpotifyTrackTile({required this.track, super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isNarrow = context.isNarrow;
    final liked = SpotifyController.isLiked(track);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => unawaited(SpotifyController.playSpotifyTrack(track)),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isNarrow ? 8 : 12,
            vertical: isNarrow ? 6 : 8,
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.md),
                child: track.coverUrl != null
                    ? RustCachedImage(
                        imageUrl: track.coverUrl!,
                        width: 52,
                        height: 52,
                        errorWidget: _coverPlaceholder(cs),
                      )
                    : _coverPlaceholder(cs),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: isNarrow ? 15 : 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      track.artists,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: isNarrow ? 12 : 13,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatDuration(track.durationMs),
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: isNarrow ? 12 : 13,
                ),
              ),
              IconButton(
                onPressed: () => unawaited(SpotifyController.toggleLike(track)),
                icon: Icon(
                  liked
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: liked ? cs.primary : cs.onSurfaceVariant,
                  size: 22,
                ),
                tooltip: 'Нравится (Spotify и Яндекс Музыка)',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _coverPlaceholder(ColorScheme cs) => Container(
    width: 52,
    height: 52,
    color: cs.onSurface.withValues(alpha: 0.06),
    child: Icon(Icons.music_note_rounded, color: cs.onSurfaceVariant),
  );
}
