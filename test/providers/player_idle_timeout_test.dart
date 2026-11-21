import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:musly/models/song.dart';
import 'package:musly/providers/player_provider.dart';
import 'package:musly/services/audio_handler.dart';
import 'package:musly/services/jukebox_service.dart';
import 'package:musly/services/storage_service.dart';
import 'package:musly/services/subsonic_service.dart';
import 'package:musly/services/transcoding_service.dart';
import 'package:musly/services/upnp_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bootstrap.dart';
import '../fake_just_audio_platform.dart';
import '../fake_upnp_renderer.dart';
import '../test_helpers.dart';

/// Once playback has been stopped for the idle period, the Android wake lock
/// is released and nothing keeps a DLNA poll alive in the background. The
/// provider stops polling at that point but stays on the renderer, so the
/// session stays remote: the next play resumes on the speaker, and the system
/// volume slider still drives the speaker. Hardware volume keys are not
/// covered here; Android only routes them to a session that is playing.
void main() {
  initializeTestEnvironment();

  late FakeJustAudioPlatform audio;
  late FakeUpnpRenderer renderer;
  late UpnpService upnp;
  late MuslyAudioHandler handler;
  late PlayerProvider player;

  setUp(() async {
    HttpOverrides.global = null;
    audio = FakeJustAudioPlatform();
    JustAudioPlatform.instance = audio;
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
    // As in player_media_button_cold_start_test: dispose() does not wait for
    // its stop, and just_audio 0.9.46 then completes a future with itself.
    await handler.player.stop();
    await pumpEventQueue();
    player.dispose();
    await renderer.close();
  });

  Song song(String id) => Song(
        id: id,
        title: 'Title $id',
        artist: 'Artist $id',
        path: '/tmp/$id.mp3',
        isLocal: true,
        duration: 180,
      );

  Future<void> until(bool Function() done, String what) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(done(), isTrue, reason: what);
  }

  int polls() => renderer.actions.where((a) => a == 'GetTransportInfo').length;

  /// Casting song a, paused 42 s in, with the provider caught up on that.
  Future<void> pausedOnRenderer() async {
    player.queue.add(song('a'));
    await player.adoptTrackAt(0);
    expect(await upnp.connect(renderer.device), isTrue);
    await until(() => renderer.actions.contains('Play'), 'song a cast');
    await player.pause();
    renderer.position = 42;
    await until(() => player.position == const Duration(seconds: 42),
        'a poll has reported the paused position');
  }

  test('the idle timeout keeps the renderer and stops polling', () async {
    await pausedOnRenderer();

    await handler.onIdleTimeout!();
    renderer.actions.clear();
    await Future<void>.delayed(const Duration(milliseconds: 2500));

    expect(upnp.isConnected, isTrue);
    expect(player.isRemotePlayback, isTrue,
        reason: 'the media session stays remote, so the system volume '
            'slider still drives the speaker');
    expect(renderer.actions, isNot(contains('Stop')));
    expect(polls(), 0, reason: 'nothing may poll once the wake lock is gone');
    expect(renderer.transportState, 'PAUSED_PLAYBACK');
  });

  test('play after the idle timeout resumes a renderer still paused', () async {
    await pausedOnRenderer();
    await handler.onIdleTimeout!();
    renderer.actions.clear();

    await player.play();

    expect(upnp.isConnected, isTrue);
    expect(player.isPlaying, isTrue);
    expect(renderer.transportState, 'PLAYING');
    expect(renderer.actions, contains('Play'));
    expect(renderer.actions, isNot(contains('SetAVTransportURI')),
        reason: 'the renderer still had our track; reloading it would '
            'restart the stream');
    final before = polls();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(polls(), greaterThan(before), reason: 'polling resumes on play');
  });

  test('play after the idle timeout reloads a renderer that dropped the track',
      () async {
    await pausedOnRenderer();
    await handler.onIdleTimeout!();
    // A speaker going into standby, or another app taking it over.
    renderer.transportState = 'STOPPED';
    renderer.position = 0;
    renderer.actions.clear();

    await player.play();
    await until(() => renderer.actions.contains('Seek'), 'a seek');

    expect(upnp.isConnected, isTrue);
    expect(player.isPlaying, isTrue);
    expect(renderer.actions,
        containsAllInOrder(['SetAVTransportURI', 'Play', 'Seek']));
    expect(renderer.trackUri, contains('/tmp/a.mp3'));
    expect(renderer.lastRequest['Seek'], contains('00:00:42'),
        reason: 'the song resumes where it was paused, not from the start');
  });

  test('play after the idle timeout stays paused when the renderer is gone',
      () async {
    await pausedOnRenderer();
    await handler.onIdleTimeout!();
    await renderer.close();

    await player.play();
    await pumpEventQueue();

    expect(upnp.isConnected, isFalse);
    expect(player.isRemotePlayback, isFalse);
    expect(player.isPlaying, isFalse,
        reason: 'a press meant for the speaker must not start the phone');
    expect(handler.playbackState.value.playing, isFalse);
    expect(audio.players.any((p) => p.playing), isFalse);
  });

  test('the volume slider reaches the renderer after the idle timeout',
      () async {
    await pausedOnRenderer();
    await handler.onIdleTimeout!();

    handler.onSetRemoteVolume!(40);
    await until(() => renderer.setVolumes.contains(40), 'SetVolume 40');
    expect(renderer.volume, 40);
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

    upnp.disconnect();
    await pumpEventQueue();
    expect(player.localSourceStale, isTrue,
        reason: 'disconnecting does not make the old local source current');
  });
}
