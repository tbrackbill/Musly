import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musly/providers/player_provider.dart';
import 'package:musly/services/audio_handler.dart';
import 'package:musly/services/jukebox_service.dart';
import 'package:musly/services/storage_service.dart';
import 'package:musly/services/subsonic_service.dart';
import 'package:musly/services/transcoding_service.dart';
import 'package:musly/services/upnp_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bootstrap.dart';
import '../fake_upnp_renderer.dart';
import '../test_helpers.dart';

/// Once playback has been stopped long enough for the Android service to be
/// released, nothing keeps a DLNA poll alive in the background. The provider
/// drops the renderer at that point, and the next play is local, so it must
/// start from the song and position the renderer left off at, not from
/// whatever the local player held before casting began.
void main() {
  initializeTestEnvironment();

  late FakeUpnpRenderer renderer;
  late UpnpService upnp;
  late MuslyAudioHandler handler;
  late PlayerProvider player;

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    renderer = FakeUpnpRenderer();
    await renderer.start();
    upnp = UpnpService();
    handler = MuslyAudioHandler();
    player = PlayerProvider(
      SubsonicService(),
      StorageService(),
      FakeCastService(),
      upnp,
      handler,
      JukeboxService(),
      TranscodingService(),
    );
  });

  tearDown(() async {
    upnp.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    player.dispose();
    await renderer.close();
  });

  test('the idle timeout drops a connected renderer', () async {
    expect(await upnp.connect(renderer.device), isTrue);
    await pumpEventQueue();
    expect(player.isRemotePlayback, isTrue);

    await handler.onIdleTimeout!();

    expect(upnp.isConnected, isFalse);
    expect(player.isRemotePlayback, isFalse);
  });

  test('the idle timeout leaves local playback alone', () async {
    await handler.onIdleTimeout!();
    expect(upnp.isConnected, isFalse);
    expect(player.localSourceStale, isFalse);
  });

  test('after a renderer, the next local play reloads the current song',
      () async {
    expect(player.localSourceStale, isFalse);
    expect(await upnp.connect(renderer.device), isTrue);
    await pumpEventQueue();
    expect(player.localSourceStale, isTrue,
        reason: 'the local player stops following the queue once remote');

    await handler.onIdleTimeout!();
    await pumpEventQueue();
    expect(player.localSourceStale, isTrue,
        reason: 'disconnecting does not make the old local source current');
  });
}
