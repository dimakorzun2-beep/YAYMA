import 'package:yayma/src/features/auth/providers/auth_provider.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/features/spotify/spotify_service.dart';
import 'package:yayma/src/rust/api/content.dart' as content;
import 'package:yayma/src/rust/api/playback.dart';

class HomeController {
  static Future<void> startMyWave() async {
    final currentSeeds = currentWaveSeedsSignal();
    var seeds = currentSeeds.isNotEmpty ? currentSeeds : ['user:onyourwave'];

    // Spotify in "My Wave": take the user's Spotify top / liked tracks,
    // find them on Yandex Music and use them as wave seeds.
    final isDefaultWave =
        seeds.length == 1 && seeds.first == 'user:onyourwave';
    if (isDefaultWave &&
        spotifyConnectedSignal.value &&
        spotifyWaveSignal.value) {
      final spotifySeeds = await _spotifySeeds();
      if (spotifySeeds.isNotEmpty) seeds = spotifySeeds;
    }

    await runRustAction(
      (ctx) => startWave(ctx: ctx, seeds: seeds),
    );
    setSection(AppSection.home);
  }

  static Future<List<String>> _spotifySeeds() async {
    final result = <String>[];
    try {
      final tracks = await SpotifyService.seedTracks();
      for (final t in tracks) {
        final found = await runRustFetch(
          (ctx) => content.search(ctx: ctx, query: '${t.artist} ${t.title}'),
        );
        final match = found?.tracks.isNotEmpty == true
            ? found!.tracks.first
            : null;
        if (match != null) result.add('track:${match.id}:${match.title}');
      }
    } on Object catch (_) {}
    return result;
  }
}
