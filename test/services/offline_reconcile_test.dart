import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:musly/models/playlist.dart';
import 'package:musly/models/server_config.dart';
import 'package:musly/models/song.dart';
import 'package:musly/providers/auth_provider.dart';
import 'package:musly/services/offline_service.dart';
import 'package:musly/services/storage_service.dart';
import 'package:musly/services/subsonic_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bootstrap.dart';

/// _processQueue drops a playlist's track manifest the moment it completes,
/// and resumeIncompleteDownloads only walks playlists still in the queue. So a
/// finished playlist was never looked at again: add a track to a playlist you
/// had already downloaded and that track never downloaded, while
/// downloadedPlaylistIds went on reporting the playlist as complete.
class _FakeSubsonic extends SubsonicService {
  _FakeSubsonic(this.playlists);

  final Map<String, Playlist> playlists;
  final List<String> requested = [];

  /// Whether the service had a server configured at each request.
  final List<bool> configuredAtRequest = [];

  /// Runs while the request is "in flight", so a test can mutate service state
  /// the way a user action would during a slow server call.
  Future<void> Function(String id)? onRequest;

  @override
  Future<PingResult> pingWithError() async => PingResult(success: true);

  @override
  Future<Playlist> getPlaylist(String id) async {
    requested.add(id);
    configuredAtRequest.add(isConfigured);
    await onRequest?.call(id);
    final p = playlists[id];
    if (p == null) throw Exception('no such playlist $id');
    return p;
  }
}

Song _song(String id) => Song(id: id, title: 'Title $id');

Playlist _playlist(String id, List<String> songIds) => Playlist(
      id: id,
      name: 'Playlist $id',
      songs: songIds.map(_song).toList(),
    );

ServerConfig _server(String url) =>
    ServerConfig(serverUrl: url, username: 'user', password: 'secret');

/// A fake already pointed at a server, as it is once a connection is verified.
Future<_FakeSubsonic> _connected(Map<String, Playlist> playlists,
    {String url = 'http://a.invalid'}) async {
  final svc = _FakeSubsonic(playlists);
  await svc.configure(_server(url));
  return svc;
}

void main() {
  initializeTestEnvironment();

  late OfflineService offline;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // OfflineService is a singleton, so state has to be reset explicitly
    // rather than by constructing a fresh instance. Resetting only the
    // ValueNotifiers is not enough: initialize() rebuilds _queuedPlaylistData
    // from prefs only when the key is present, so an in-memory download queue
    // survives an apparently clean setUp.
    offline = OfflineService();
    offline.resetForTests();
    // initialize() repopulates the notifiers from prefs and from the offline
    // directory, so it has to run before the per-test state below rather than
    // lazily inside the reconcile.
    await offline.initialize();
    offline.resetForTests();
  });

  tearDown(() {
    // A playlist found to be missing tracks enqueues a real download, which
    // keeps running after the test returns. Clear it so it cannot bleed into
    // the next test.
    offline.resetForTests();
  });

  tearDownAll(() {
    // bootstrap.dart mocks path_provider to '.', so initialize() creates an
    // offline_music directory in the working tree. Do not leave it behind.
    final dir = Directory('./offline_music');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('a playlist whose tracks are all present is left alone', () async {
    offline.downloadedPlaylistIds.value = {'p1'};
    offline.downloadedSongIds.value = {'a', 'b'};
    final svc = await _connected({
      'p1': _playlist('p1', ['a', 'b'])
    });

    final requeued = await offline.reconcileDownloadedPlaylists(svc);

    expect(requeued, isEmpty);
    expect(offline.downloadedPlaylistIds.value, contains('p1'),
        reason: 'a complete playlist must stay marked complete');
  });

  test('a track added server-side is detected and re-queued', () async {
    offline.downloadedPlaylistIds.value = {'p1'};
    offline.downloadedSongIds.value = {'a', 'b'};
    // 'c' was added to the playlist after it finished downloading.
    final svc = await _connected({
      'p1': _playlist('p1', ['a', 'b', 'c'])
    });

    final requeued = await offline.reconcileDownloadedPlaylists(svc);

    expect(requeued, {'p1'});
    expect(offline.downloadedPlaylistIds.value, isNot(contains('p1')),
        reason: 'it is no longer complete, so it must stop claiming to be');
  });

  test('an empty server response does not discard downloads', () async {
    offline.downloadedPlaylistIds.value = {'p1'};
    offline.downloadedSongIds.value = {'a'};
    final svc = await _connected({'p1': _playlist('p1', const [])});

    final requeued = await offline.reconcileDownloadedPlaylists(svc);

    // An empty result is far likelier to be a transport hiccup than a playlist
    // that lost every track, and acting on it would delete the user's music.
    expect(requeued, isEmpty);
    expect(offline.downloadedPlaylistIds.value, contains('p1'));
  });

  test('nothing is requested while offline', () async {
    offline.downloadedPlaylistIds.value = {'p1'};
    offline.setOfflineMode(true);
    final svc = await _connected({
      'p1': _playlist('p1', ['a'])
    });

    final requeued = await offline.reconcileDownloadedPlaylists(svc);

    expect(requeued, isEmpty);
    expect(svc.requested, isEmpty,
        reason: 'reconciling offline would just pile up failed requests');
  });

  test('one unreachable playlist does not stop the others', () async {
    offline.downloadedPlaylistIds.value = {'missing', 'p2'};
    offline.downloadedSongIds.value = {'a'};
    final svc = await _connected({
      'p2': _playlist('p2', ['a', 'b'])
    });

    final requeued = await offline.reconcileDownloadedPlaylists(svc);

    expect(requeued, {'p2'});
    expect(svc.requested, containsAll(<String>['missing', 'p2']));
  });

  test('a playlist cancelled mid-check is not resurrected', () async {
    offline.downloadedPlaylistIds.value = {'p1'};
    offline.downloadedSongIds.value = {'a'};

    // getPlaylist can sit for the full connect+receive timeout. Simulate the
    // user tapping "remove download" during that window.
    final svc = await _connected({
      'p1': _playlist('p1', ['a', 'b'])
    });
    svc.onRequest = (_) async => offline.cancelPlaylistDownload('p1');

    final requeued = await offline.reconcileDownloadedPlaylists(svc);

    expect(requeued, isEmpty,
        reason: 'reconcile must not undo an explicit user cancel');
    expect(offline.queuedPlaylistIds.value, isNot(contains('p1')));
  });

  test('every downloaded playlist is checked, not just the first', () async {
    offline.downloadedPlaylistIds.value = {'p1', 'p2', 'p3'};
    offline.downloadedSongIds.value = {'a'};
    final svc = await _connected({
      'p1': _playlist('p1', ['a']),
      'p2': _playlist('p2', ['a']),
      'p3': _playlist('p3', ['a']),
    });

    await offline.reconcileDownloadedPlaylists(svc);

    expect(svc.requested.toSet(), {'p1', 'p2', 'p3'});
  });

  group('across servers', () {
    test('a playlist downloaded from another server is not looked up',
        () async {
      offline.downloadedSongIds.value = {'a'};
      // Every track is already on disk, so this records the owner and marks
      // the playlist downloaded without starting a real download.
      final a = await _connected({
        'p1': _playlist('p1', ['a'])
      });
      await offline.queuePlaylistDownload('p1', [_song('a')], a);
      expect(offline.downloadedPlaylistIds.value, contains('p1'));

      // Playlist ids are only unique per server. After a profile switch, a
      // colliding id on the new server is an unrelated playlist.
      final b = await _connected({
        'p1': _playlist('p1', ['x', 'y'])
      }, url: 'http://b.invalid');
      final requeued = await offline.reconcileDownloadedPlaylists(b);

      expect(b.requested, isEmpty);
      expect(requeued, isEmpty);
      expect(offline.downloadedPlaylistIds.value, contains('p1'));
    });

    test('a pre-existing download is not claimed by an unrelated playlist',
        () async {
      // Downloaded before owners were recorded, so there is no owner to check.
      offline.downloadedPlaylistIds.value = {'p1'};
      offline.downloadedSongIds.value = {'a', 'b'};
      final svc = await _connected({
        'p1': _playlist('p1', ['x', 'y'])
      });

      final requeued = await offline.reconcileDownloadedPlaylists(svc);

      expect(requeued, isEmpty,
          reason: 'a playlist sharing no track with the download is not it');
      expect(offline.downloadedPlaylistIds.value, contains('p1'));
    });

    test('a profile switch mid-check stops the pass', () async {
      offline.downloadedPlaylistIds.value = {'p1', 'p2'};
      offline.downloadedSongIds.value = {'a'};
      final svc = await _connected({
        'p1': _playlist('p1', ['a', 'b']),
        'p2': _playlist('p2', ['a', 'b']),
      });
      // The service is shared, so switching profiles repoints it mid-pass.
      svc.onRequest = (_) => svc.configure(_server('http://b.invalid'));

      final requeued = await offline.reconcileDownloadedPlaylists(svc);

      expect(requeued, isEmpty);
      expect(svc.requested, hasLength(1));
    });
  });

  test('a call during a running pass joins it', () async {
    offline.downloadedPlaylistIds.value = {'p1'};
    offline.downloadedSongIds.value = {'a'};
    final svc = await _connected({
      'p1': _playlist('p1', ['a', 'b'])
    });

    // Retrying the connection while a reconcile is still running would
    // otherwise queue the same playlist twice.
    final results = await Future.wait([
      offline.reconcileDownloadedPlaylists(svc),
      offline.reconcileDownloadedPlaylists(svc),
    ]);

    expect(svc.requested, ['p1']);
    expect(results, [
      {'p1'},
      {'p1'}
    ]);
  });

  test('app start reconciles once the server connection is verified', () async {
    // Run from PlayerProvider's startup, the reconcile fired before
    // AuthProvider had configured the service, so every request failed with
    // "Server not configured" and nothing was ever re-queued. Observed on
    // device; the other tests here cannot see it because they call the
    // reconcile directly.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('offline_downloaded_playlists', ['p1']);
    await StorageService().saveServerConfig(ServerConfig(
      serverUrl: 'http://music.invalid',
      username: 'user',
      password: 'secret',
    ));
    final svc = _FakeSubsonic({'p1': _playlist('p1', const [])});

    final auth = AuthProvider(svc, StorageService());
    addTearDown(auth.dispose);
    for (var i = 0; i < 100 && svc.requested.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(auth.state, AuthState.authenticated);
    expect(svc.requested, ['p1']);
    expect(svc.configuredAtRequest, [true]);
  });
}
