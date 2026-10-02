// Spotify integration for YAYMA.
//
// Spotify does not allow third-party apps to stream its audio, so the
// integration works like this:
//  * login via OAuth (PKCE) in the system browser, redirect to a local server;
//  * likes made inside YAYMA are mirrored to Spotify "Liked Songs";
//  * "My Wave" can be seeded with the user's Spotify top tracks, which are
//    matched to Yandex Music tracks and played from Yandex.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

const int kSpotifyRedirectPort = 43821;
const String kSpotifyRedirectUri =
    'http://127.0.0.1:$kSpotifyRedirectPort/callback';
const String _scopes =
    'user-library-read user-library-modify user-top-read user-read-private';

/// Which services are active in the app.
final FlutterSignal<bool> spotifyConnectedSignal = signal<bool>(false);
final FlutterSignal<String?> spotifyUserNameSignal = signal<String?>(null);
final FlutterSignal<bool> spotifyLikeSyncSignal = signal<bool>(true);
final FlutterSignal<bool> spotifyWaveSignal = signal<bool>(true);
final FlutterSignal<String> spotifyClientIdSignal = signal<String>('');

class SpotifySeedTrack {
  final String title;
  final String artist;
  const SpotifySeedTrack(this.title, this.artist);
}

class SpotifyService {
  static String? _accessToken;
  static String? _refreshToken;
  static DateTime _expiresAt = DateTime.fromMillisecondsSinceEpoch(0);
  static bool _loaded = false;

  // ---------------------------------------------------------------- storage

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}spotify.json');
  }

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (!f.existsSync()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      spotifyClientIdSignal.value = (j['clientId'] as String?) ?? '';
      _accessToken = j['accessToken'] as String?;
      _refreshToken = j['refreshToken'] as String?;
      _expiresAt = DateTime.fromMillisecondsSinceEpoch(
        (j['expiresAt'] as int?) ?? 0,
      );
      spotifyLikeSyncSignal.value = (j['likeSync'] as bool?) ?? true;
      spotifyWaveSignal.value = (j['wave'] as bool?) ?? true;
      spotifyUserNameSignal.value = j['userName'] as String?;
      spotifyConnectedSignal.value = _refreshToken != null;
    } on Object catch (_) {}
  }

  static Future<void> _save() async {
    try {
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(
        jsonEncode({
          'clientId': spotifyClientIdSignal.value,
          'accessToken': _accessToken,
          'refreshToken': _refreshToken,
          'expiresAt': _expiresAt.millisecondsSinceEpoch,
          'likeSync': spotifyLikeSyncSignal.value,
          'wave': spotifyWaveSignal.value,
          'userName': spotifyUserNameSignal.value,
        }),
      );
    } on Object catch (_) {}
  }

  static Future<void> setLikeSync({required bool value}) async {
    spotifyLikeSyncSignal.value = value;
    await _save();
  }

  static Future<void> setWave({required bool value}) async {
    spotifyWaveSignal.value = value;
    await _save();
  }

  static Future<void> logout() async {
    _accessToken = null;
    _refreshToken = null;
    spotifyConnectedSignal.value = false;
    spotifyUserNameSignal.value = null;
    await _save();
  }

  // ------------------------------------------------------------------ auth

  static String _randomString(int len) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(len, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// Opens the browser and waits for the redirect. Returns null on success,
  /// or an error message.
  static Future<String?> login(String clientId) async {
    await load();
    clientId = clientId.trim();
    if (clientId.isEmpty) return 'Укажи Client ID приложения Spotify';
    spotifyClientIdSignal.value = clientId;

    final verifier = _randomString(64);
    final challenge = base64Url
        .encode(sha256.convert(utf8.encode(verifier)).bytes)
        .replaceAll('=', '');
    final state = _randomString(16);

    HttpServer server;
    try {
      server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        kSpotifyRedirectPort,
      );
    } on Object catch (_) {
      return 'Порт $kSpotifyRedirectPort занят';
    }

    final authUri = Uri.https('accounts.spotify.com', '/authorize', {
      'client_id': clientId,
      'response_type': 'code',
      'redirect_uri': kSpotifyRedirectUri,
      'code_challenge_method': 'S256',
      'code_challenge': challenge,
      'scope': _scopes,
      'state': state,
    });

    if (!await launchUrl(authUri, mode: LaunchMode.externalApplication)) {
      await server.close(force: true);
      return 'Не удалось открыть браузер';
    }

    String? code;
    String? error;
    try {
      await for (final req in server.timeout(const Duration(minutes: 5))) {
        if (req.uri.path != '/callback') {
          req.response.statusCode = 404;
          await req.response.close();
          continue;
        }
        final q = req.uri.queryParameters;
        if (q['state'] != state) {
          error = 'Неверный state';
        } else {
          code = q['code'];
          error = q['error'];
        }
        req.response.headers.contentType = ContentType.html;
        req.response.write(
          '<html><meta charset="utf-8"><body style="font-family:sans-serif;'
          'background:#111;color:#eee;text-align:center;padding-top:20vh">'
          '<h2>${code != null ? 'Spotify подключён ✅' : 'Ошибка входа'}</h2>'
          '<p>Можно вернуться в YAYMA.</p></body></html>',
        );
        await req.response.close();
        break;
      }
    } on TimeoutException {
      error = 'Время ожидания вышло';
    } finally {
      await server.close(force: true);
    }

    if (code == null) return error ?? 'Вход отменён';

    final ok = await _tokenRequest({
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': kSpotifyRedirectUri,
      'client_id': clientId,
      'code_verifier': verifier,
    });
    if (!ok) return 'Spotify не выдал токен';

    final me = await _api('GET', '/me');
    if (me is Map<String, dynamic>) {
      spotifyUserNameSignal.value =
          (me['display_name'] as String?) ?? (me['id'] as String?);
    }
    spotifyConnectedSignal.value = true;
    await _save();
    return null;
  }

  static Future<bool> _tokenRequest(Map<String, String> body) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(
        Uri.parse('https://accounts.spotify.com/api/token'),
      );
      req.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );
      req.write(Uri(queryParameters: body).query);
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return false;
      final j = jsonDecode(text) as Map<String, dynamic>;
      _accessToken = j['access_token'] as String?;
      _refreshToken = (j['refresh_token'] as String?) ?? _refreshToken;
      _expiresAt = DateTime.now().add(
        Duration(seconds: ((j['expires_in'] as int?) ?? 3600) - 60),
      );
      await _save();
      return _accessToken != null;
    } on Object catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  static Future<bool> _ensureToken() async {
    await load();
    if (_refreshToken == null) return false;
    if (_accessToken != null && DateTime.now().isBefore(_expiresAt)) {
      return true;
    }
    return _tokenRequest({
      'grant_type': 'refresh_token',
      'refresh_token': _refreshToken!,
      'client_id': spotifyClientIdSignal.value,
    });
  }

  // ------------------------------------------------------------------- api

  static Future<dynamic> _api(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    if (!await _ensureToken()) return null;
    final client = HttpClient();
    try {
      final uri = Uri.https('api.spotify.com', '/v1$path', query);
      final req = await client.openUrl(method, uri);
      req.headers.set('Authorization', 'Bearer $_accessToken');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      } else if (method != 'GET') {
        req.headers.contentLength = 0;
      }
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401) {
        _accessToken = null;
        return null;
      }
      if (res.statusCode >= 300 || text.isEmpty) return null;
      return jsonDecode(text);
    } on Object catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  static String _clean(String s) => s
      .replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), '')
      .replaceAll(RegExp('[\'"]'), '')
      .trim();

  /// Finds the Spotify track id for a "title + artist" pair.
  static Future<String?> findTrack(String title, String artist) async {
    final q = 'track:${_clean(title)} artist:${_clean(artist)}';
    var res = await _api(
      'GET',
      '/search',
      query: {'q': q, 'type': 'track', 'limit': '1'},
    );
    var items = (res?['tracks']?['items'] as List?) ?? const [];
    if (items.isEmpty) {
      res = await _api(
        'GET',
        '/search',
        query: {'q': '$artist $title', 'type': 'track', 'limit': '1'},
      );
      items = (res?['tracks']?['items'] as List?) ?? const [];
    }
    if (items.isEmpty) return null;
    return (items.first as Map<String, dynamic>)['id'] as String?;
  }

  /// Mirrors a like / unlike made in YAYMA to Spotify "Liked Songs".
  static Future<void> mirrorLike({
    required String title,
    required String artist,
    required bool liked,
  }) async {
    await load();
    if (!spotifyConnectedSignal.value || !spotifyLikeSyncSignal.value) return;
    final id = await findTrack(title, artist);
    if (id == null) return;
    await _api(liked ? 'PUT' : 'DELETE', '/me/tracks', query: {'ids': id});
  }

  /// Top + recently liked Spotify tracks, used as seeds for "My Wave".
  static Future<List<SpotifySeedTrack>> seedTracks({int count = 3}) async {
    await load();
    if (!spotifyConnectedSignal.value || !spotifyWaveSignal.value) return [];
    final out = <SpotifySeedTrack>[];
    for (final path in ['/me/top/tracks', '/me/tracks']) {
      final res = await _api(
        'GET',
        path,
        query: {
          'limit': '20',
          if (path.contains('top')) 'time_range': 'short_term',
        },
      );
      for (final raw in (res?['items'] as List?) ?? const []) {
        final t = (raw is Map && raw['track'] != null) ? raw['track'] : raw;
        if (t is! Map) continue;
        final artists = (t['artists'] as List?) ?? const [];
        if (artists.isEmpty) continue;
        out.add(
          SpotifySeedTrack(
            t['name'] as String,
            (artists.first as Map)['name'] as String,
          ),
        );
      }
    }
    out.shuffle();
    return out.take(count).toList();
  }
}
