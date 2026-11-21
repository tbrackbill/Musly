import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musly/services/upnp_service.dart';

import '../fake_upnp_renderer.dart';

/// During a long pause the 1 s poll is suspended so nothing keeps the device
/// awake, while the renderer stays connected. These pin what restarts it and
/// what does not, against a fake renderer on loopback.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeUpnpRenderer renderer;
  late UpnpService upnp;

  setUp(() async {
    HttpOverrides.global = null;
    renderer = FakeUpnpRenderer();
    await renderer.start();
    upnp = UpnpService();
  });

  tearDown(() async {
    upnp.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await renderer.close();
  });

  int polls() => renderer.actions.where((a) => a == 'GetTransportInfo').length;

  Future<int> pollsOver(Duration d) async {
    final before = polls();
    await Future<void>.delayed(d);
    return polls() - before;
  }

  const twoPolls = Duration(milliseconds: 2200);

  test('suspending does nothing while disconnected', () {
    upnp.suspendPolling();
    expect(upnp.pollingSuspended, isFalse);
  });

  test('a suspended renderer stays connected and is not polled', () async {
    expect(await upnp.connect(renderer.device), isTrue);
    upnp.suspendPolling();
    expect(upnp.pollingSuspended, isTrue);
    expect(upnp.isConnected, isTrue);
    expect(await pollsOver(twoPolls), 0);
    expect(renderer.actions, isNot(contains('Stop')));
  });

  test('play resumes the poll', () async {
    expect(await upnp.connect(renderer.device), isTrue);
    upnp.suspendPolling();
    await upnp.play();
    expect(upnp.pollingSuspended, isFalse);
    expect(await pollsOver(twoPolls), greaterThan(0));
  });

  test('play can leave the poll suspended for the caller to resume', () async {
    expect(await upnp.connect(renderer.device), isTrue);
    upnp.suspendPolling();
    await upnp.play(resumePolling: false);
    expect(renderer.actions, contains('Play'));
    expect(upnp.pollingSuspended, isTrue);
    expect(await pollsOver(twoPolls), 0);

    upnp.resumePolling();
    expect(await pollsOver(twoPolls), greaterThan(0));
  });

  test('loading a track resumes the poll', () async {
    expect(await upnp.connect(renderer.device), isTrue);
    upnp.suspendPolling();
    expect(
      await upnp.loadAndPlay(url: 'http://x/a.mp3', title: 'a', artist: 'b'),
      isTrue,
    );
    expect(upnp.pollingSuspended, isFalse);
    expect(await pollsOver(twoPolls), greaterThan(0));
  });

  test('disconnect and reconnect clear the suspension', () async {
    expect(await upnp.connect(renderer.device), isTrue);
    upnp.suspendPolling();
    upnp.disconnect();
    expect(upnp.pollingSuspended, isFalse);

    expect(await upnp.connect(renderer.device), isTrue);
    expect(upnp.pollingSuspended, isFalse);
    expect(await pollsOver(twoPolls), greaterThan(0));
  });
}
