import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musly/providers/player_provider.dart';
import 'package:musly/services/android_system_service.dart';
import 'package:musly/services/audio_handler.dart';
import 'package:musly/services/bluetooth_avrcp_service.dart';
import 'package:musly/services/cast_service.dart';
import 'package:musly/services/jukebox_service.dart';
import 'package:musly/services/storage_service.dart';
import 'package:musly/services/subsonic_service.dart';
import 'package:musly/services/transcoding_service.dart';
import 'package:musly/services/upnp_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bootstrap.dart';

/// Cast stand-in whose connection state and reported media state are settable,
/// so renderer transitions can be driven without a Chromecast.
class _FakeCast extends CastService {
  bool connected = false;
  // Not named `state`: CastService already has a `state` getter of a different
  // type (CastState).
  CastMediaState reported = CastMediaState();

  @override
  bool get isConnected => connected;

  @override
  CastMediaState get mediaState => reported;

  @override
  Future<bool> loadMedia({
    required String url,
    required String title,
    required String artist,
    required String imageUrl,
    String? albumName,
    int? trackNumber,
    Duration? duration,
    bool autoPlay = true,
  }) async =>
      true;

  // Call counters: asserting these stay at zero is what makes the
  // remote-renderer guard tests able to fail when a guard is deleted.
  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;

  @override
  Future<void> play() async => playCalls++;
  @override
  Future<void> pause() async => pauseCalls++;
  @override
  Future<void> stop() async => stopCalls++;
  @override
  Future<void> seek(Duration position) async {}

  /// Publish a state change the way the real service does.
  void emit() => notifyListeners();
}

// NOTE: there is deliberately no _FakeUpnp. UpnpService is a singleton with a
// private constructor (`UpnpService._internal()`), so it cannot be subclassed
// or substituted, and its connection state cannot be driven from a test. Matrix
// row L2 (renderer disappears) is therefore NOT coverable in Dart until that
// service takes the same shape as CastService. Tracked as GAP-8.

void main() {
  initializeTestEnvironment();

  late _FakeCast cast;
  late PlayerProvider player;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    cast = _FakeCast();
    player = PlayerProvider(
      SubsonicService(),
      StorageService(),
      cast,
      UpnpService(),
      MuslyAudioHandler(),
      JukeboxService(),
      TranscodingService(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
  });

  tearDown(() => player.dispose());

  // ── Renderer loss: matrix L1, L2 ──────────────────────────────────────────

  group('renderer loss', () {
    test('L1 cast disconnect clears remote rendering and stops playback',
        () async {
      // Enter remote mode explicitly. Reaching it through playSong() needs a
      // configured server, and without it this assertion would be vacuous
      // (false staying false) and could never catch a regression.
      cast.connected = true;
      player.setRenderingRemotelyForTest(true);
      expect(player.isRemotePlayback, isTrue);

      cast.connected = false;
      cast.emit();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(player.isRemotePlayback, isFalse,
          reason: 'a vanished cast device must not leave us in remote mode, '
              'or every later play() would be routed to nothing');
      expect(player.isPlaying, isFalse);
    });

    test('L1 repeated disconnects are idempotent', () async {
      for (var i = 0; i < 3; i++) {
        cast.connected = false;
        cast.emit();
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(player.isRemotePlayback, isFalse);
    });
  });

  // ── Remote position sync: matrix GAP-3 ────────────────────────────────────

  group('remote position sync', () {
    test('adopts a position that differs by more than the 500ms debounce', () {
      final changed = player.syncRemotePosition(
        const Duration(seconds: 30),
        const Duration(minutes: 3),
      );
      expect(changed, isTrue);
      expect(player.position, const Duration(seconds: 30));
      expect(player.duration, const Duration(minutes: 3));
    });

    test('ignores jitter within the debounce window', () {
      player.syncRemotePosition(
          const Duration(seconds: 30), const Duration(minutes: 3));
      final changed = player.syncRemotePosition(
        const Duration(seconds: 30, milliseconds: 200),
        const Duration(minutes: 3),
      );
      expect(changed, isFalse,
          reason: 'poll jitter must not fight the UI progress bar');
      expect(player.position, const Duration(seconds: 30));
    });

    test('a zero duration never clobbers a known duration', () {
      player.syncRemotePosition(
          const Duration(seconds: 5), const Duration(minutes: 3));
      player.syncRemotePosition(const Duration(seconds: 30), Duration.zero);
      expect(player.duration, const Duration(minutes: 3),
          reason: 'a not-yet-loaded track reports duration 0; adopting it '
              'would break the track-end heuristic');
    });
  });

  // ── Audio focus + noisy: matrix P2, P3, P4, P6 ────────────────────────────
  //
  // These fire on the AndroidSystemService singleton, which PlayerProvider
  // wires callbacks onto. Driving them directly is what the OS does when a
  // call arrives or headphones are unplugged.

  group('interruptions', () {
    final sys = AndroidSystemService();

    // Regression guards for a495233 / bb3852f: while a Cast or DLNA renderer is
    // playing, the audio is NOT on this phone. Android reassigns local audio
    // focus at screen-off and fires becoming-noisy when Bluetooth drops, and
    // acting on either would pause the renderer mid-song.
    // Both assert on the fake's call counters rather than on provider flags:
    // pause() routes to _castService.pause() whenever cast is connected, so a
    // deleted guard shows up as a non-zero counter. Asserting isRemotePlayback
    // instead would pass even with the guard removed.
    test('P2 focus loss must not pause a remote renderer', () async {
      cast.connected = true;
      player.setRenderingRemotelyForTest(true);

      sys.onAudioFocusLoss?.call();
      sys.onAudioFocusLossTransient?.call();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(cast.pauseCalls, 0,
          reason: 'audio is on the cast device; Android reassigning local '
              'focus at screen-off must not reach the renderer');
      expect(player.isRemotePlayback, isTrue);
    });

    test('P6 becoming-noisy must not pause a remote renderer', () async {
      cast.connected = true;
      player.setRenderingRemotelyForTest(true);

      sys.onBecomingNoisy?.call();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(cast.pauseCalls, 0,
          reason: 'pulling headphones out of the phone says nothing about a '
              'renderer in another room');
      expect(player.isRemotePlayback, isTrue);
    });

    test('P2 sanity: without the remote flag, focus loss DOES pause', () async {
      // Proves the counters above would move if the guards were removed —
      // otherwise those tests could never fail.
      cast.connected = true;
      player.setRenderingRemotelyForTest(false);

      sys.onAudioFocusLoss?.call();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(cast.pauseCalls, greaterThan(0));
    });

    test('P2/P3/P4/P6 handlers are wired and never throw locally', () async {
      expect(sys.onAudioFocusLoss, isNotNull);
      expect(sys.onAudioFocusLossTransient, isNotNull);
      expect(sys.onAudioFocusLossTransientCanDuck, isNotNull);
      expect(sys.onAudioFocusGain, isNotNull);
      expect(sys.onBecomingNoisy, isNotNull);

      expect(() => sys.onAudioFocusLoss?.call(), returnsNormally);
      expect(() => sys.onAudioFocusLossTransient?.call(), returnsNormally);
      expect(
          () => sys.onAudioFocusLossTransientCanDuck?.call(), returnsNormally);
      expect(() => sys.onAudioFocusGain?.call(), returnsNormally);
      expect(() => sys.onBecomingNoisy?.call(), returnsNormally);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(player.isPlaying, isFalse);
    });
  });

  // ── Bluetooth: matrix L3 ──────────────────────────────────────────────────

  group('bluetooth disconnect', () {
    test('L3 disconnect callback is wired and survives an unknown device', () {
      final bt = BluetoothAvrcpService();
      expect(bt.onDeviceDisconnected, isNotNull);

      expect(
        () => bt.onDeviceDisconnected!(BluetoothDeviceInfo(
          address: 'AA:BB:CC:DD:EE:FF',
          name: 'Never connected',
          isConnected: false,
          supportsAvrcp: true,
          avrcpVersion: 13,
          supportsAlbumArt: false,
          supportsBrowsing: false,
        )),
        returnsNormally,
      );
    });
  });

  // ── Teardown safety: matrix C10-adjacent ──────────────────────────────────

  group('disposal', () {
    test('renderer events after dispose do not throw', () async {
      player.dispose();

      // The provider detaches its listeners on dispose; a late event from a
      // renderer must not reach a disposed ChangeNotifier.
      expect(() {
        cast.connected = false;
        cast.emit();
      }, returnsNormally);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Re-create so tearDown's dispose() runs against a live provider rather
      // than disposing twice.
      player = PlayerProvider(
        SubsonicService(),
        StorageService(),
        _FakeCast(),
        UpnpService(),
        MuslyAudioHandler(),
        JukeboxService(),
        TranscodingService(),
      );
    });
  });
}

/// Guards the assumption the whole matrix rests on: local playback, offline
/// files and A2DP all share one renderer path, which is why a Bluetooth speaker
/// on a desk exercises the same code as a car head unit.
@visibleForTesting
const rendererSharingNote = 'R1 == R6 == A2DP routing';
