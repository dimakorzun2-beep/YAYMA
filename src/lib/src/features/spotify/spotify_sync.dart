// Glue between Spotify and the Yandex Music side of the app.
import 'dart:async';

import 'package:yayma/src/features/auth/providers/auth_provider.dart';
import 'package:yayma/src/features/core/providers/notification_provider.dart';
import 'package:yayma/src/features/library/providers/library_provider.dart';
import 'package:yayma/src/features/spotify/spotify_service.dart';
import 'package:yayma/src/rust/api/content.dart' as content;
import 'package:yayma/src/rust/api/library.dart' as library;
import 'package:yayma/src/rust/api/models.dart';

class SpotifySync {
  static bool _running = false;

  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), '')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();

  /// Finds the same track on Yandex Music.
  static Future<SimpleTrackDto?> findOnYandex(SpotifySeedTrack t) async {
    final found = await runRustFetch(
      (ctx) => content.search(ctx: ctx, query: '${t.artist} ${t.title}'),
    );
    final tracks = found?.tracks ?? const <SimpleTrackDto>[];
    if (tracks.isEmpty) return null;
    final title = _norm(t.title);
    final artist = _norm(t.artist);
    for (final y in tracks.take(5)) {
      final yt = _norm(y.title);
      final sameTitle = yt.contains(title) || title.contains(yt);
      final sameArtist = y.artists.any((a) {
        final n = _norm(a.name);
        return n.contains(artist) || artist.contains(n);
      });
      if (sameTitle && sameArtist) return y;
    }
    return null;
  }

  /// Takes every track from Spotify "Liked Songs", finds it on Yandex Music
  /// and adds it to "Мне нравится" with a Spotify badge, so it can be played.
  static Future<void> importLikes() async {
    if (_running || !spotifyConnectedSignal.value) return;
    _running = true;
    try {
      spotifyImportStatusSignal.value = 'Загружаю треки из Spotify…';
      final tracks = await SpotifyService.savedTracks();
      final imported = <String>[];
      var missing = 0;
      for (var i = 0; i < tracks.length; i++) {
        spotifyImportStatusSignal.value =
            'Переношу из Spotify: ${i + 1} / ${tracks.length}';
        final y = await findOnYandex(tracks[i]);
        if (y == null) {
          missing++;
          continue;
        }
        if (!y.isLiked) {
          // Direct call: no need to mirror this like back to Spotify.
          await runRustAction(
            (ctx) => library.toggleLike(ctx: ctx, trackId: y.id),
          );
        }
        imported.add(y.id);
        if (imported.length % 20 == 0) {
          await SpotifySync._flush(imported);
        }
      }
      await _flush(imported);
      unawaited(refreshLikedTracks(force: true));
      showAppSuccess(
        'Из Spotify добавлено ${imported.length} треков'
        '${missing > 0 ? ', не нашлось в Яндексе: $missing' : ''}',
      );
    } on Object catch (_) {
      showAppError('Не удалось перенести треки из Spotify');
    } finally {
      spotifyImportStatusSignal.value = null;
      _running = false;
    }
  }

  static Future<void> _flush(List<String> ids) =>
      SpotifyService.markImported(ids);

  /// Spotify tracks matched to Yandex, as wave seeds.
  static Future<List<String>> waveSeeds() async {
    final result = <String>[];
    try {
      final tracks = await SpotifyService.seedTracks();
      for (final t in tracks) {
        final y = await findOnYandex(t);
        if (y != null) result.add('track:${y.id}:${y.title}');
      }
    } on Object catch (_) {}
    return result;
  }
}
