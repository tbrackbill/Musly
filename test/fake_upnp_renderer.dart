import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:musly/services/upnp_service.dart';

/// A UPnP renderer on loopback, so tests can drive the real UpnpService over
/// real HTTP and hold individual responses open to force an interleaving.
///
/// The test binding replaces HttpClient with one that answers 400; set
/// `HttpOverrides.global = null` before using this.
class FakeUpnpRenderer {
  FakeUpnpRenderer({this.volume = 15, this.name = 'Fake renderer'});

  final String name;
  late final HttpServer _server;

  int volume;

  /// Every DesiredVolume received, in arrival order.
  final setVolumes = <int>[];

  /// What the renderer applies when asked for a volume; defaults to exactly
  /// what was asked. Real hardware mixers often round.
  int Function(int requested) apply = (v) => v;

  /// When set, SetVolume requests wait for this before being applied.
  Completer<void>? gateSetVolume;

  /// When set, the next GetVolume records the volume at request time and then
  /// waits for [releaseRead] before answering with it.
  bool holdNextRead = false;
  final Completer<void> readHeld = Completer<void>();
  final Completer<void> releaseRead = Completer<void>();

  /// Moved by Play, Pause and Stop, as a real renderer's transport is. Set it
  /// directly to model the renderer changing on its own, e.g. a speaker that
  /// drops its paused track when it goes into standby.
  String transportState = 'PLAYING';

  /// The URI from the last SetAVTransportURI, reported back as TrackURI.
  String? trackUri;

  /// Every action received, in arrival order.
  final actions = <String>[];

  /// The request body of the last action of each name.
  final lastRequest = <String, String>{};

  /// When set, the next Play leaves the renderer in this state instead of
  /// PLAYING, once: a renderer whose stream went stale during a long pause
  /// goes to STOPPED.
  String? nextPlayState;

  /// When set, GetTransportInfo requests wait for this before answering.
  Completer<void>? gateTransportInfo;

  /// How many of the next requests to answer with a SOAP fault (HTTP 500),
  /// as a renderer does while it is still waking up.
  int refuseNext = 0;

  /// Seconds into the track. Advances on each position read while playing.
  int position = 0;

  bool _closed = false;

  String get base => 'http://${_server.address.host}:${_server.port}';

  UpnpDevice get device => UpnpDevice(
        friendlyName: name,
        location: '$base/desc.xml',
        manufacturer: 'test',
        modelName: 'test',
        avTransportUrl: '$base/avt',
        renderingControlUrl: '$base/rc',
      );

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  /// Also models a renderer that has gone away: later requests are refused.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!releaseRead.isCompleted) releaseRead.complete();
    if (gateTransportInfo?.isCompleted == false) gateTransportInfo!.complete();
    if (gateSetVolume?.isCompleted == false) gateSetVolume!.complete();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final action = (req.headers.value('SOAPAction') ?? '')
        .replaceAll('"', '')
        .split('#')
        .last;
    final request = await utf8.decodeStream(req);
    actions.add(action);
    lastRequest[action] = request;
    if (refuseNext > 0) {
      refuseNext--;
      req.response.statusCode = HttpStatus.internalServerError;
      await req.response.close();
      return;
    }

    var body = '';
    switch (action) {
      case 'GetTransportInfo':
        await gateTransportInfo?.future;
        body = '<CurrentTransportState>$transportState</CurrentTransportState>';
      case 'GetPositionInfo':
        // Advancing position makes every poll notify, as it does while a real
        // renderer is playing.
        final s = transportState == 'PLAYING' ? position++ : position;
        body = '<RelTime>0:${(s ~/ 60).toString().padLeft(2, '0')}:'
            '${(s % 60).toString().padLeft(2, '0')}</RelTime>'
            '<TrackDuration>0:03:00</TrackDuration>'
            '${trackUri == null ? '' : '<TrackURI>$trackUri</TrackURI>'}';
      case 'SetAVTransportURI':
        trackUri =
            RegExp(r'<CurrentURI>([^<]*)<').firstMatch(request)?.group(1);
        transportState = 'STOPPED';
      case 'Play':
        transportState = nextPlayState ?? 'PLAYING';
        nextPlayState = null;
      case 'Pause':
        transportState = 'PAUSED_PLAYBACK';
      case 'Stop':
        transportState = 'STOPPED';
      case 'Seek':
        final m = RegExp(r'<Target>(\d+):(\d+):(\d+)').firstMatch(request);
        if (m != null) {
          position = int.parse(m.group(1)!) * 3600 +
              int.parse(m.group(2)!) * 60 +
              int.parse(m.group(3)!);
        }
      case 'GetVolume':
        final seen = volume;
        if (holdNextRead) {
          holdNextRead = false;
          readHeld.complete();
          await releaseRead.future;
        }
        body = '<CurrentVolume>$seen</CurrentVolume>';
      case 'SetVolume':
        final m = RegExp(r'<DesiredVolume>(\d+)<').firstMatch(request);
        final requested = int.parse(m!.group(1)!);
        setVolumes.add(requested);
        await gateSetVolume?.future;
        volume = apply(requested);
    }

    req.response
      ..headers.contentType = ContentType('text', 'xml', charset: 'utf-8')
      ..write('<?xml version="1.0"?><s:Envelope '
          'xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
          '<u:${action}Response>$body</u:${action}Response>'
          '</s:Body></s:Envelope>');
    await req.response.close();
  }
}
