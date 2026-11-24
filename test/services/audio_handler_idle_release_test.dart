import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:musly/services/audio_handler.dart';

import '../bootstrap.dart';

/// audio_service takes a partial wake lock on every play and, with Musly's
/// configuration, keeps it through a pause. On a device where Musly's battery
/// use is unrestricted, that kept the CPU awake for as long as the app stayed
/// paused. The handler now releases it five minutes into a pause. These pin
/// when it does and when it must not.
///
/// The playing state is driven through updateRemotePlaybackState, which is
/// what a DLNA poll uses and the one state source that runs on a host VM.
void main() {
  initializeTestEnvironment();

  late List<String> calls;
  late MuslyAudioHandler handler;

  MuslyAudioHandler build({bool enabled = true}) {
    final h = MuslyAudioHandler(
      releaseWhenIdle: enabled,
      releaseWakeLock: () async => calls.add('release'),
    );
    h.onIdleTimeout = () async => calls.add('timeout');
    return h;
  }

  void setPlaying(bool playing) => handler.updateRemotePlaybackState(
        playing: playing,
        position: Duration.zero,
      );

  setUp(() => calls = []);
  tearDown(() => handler.cancelLocalStateMirror());

  testWidgets('releases five minutes after playback stops', (tester) async {
    handler = build();
    setPlaying(true);
    setPlaying(false);

    await tester
        .pump(MuslyAudioHandler.idleRelease - const Duration(seconds: 1));
    expect(calls, isEmpty);

    await tester.pump(const Duration(seconds: 1));
    expect(calls, ['timeout', 'release'],
        reason: 'the renderer is dropped before the service goes');
  });

  testWidgets('a paused state every second does not restart the clock',
      (tester) async {
    // A DLNA poll republishes the paused state once a second; if each one
    // restarted the countdown the release would never come.
    handler = build();
    setPlaying(true);
    for (var i = 0; i < MuslyAudioHandler.idleRelease.inSeconds; i++) {
      setPlaying(false);
      await tester.pump(const Duration(seconds: 1));
    }
    expect(calls, ['timeout', 'release']);
  });

  testWidgets('playing again before the timeout keeps the service',
      (tester) async {
    handler = build();
    setPlaying(true);
    setPlaying(false);
    await tester.pump(const Duration(minutes: 4));
    setPlaying(true);
    await tester.pump(const Duration(minutes: 30));
    expect(calls, isEmpty);
  });

  testWidgets('releases once per pause, and again after the next play',
      (tester) async {
    handler = build();
    setPlaying(true);
    setPlaying(false);
    await tester.pump(MuslyAudioHandler.idleRelease);
    setPlaying(false);
    await tester.pump(const Duration(minutes: 30));
    expect(calls, ['timeout', 'release']);

    setPlaying(true);
    setPlaying(false);
    await tester.pump(MuslyAudioHandler.idleRelease);
    expect(calls, ['timeout', 'release', 'timeout', 'release']);
  });

  testWidgets('nothing to release before anything has played', (tester) async {
    // audio_service only takes the wake lock on the first playing state.
    handler = build();
    setPlaying(false);
    await tester.pump(const Duration(minutes: 30));
    expect(calls, isEmpty);
  });

  testWidgets('does not release if playback restarts during the callback',
      (tester) async {
    handler = build();
    handler.onIdleTimeout = () async {
      calls.add('timeout');
      setPlaying(true);
    };
    setPlaying(true);
    setPlaying(false);
    await tester.pump(MuslyAudioHandler.idleRelease);
    expect(calls, ['timeout']);
  });

  testWidgets('a failed release is retried, and play still cancels it',
      (tester) async {
    // The native side attaches the channel once the main thread first goes
    // idle, so a call made before then finds no handler.
    var failures = 1;
    handler = MuslyAudioHandler(
      releaseWhenIdle: true,
      releaseWakeLock: () async {
        calls.add('release');
        if (failures-- > 0) throw Exception('no channel yet');
      },
    );
    setPlaying(true);
    setPlaying(false);
    await tester.pump(MuslyAudioHandler.idleRelease);
    expect(calls, ['release']);

    await tester.pump(MuslyAudioHandler.idleRelease);
    expect(calls, ['release', 'release'], reason: 'retried after a failure');

    await tester.pump(const Duration(minutes: 30));
    expect(calls, ['release', 'release'], reason: 'stops once it worked');

    // A failure followed by play: the retry must not fire mid-playback.
    failures = 1;
    calls.clear();
    setPlaying(true);
    setPlaying(false);
    await tester.pump(MuslyAudioHandler.idleRelease);
    setPlaying(true);
    await tester.pump(const Duration(minutes: 30));
    expect(calls, ['release']);
  });

  testWidgets('no retry is left pending when play starts during a failure',
      (tester) async {
    handler = MuslyAudioHandler(
      releaseWhenIdle: true,
      releaseWakeLock: () async {
        calls.add('release');
        setPlaying(true);
        throw Exception('no channel yet');
      },
    );
    handler.onIdleTimeout = () async => calls.add('timeout');
    setPlaying(true);
    setPlaying(false);
    await tester.pump(MuslyAudioHandler.idleRelease);
    await tester.pump(const Duration(minutes: 30));
    expect(calls, ['timeout', 'release'],
        reason: 'nothing may fire while playing');
  });

  testWidgets('play during a successful release still arms the next pause',
      (tester) async {
    // The lock is released, then play takes it again before the call returns.
    var first = true;
    handler = MuslyAudioHandler(
      releaseWhenIdle: true,
      releaseWakeLock: () async {
        calls.add('release');
        if (first) {
          first = false;
          setPlaying(true);
        }
      },
    );
    setPlaying(true);
    setPlaying(false);
    await tester.pump(MuslyAudioHandler.idleRelease);
    expect(calls, ['release']);

    setPlaying(false);
    await tester.pump(MuslyAudioHandler.idleRelease);
    expect(calls, ['release', 'release'],
        reason: 'the lock taken by that play must be released too');
  });

  test('a finished queue is reported as not playing', () {
    // just_audio leaves `playing` true at the end of the queue; reporting that
    // to the session meant the idle release never started.
    expect(
      MuslyAudioHandler.reportsPlaying(true, ProcessingState.completed),
      isFalse,
    );
    expect(
        MuslyAudioHandler.reportsPlaying(true, ProcessingState.ready), isTrue);
    expect(MuslyAudioHandler.reportsPlaying(true, ProcessingState.buffering),
        isTrue,
        reason: 'a stall mid-track is still playing');
    expect(MuslyAudioHandler.reportsPlaying(false, ProcessingState.ready),
        isFalse);
  });

  test('play with nothing loaded is reported as not playing', () {
    // A media key that cold-starts the app calls play() before any source is
    // set; just_audio then reports playing while idle, indefinitely.
    expect(
      MuslyAudioHandler.reportsPlaying(true, ProcessingState.idle),
      isFalse,
    );
    expect(
        MuslyAudioHandler.reportsPlaying(true, ProcessingState.loading), isTrue,
        reason: 'a source is on its way');
  });

  testWidgets('off unless enabled, as on every platform but Android',
      (tester) async {
    handler = build(enabled: false);
    setPlaying(true);
    setPlaying(false);
    await tester.pump(const Duration(minutes: 30));
    expect(calls, isEmpty);
  });
}
