import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:musly/models/server_config.dart';
import 'package:musly/providers/auth_provider.dart';
import 'package:musly/services/services.dart';

import '../bootstrap.dart';

// With the server unreachable in a way that makes connections hang (Wi-Fi
// off but mobile data on, with a LAN-only server), the app showed "Cannot
// reach server" only after about 40 s: three pings of up to 10 s each, with
// 2 s between them. A ping that gets no answer is no longer retried.

/// Answers each ping with the next of [answers]; the last one repeats.
class _Server extends SubsonicService {
  _Server(this.answers);

  final List<Future<PingResult> Function()> answers;
  int pings = 0;

  @override
  Future<void> configure(ServerConfig config) async {}

  @override
  Future<PingResult> pingWithError() {
    final answer = answers[pings < answers.length ? pings : answers.length - 1];
    pings++;
    return answer();
  }
}

class _Storage extends Mock implements StorageService {}

Future<PingResult> _hang() => Completer<PingResult>().future;
Future<PingResult> _fail() async =>
    PingResult(success: false, error: 'Connection refused');
Future<PingResult> _ok() async => PingResult(success: true);

/// The offline store is read from disk once the ping is settled, and real
/// file I/O completes outside the test's fake clock. Alternate real waits
/// with pumps (which do not advance the clock) until [done] holds.
Future<void> _settle(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}

void main() {
  initializeTestEnvironment();

  // Its own app documents directory: test files run concurrently, and the
  // '.' that bootstrap.dart returns would be shared with other suites.
  late Directory appDir;
  setUpAll(() {
    appDir = Directory.systemTemp.createTempSync('musly_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => appDir.path,
    );
  });

  tearDownAll(() => appDir.deleteSync(recursive: true));

  late _Storage storage;

  setUp(() {
    storage = _Storage();
    when(() => storage.getServerConfig()).thenAnswer((_) async => ServerConfig(
          serverUrl: 'http://192.168.1.2:4533',
          username: 'u',
          password: 'p',
        ));
  });

  Future<AuthProvider> startAfter(
      WidgetTester tester, _Server server, Duration elapsed) async {
    final auth = AuthProvider(server, storage);
    await tester.pump(elapsed);
    await _settle(tester, () => auth.state != AuthState.authenticating);
    return auth;
  }

  testWidgets('a server that does not answer is unreachable within 7 s',
      (tester) async {
    final server = _Server([_hang]);

    final auth = await startAfter(tester, server, const Duration(seconds: 7));

    expect(auth.state, AuthState.serverUnreachable);
    expect(server.pings, 1);
  });

  testWidgets('a ping that fails at once is retried', (tester) async {
    // The network may still be coming up when the app starts.
    final server = _Server([_fail, _fail, _ok]);

    final auth = await startAfter(tester, server, const Duration(seconds: 5));

    expect(auth.state, AuthState.authenticated);
    expect(server.pings, 3);
  });

  testWidgets('a server that answers after a DNS resend is reached',
      (tester) async {
    // Android's resolver resends a lost DNS query after 5 s.
    final server = _Server([
      () => Future.delayed(const Duration(milliseconds: 6500), _ok),
    ]);

    final auth = await startAfter(tester, server, const Duration(seconds: 7));

    expect(auth.state, AuthState.authenticated);
    expect(server.pings, 1);
  });
}
