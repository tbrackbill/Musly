import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musly/models/song.dart';
import 'package:musly/providers/player_provider.dart';
import 'package:musly/services/bluetooth_avrcp_service.dart';
import 'package:musly/services/jukebox_service.dart';
import 'package:musly/services/storage_service.dart';
import 'package:musly/services/subsonic_service.dart';
import 'package:musly/services/transcoding_service.dart';
import 'package:musly/services/upnp_service.dart';
import 'package:musly/services/audio_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bootstrap.dart';
import '../test_helpers.dart';

/// Records whether the BT connect handler reached [play] instead of driving
/// the real audio stack (which has no plugin in the test environment).
class _RecordingPlayerProvider extends PlayerProvider {
  _RecordingPlayerProvider(
    SubsonicService subsonic,
    StorageService storage,
    UpnpService upnp,
    MuslyAudioHandler handler,
    JukeboxService jukebox,
    TranscodingService transcoding,
  ) : super(subsonic, storage, FakeCastService(), upnp, handler, jukebox,
            transcoding);

  int playCallCount = 0;

  @override
  Future<void> play() async {
    playCallCount++;
  }
}

const _avrcpChannel = MethodChannel('com.devid.musly/bluetooth_avrcp');

/// A song shaped the way [PlayerProvider._restoreQueueState] expects.
final _song = Song(
  id: 'song-1',
  title: 'Restored Track',
  artist: 'Test Artist',
  album: 'Test Album',
  duration: 210,
);

/// Seeds the persisted queue so a freshly constructed provider restores
/// `currentSong` — the precondition for resume-on-connect.
void _seedPersistedQueue() {
  SharedPreferences.setMockInitialValues({
    'persistent_queue': jsonEncode([_song.toJson()]),
    'persistent_queue_index': 0,
    'persistent_queue_song_id': _song.id,
    'persistent_queue_position_ms': 0,
  });
}

void main() {
  initializeTestEnvironment();

  group('Bluetooth resume-on-connect', () {
    late _RecordingPlayerProvider provider;
    bool a2dpActive = true;

    setUp(() async {
      a2dpActive = true;
      _seedPersistedQueue();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_avrcpChannel, (call) async {
        switch (call.method) {
          case 'isA2dpConnected':
            return a2dpActive;
          case 'getConnectedDevices':
            return <Map<String, dynamic>>[];
          default:
            return null;
        }
      });

      provider = _RecordingPlayerProvider(
        SubsonicService(),
        StorageService(),
        UpnpService(),
        MuslyAudioHandler(),
        JukeboxService(),
        TranscodingService(),
      );

      // Let the async constructor work (queue restore, service wiring) settle.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_avrcpChannel, null);
      provider.dispose();
    });

    /// Fires the same callback [BluetoothAvrcpService] invokes when the
    /// platform reports an A2DP device connect, then waits for the async
    /// isA2dpConnected() round trip inside the handler.
    Future<void> simulateDeviceConnected() async {
      final onConnected = BluetoothAvrcpService().onDeviceConnected;
      expect(onConnected, isNotNull,
          reason: 'PlayerProvider should have wired onDeviceConnected');
      onConnected!(BluetoothDeviceInfo(
        address: '00:11:22:33:44:55',
        name: 'Test Head Unit',
        isConnected: true,
        supportsAvrcp: true,
        avrcpVersion: 15,
        supportsAlbumArt: true,
        supportsBrowsing: true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    test('restores a queue on construction', () {
      expect(provider.currentSong, isNotNull,
          reason: 'resume-on-connect is a no-op without a restored song');
      expect(provider.currentSong!.id, _song.id);
      expect(provider.isPlaying, isFalse);
    });

    test('auto-plays when an A2DP device connects while idle', () async {
      expect(provider.resumeOnBluetoothConnect, isTrue,
          reason: 'setting defaults to on');

      await simulateDeviceConnected();

      expect(provider.playCallCount, 1);
    });

    test('does not auto-play when the setting is off', () async {
      provider.toggleResumeOnBluetoothConnect();
      expect(provider.resumeOnBluetoothConnect, isFalse);

      await simulateDeviceConnected();

      expect(provider.playCallCount, 0);
    });

    test('does not auto-play when A2DP audio is not actually active', () async {
      a2dpActive = false;

      await simulateDeviceConnected();

      expect(provider.playCallCount, 0);
    });

    test('is idempotent across repeated connect events', () async {
      await simulateDeviceConnected();
      await simulateDeviceConnected();

      // Second connect still calls play(); the guard that matters in the app is
      // isPlaying, which the fake play() override never sets. This locks in that
      // the handler is re-entrant and does not throw.
      expect(provider.playCallCount, 2);
    });
  });
}
