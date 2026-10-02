import 'package:yayma/src/features/auth/providers/auth_provider.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/features/spotify/spotify_service.dart';
import 'package:yayma/src/features/spotify/spotify_sync.dart';
import 'package:yayma/src/rust/api/playback.dart';

class HomeController {
  static Future<void> startMyWave() async {
    final currentSeeds = currentWaveSeedsSignal();
    final seeds = currentSeeds.isNotEmpty ? currentSeeds : ['user:onyourwave'];

    // Mix Spotify into "My Wave": the Yandex wave plus seeds made from the
    // user's Spotify top / liked tracks.
    final isDefaultWave =
        seeds.length == 1 && seeds.first == 'user:onyourwave';
    if (isDefaultWave &&
        spotifyConnectedSignal.value &&
        spotifyWaveSignal.value) {
      final spotifySeeds = await SpotifySync.waveSeeds();
      if (spotifySeeds.isNotEmpty) {
        final mixed = ['user:onyourwave', ...spotifySeeds];
        final ok = await runRustAction(
          (ctx) => startWave(ctx: ctx, seeds: mixed),
        );
        if (ok) {
          setSection(AppSection.home);
          return;
        }
      }
    }

    await runRustAction(
      (ctx) => startWave(ctx: ctx, seeds: seeds),
    );
    setSection(AppSection.home);
  }
}
