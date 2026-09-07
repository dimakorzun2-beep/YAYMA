import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:yayma/src/features/auth/providers/auth_provider.dart';
import 'package:yayma/src/features/core/providers/navigation_provider.dart';
import 'package:yayma/src/features/core/providers/notification_provider.dart';
import 'package:yayma/src/features/playback/providers/playback_provider.dart';
import 'package:yayma/src/rust/api/content.dart' as rust;
import 'package:yayma/src/rust/api/models.dart';

enum MusicProvider { yandex, spotify }

final FlutterSignal<MusicProvider> musicProviderSignal = signal(
  MusicProvider.yandex,
);

final FlutterSignal<bool> spotifyConfiguredSignal = signal(false);

final FlutterSignal<bool> spotifyUserConnectedSignal = signal(false);

final FlutterSignal<String> spotifyWaveSeedArtistSignal = signal('Face');

final FlutterSignal<List<SpotifyTrack>> spotifyLikedSignal =
    signal<List<SpotifyTrack>>(const []);

final FlutterSignal<String> spotifySearchQuerySignal = signal<String>('');

Timer? _spotifySearchDebounce;

void setSpotifySearchQuery(String query) {
  _spotifySearchDebounce?.cancel();
  _spotifySearchDebounce = Timer(const Duration(milliseconds: 350), () {
    spotifySearchQuerySignal.value = query;
  });
}

class SpotifyNotConnectedException implements Exception {
  @override
  String toString() =>
      'Spotify не подключен — укажите Client ID и Secret в настройках';
}

class SpotifyArtist {
  final String id;
  final String name;
  final String? imageUrl;

  const SpotifyArtist({required this.id, required this.name, this.imageUrl});
}

class SpotifyTrack {
  final String id;
  final String title;
  final String artists;
  final String? album;
  final String? coverUrl;
  final int durationMs;
  final String? url;

  const SpotifyTrack({
    required this.id,
    required this.title,
    required this.artists,
    this.album,
    this.coverUrl,
    this.durationMs = 0,
    this.url,
  });

  String get searchQuery {
    final mainArtist = artists.split(',').first.trim();
    return '$mainArtist $title';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artists': artists,
    'album': album,
    'coverUrl': coverUrl,
    'durationMs': durationMs,
    'url': url,
  };

  factory SpotifyTrack.fromJson(Map<String, dynamic> json) => SpotifyTrack(
    id: json['id'] as String,
    title: json['title'] as String,
    artists: json['artists'] as String,
    album: json['album'] as String?,
    coverUrl: json['coverUrl'] as String?,
    durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
    url: json['url'] as String?,
  );
}

class SpotifyController {
  static const _tokenUrl = 'https://accounts.spotify.com/api/token';
  static const _apiBase = 'https://api.spotify.com/v1';

  static final _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  static String? _clientId;
  static String? _clientSecret;
  static String? _userToken;

  static String? _accessToken;
  static DateTime? _tokenExpiresAt;

  static File? _settingsFile;
  static Timer? _saveDebounce;

  static Future<void> init() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/spotify_settings.json');
      _settingsFile = file;
      if (file.existsSync()) {
        final json =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        _clientId = json['clientId'] as String?;
        _clientSecret = json['clientSecret'] as String?;
        _userToken = json['userToken'] as String?;
        final seed = json['seedArtist'] as String?;
        if (seed != null && seed.trim().isNotEmpty) {
          spotifyWaveSeedArtistSignal.value = seed;
        }
        final provider = json['provider'] as String?;
        if (provider == 'spotify') {
          musicProviderSignal.value = MusicProvider.spotify;
        }
        final liked = (json['liked'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(SpotifyTrack.fromJson)
            .toList();
        spotifyLikedSignal.value = liked;
      }
    } on Object catch (_) {}
    _syncStatusSignals();
  }

  static void _syncStatusSignals() {
    spotifyConfiguredSignal.value =
        (_clientId != null && _clientId!.isNotEmpty) &&
        (_clientSecret != null && _clientSecret!.isNotEmpty);
    spotifyUserConnectedSignal.value =
        _userToken != null && _userToken!.isNotEmpty;
  }

  static void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(_save());
    });
  }

  static Future<void> _save() async {
    try {
      final file = _settingsFile;
      if (file == null) return;
      final json = {
        'clientId': _clientId,
        'clientSecret': _clientSecret,
        'userToken': _userToken,
        'seedArtist': spotifyWaveSeedArtistSignal.value,
        'provider': musicProviderSignal.value == MusicProvider.spotify
            ? 'spotify'
            : 'yandex',
        'liked': spotifyLikedSignal.value.map((t) => t.toJson()).toList(),
      };
      await file.writeAsString(jsonEncode(json));
    } on Object catch (_) {}
  }

  static void setProvider(MusicProvider provider) {
    musicProviderSignal.value = provider;
    _scheduleSave();
  }

  static bool get isConfigured => spotifyConfiguredSignal.value;

  static Future<void> saveCredentials({
    required String clientId,
    required String clientSecret,
    required String userToken,
    required String seedArtist,
  }) async {
    _clientId = clientId.trim();
    _clientSecret = clientSecret.trim();
    _userToken = userToken.trim().isEmpty ? null : userToken.trim();
    if (seedArtist.trim().isNotEmpty) {
      spotifyWaveSeedArtistSignal.value = seedArtist.trim();
    }
    _accessToken = null;
    _tokenExpiresAt = null;
    _syncStatusSignals();
    _scheduleSave();
  }

  static Future<void> _ensureAccessToken() async {
    if (!_spotifyConfigured) {
      throw Exception(
        'Spotify не подключен. Укажите Client ID и Client Secret в настройках.',
      );
    }
    if (_accessToken != null &&
        _tokenExpiresAt != null &&
        DateTime.now().isBefore(_tokenExpiresAt!)) {
      return;
    }
    final body =
        'grant_type=client_credentials'
        '&client_id=${Uri.encodeComponent(_clientId!)}'
        '&client_secret=${Uri.encodeComponent(_clientSecret!)}';
    final request = await _client.postUrl(Uri.parse(_tokenUrl));
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/x-www-form-urlencoded',
    );
    request.write(body);
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw Exception('Ошибка авторизации Spotify (${response.statusCode})');
    }
    final json = jsonDecode(text) as Map<String, dynamic>;
    _accessToken = json['access_token'] as String?;
    final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 3600;
    _tokenExpiresAt = DateTime.now().add(Duration(seconds: expiresIn - 60));
  }

  static bool get _spotifyConfigured =>
      _clientId != null &&
      _clientId!.isNotEmpty &&
      _clientSecret != null &&
      _clientSecret!.isNotEmpty;

  static Future<Map<String, dynamic>> _apiGet(
    String path,
    Map<String, String> query,
  ) async {
    await _ensureAccessToken();
    final uri = Uri.parse('$_apiBase$path').replace(queryParameters: query);
    final request = await _client.getUrl(uri);
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer $_accessToken',
    );
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw Exception('Ошибка Spotify (${response.statusCode})');
    }
    return jsonDecode(text) as Map<String, dynamic>;
  }

  static Future<void> _userApi(String method, String path, String? ids) async {
    final token = _userToken;
    if (token == null || token.isEmpty) return;
    var uri = Uri.parse('$_apiBase$path');
    if (ids != null) {
      uri = uri.replace(queryParameters: {'ids': ids});
    }
    final request = await _client.openUrl(method, uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close();
    await response.drain<void>();
  }

  static SpotifyTrack _parseTrack(Map<String, dynamic> json) {
    final artists = (json['artists'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map((a) => a['name'] as String? ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
    final album = json['album'] as Map<String, dynamic>?;
    String? cover;
    final images = album?['images'] as List<dynamic>?;
    if (images != null && images.isNotEmpty) {
      cover = (images.first as Map<String, dynamic>)['url'] as String?;
    }
    final externalUrls = json['external_urls'] as Map<String, dynamic>?;
    return SpotifyTrack(
      id: json['id'] as String? ?? '',
      title: json['name'] as String? ?? '',
      artists: artists.join(', '),
      album: album?['name'] as String?,
      coverUrl: cover,
      durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
      url: externalUrls?['spotify'] as String?,
    );
  }

  static Future<List<SpotifyTrack>> searchTracks(String query) async {
    final json = await _apiGet('/search', {
      'q': query,
      'type': 'track',
      'limit': '30',
    });
    final tracks =
        ((json['tracks'] as Map<String, dynamic>?)?['items']
            as List<dynamic>? ??
        []);
    return tracks
        .whereType<Map<String, dynamic>>()
        .map(_parseTrack)
        .where((t) => t.id.isNotEmpty)
        .toList();
  }

  static Future<SpotifyArtist?> searchArtist(String name) async {
    final json = await _apiGet('/search', {
      'q': name,
      'type': 'artist',
      'limit': '1',
    });
    final items =
        (json['artists'] as Map<String, dynamic>?)?['items'] as List<dynamic>?;
    if (items == null || items.isEmpty) return null;
    final artist = items.first as Map<String, dynamic>;
    final images = artist['images'] as List<dynamic>?;
    String? image;
    if (images != null && images.isNotEmpty) {
      image = (images.first as Map<String, dynamic>)['url'] as String?;
    }
    return SpotifyArtist(
      id: artist['id'] as String? ?? '',
      name: artist['name'] as String? ?? name,
      imageUrl: image,
    );
  }

  static Future<List<SpotifyTrack>> artistTopTracks(String artistId) async {
    final json = await _apiGet('/artists/$artistId/top-tracks', {});
    final tracks = json['tracks'] as List<dynamic>? ?? [];
    return tracks
        .whereType<Map<String, dynamic>>()
        .map(_parseTrack)
        .where((t) => t.id.isNotEmpty)
        .toList();
  }

  static int _matchScore(SimpleTrackDto candidate, SpotifyTrack track) {
    String normalize(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final candTitle = normalize(candidate.title);
    final spotifyTitle = normalize(track.title);
    final candArtists = candidate.artists.map((a) => normalize(a.name));
    final spotifyMainArtist = normalize(track.artists.split(',').first.trim());

    var score = 0;
    if (candTitle == spotifyTitle) {
      score += 60;
    } else if (candTitle.startsWith(spotifyTitle) ||
        spotifyTitle.startsWith(candTitle)) {
      score += 40;
    } else if (candTitle.contains(spotifyTitle) ||
        spotifyTitle.contains(candTitle)) {
      score += 25;
    } else {
      return 0;
    }
    if (candArtists.any((a) => a == spotifyMainArtist && a.isNotEmpty)) {
      score += 40;
    } else if (candArtists.any(
      (a) => a.isNotEmpty && spotifyMainArtist.contains(a),
    )) {
      score += 20;
    } else {
      score -= 30;
    }
    return score;
  }

  static Future<SimpleTrackDto?> findOnYandex(SpotifyTrack track) async {
    final ctx = appContextSignal.value;
    if (ctx == null) return null;
    try {
      final results = await rust.search(ctx: ctx, query: track.searchQuery);
      SimpleTrackDto? best;
      var bestScore = 0;
      for (final candidate in results.tracks) {
        final score = _matchScore(candidate, track);
        if (score > bestScore) {
          bestScore = score;
          best = candidate;
        }
      }
      if (bestScore >= 40) return best;
      if (bestScore >= 25 && results.tracks.isNotEmpty) return best;
      return null;
    } on Object catch (_) {
      return null;
    }
  }

  static Future<void> playSpotifyTrack(SpotifyTrack track) async {
    final mapped = await findOnYandex(track);
    if (mapped == null) {
      showAppError('«${track.title}» не найден в Яндекс Музыке');
      return;
    }
    await PlaybackController.playTrack(mapped.id);
  }

  static Future<void> startMyWave() async {
    final seedArtistName = spotifyWaveSeedArtistSignal.value;
    try {
      final artist = await searchArtist(seedArtistName);
      if (artist == null) {
        showAppError('Артист «$seedArtistName» не найден в Spotify');
        return;
      }
      final topTracks = await artistTopTracks(artist.id);
      if (topTracks.isEmpty) {
        showAppError('У артиста «${artist.name}» нет треков в Spotify');
        return;
      }
      SimpleTrackDto? mapped;
      for (final seedTrack in topTracks.take(5)) {
        mapped = await findOnYandex(seedTrack);
        if (mapped != null) break;
      }
      if (mapped == null) {
        showAppError(
          'Треки Spotify не найдены в Яндекс Музыке для запуска волны',
        );
        return;
      }
      await PlaybackController.startTrackWave(mapped.id, mapped.title);
      setSection(AppSection.home);
    } on Object catch (e) {
      showAppError('Spotify: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  static bool isLiked(SpotifyTrack track) =>
      spotifyLikedSignal.value.any((t) => t.id == track.id);

  static Future<void> toggleLike(SpotifyTrack track) async {
    final liked = List<SpotifyTrack>.from(spotifyLikedSignal.value);
    final wasLiked = liked.any((t) => t.id == track.id);
    if (wasLiked) {
      liked.removeWhere((t) => t.id == track.id);
    } else {
      liked.insert(0, track);
    }
    spotifyLikedSignal.value = liked;
    _scheduleSave();

    unawaited(() async {
      try {
        if (wasLiked) {
          await _userApi('DELETE', '/me/tracks', track.id);
        } else {
          await _userApi('PUT', '/me/tracks', track.id);
        }
      } on Object catch (_) {}
    }());

    if (wasLiked) return;

    final mapped = await findOnYandex(track);
    if (mapped != null && !mapped.isLiked) {
      try {
        await PlaybackController.toggleLike(trackId: mapped.id);
      } on Object catch (_) {}
    }
  }

  static Future<void> mirrorLikeToSpotify({
    required String title,
    required List<String> artistNames,
  }) async {
    if (!_spotifyConfigured || !spotifyUserConnectedSignal.value) return;
    try {
      final query = '${artistNames.isNotEmpty ? artistNames.first : ''} $title'
          .trim();
      final results = await searchTracks(query);
      if (results.isEmpty) return;
      SpotifyTrack? best;
      var bestScore = 0;
      String normalize(String s) =>
          s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
      for (final candidate in results) {
        var score = 0;
        if (normalize(candidate.title) == normalize(title)) {
          score += 50;
        } else if (normalize(candidate.title).contains(normalize(title))) {
          score += 25;
        }
        if (artistNames.any(
          (a) =>
              normalize(a).isNotEmpty &&
              normalize(candidate.artists).contains(normalize(a)),
        )) {
          score += 40;
        }
        if (score > bestScore) {
          bestScore = score;
          best = candidate;
        }
      }
      if (bestScore < 60 || best == null) return;
      if (isLiked(best)) return;
      final liked = List<SpotifyTrack>.from(spotifyLikedSignal.value);
      liked.insert(0, best);
      spotifyLikedSignal.value = liked;
      _scheduleSave();
      await _userApi('PUT', '/me/tracks', best.id);
    } on Object catch (_) {}
  }
}
