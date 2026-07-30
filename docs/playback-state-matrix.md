# Playback / renderer / Bluetooth state matrix

Every way playback can start, stop, or be interrupted, across every renderer,
and where each case is covered. Written after the head-unit PLAY investigation
(commit `3c8f443`), which found four defects that no existing test could have
caught.

Legend: **D** = covered by a Dart test (`flutter test`, no hardware) ·
**A** = covered by the adb harness (`tools/bt_headunit_test.sh`, device but no
car) · **H** = needs real hardware · **—** = not applicable ·
**GAP** = reachable in production, not covered.

## Renderers

| # | Renderer | Selected by | Audio renders on | `_isRenderingRemotely` |
|---|---|---|---|---|
| R1 | Local (just_audio/ExoPlayer) | default | phone / wired / A2DP | false |
| R2 | Cast (Chromecast) | `_castService.isConnected` | cast device | true |
| R3 | DLNA / UPnP | `_upnpService.isConnected` | renderer | true |
| R4 | Jukebox (Subsonic server-side) | `_jukeboxService.enabled` | server | false¹ |
| R5 | Radio / external stream | `playRadio` | phone | forced false |
| R6 | Offline / local file | `song.isLocal` | phone | false |

¹ Jukebox is remote in effect but does not set `_isRenderingRemotely`, so the
audio-focus and becoming-noisy guards at `player_provider.dart:397-419` do not
apply to it. See GAP-7.

R1 and R6 share one code path; A2DP is a routing detail of R1, not a separate
renderer — which is why a Bluetooth speaker exercises the same code as a car.

## Start cases

| # | Case | R1 | R2 | R3 | R4 | Coverage |
|---|---|---|---|---|---|---|
| S1 | User taps a song in the UI | ✓ | ✓ | ✓ | ✓ | **GAP** |
| S2 | Media button, app in foreground | ✓ | ✓ | ✓ | ✓ | **A** |
| S3 | Media button, app backgrounded, screen off | ✓ | ✓ | ✓ | ✓ | **A** |
| S4 | Media button, process dead, package *not* stopped | ✓ | — | — | — | **A** ← the head-unit bug |
| S5 | Media button, package **stopped** (force-stop) | ✗ | ✗ | ✗ | ✗ | **A** — unfixable, see below |
| S6 | Media button after device reboot / app update | ✓ | — | — | — | **A** (update path verified) |
| S7 | A2DP connect → resume-on-connect | ✓ | n/a² | n/a² | ? | **D** (logic) + **H** (timing) |
| S8 | Android Auto browse → play | ✓ | ✓ | ✓ | ✓ | **GAP** |
| S9 | Headless engine start (no UI) | ✓ | ? | ? | ? | **A** (R1 only) — **GAP-2** |
| S10 | System playback-resumption control after reboot | ✓ | — | — | — | **A** (`DEBUG_RESUMPTION_PROBE`) |

² resume-on-connect is explicitly skipped while `_isRenderingRemotely`.

## Stop / pause cases

| # | Case | Local (R1/R5/R6) | Remote (R2/R3) | Jukebox (R4) | Coverage |
|---|---|---|---|---|---|
| P1 | User pause | pause | pause on device | pause on server | **GAP** |
| P2 | Audio focus loss (call, other app) | pause | ignored (guard) | **not guarded** | **D** ✓mutation-verified |
| P3 | Audio focus transient | pause | ignored | **not guarded** | **D** |
| P4 | Audio focus duck | volume 0.3 | ignored | **not guarded** | **GAP-9** |
| P5 | Audio focus regain | resume if flagged | ignored | — | **GAP-6** |
| P6 | `AUDIO_BECOMING_NOISY` (BT/headphones pulled) | pause | ignored | **not guarded** | **D** ✓mutation-verified |
| P7 | Track ends naturally | next | next via poll heuristic | ? | **GAP-3** |
| P8 | Queue exhausted | stop | stop | ? | **GAP** |

## Crash / kill / freeze cases

| # | Case | Effect today | Coverage |
|---|---|---|---|
| C1 | Process killed by OS (LMK), package not stopped | `MusicService` restarts (START_STICKY); media button restarts Dart headlessly | **A** |
| C2 | Activity destroyed, process alive | engine now survives (cached engine); playback unaffected | **A** |
| C3 | Swipe from Recents | process survives (`stopWithTask="false"`) | **A** |
| C4 | `force-stop` / package stopped flag | **all PendingIntents cancelled — unrecoverable** | **A** (documented) |
| C5 | Package updated (Obtainium) | `MY_PACKAGE_REPLACED` re-registers the session, service stands down | **A** ✓verified on a real update |
| C6 | Device reboot | `BOOT_COMPLETED` re-registers the session | **H** (same code path as C5) |
| C7 | `startForeground` refused in background | was fatal; now caught | **GAP-4** |
| C8 | Doze / app standby during local playback | FGS + audio keeps app alive | **H** |
| C9 | Doze during remote (Cast/DLNA) playback | partial wakelock held (`a495233`) | **GAP-5** |
| C10 | Dart engine created twice (service + activity) | prevented by `FlutterEngineCache` | **A** |

## Renderer-loss cases

| # | Case | Effect today | Coverage |
|---|---|---|---|
| L1 | Cast session ends mid-playback | clears remote flag, `_isPlaying=false`; **does not resume locally** | **D** |
| L2 | UPnP renderer disappears | clears remote flag, **preserves position/duration deliberately** | **GAP-8** |
| L3 | A2DP device disconnects | `_isA2dpAudioActive` cleared; pause via P6 | **D** (wiring only) |
| L4 | Network lost mid-stream | auto-offline if offline content exists (`bb3852f`) | **GAP** |
| L5 | Server unreachable at cold headless start | ? | **GAP-2** |
| L6 | Cast and UPnP both connected | `isConnected` checked cast-first | **GAP** |

---

## The one genuinely unfixable case: S5 / C4

Confirmed against the Android 15 behavior-change docs:

> To support the intended behavior, in addition to the existing restrictions,
> the system also **cancels all pending intents when the app enters the stopped
> state** on a device running Android 15.

This is exactly the `PendingIntent$CanceledException` observed at
`MediaButtonReceiverHolder.send()`. Once the package is stopped, no app can be
woken by a media button — Symfonium and Spotify included. There is no permission,
flag or manifest entry that opts out.

What the platform *does* offer is re-registration when the user next removes the
app from that state: `ACTION_BOOT_COMPLETED` (and `ACTION_PACKAGE_UNSTOPPED`) are
delivered at that point specifically so an app can rebuild its pending intents,
and `ApplicationStartInfo.wasForceStopped()` reports whether it happened. That
does not rescue the drive where it first breaks, but it does fix **GAP-1**
(reboot / post-update), which is a case we currently fail and shouldn't.

## Prioritised gaps

| id | Gap | Why it matters | Fix |
|---|---|---|---|
| ~~GAP-1~~ | ~~No boot / package-replaced receiver~~ | **FIXED.** `MediaSessionRegistrationReceiver` re-registers on `BOOT_COMPLETED`, `LOCKED_BOOT_COMPLETED` and `MY_PACKAGE_REPLACED`; `MusicService` registers the session then stands down (`ACTION_REGISTER_SESSION`), leaving nothing resident. Verified end-to-end on a real update: post-update, never-opened, screen-off cold start reached audio in ~8s. | done |
| GAP-2 | Headless cold start only verified for R1, online | A headless start with the server unreachable, or with Cast/DLNA previously connected, is untested. | Extend harness + Dart tests. |
| GAP-3 | Track-end auto-advance for Cast is a position heuristic | Silently broke once already (fixed in `bb3852f`). | `syncRemotePosition` now covered; the advance heuristic itself is still not. |
| GAP-4 | `startForeground` refusal path untested | Now caught, but nothing proves the service still works after the catch. | Instrumented test. |
| GAP-5 | Wakelock during remote playback untested | Regression here means stalled auto-advance with the screen off. | Harness scenario. |
| GAP-6 | Focus-regain resume untested | `_shouldResumeOnFocusGain` is set in exactly one place; easy to break. | Dart test. |
| GAP-7 | Jukebox not guarded by the remote checks | Audio focus loss / noisy will pause local playback state while the *server* keeps playing → UI desync. | Treat jukebox as remote in the P2-P6 guards. |
| GAP-8 | `UpnpService` cannot be faked | It is a singleton with a private constructor (`UpnpService._internal()`), so no test can drive its connection state. Every DLNA row is therefore untestable in Dart — and DLNA has had four bugfix commits in recent history. | Give it the shape `CastService` has (plain class, overridable getters), or extract an interface. |
| GAP-9 | Audio-focus ducking untested | `_volume` is the *target* volume and is not mutated by ducking, so the obvious assertion is vacuous. Needs to observe the audio player, not the provider. | Inject/observe the `AudioPlayer` volume. |

## Running the coverage

```bash
flutter test                         # 79 tests, no hardware
tools/bt_headunit_test.sh            # A1-A4 + B1-B2, device over adb, no car
tools/bt_headunit_test.sh A3 A4      # just the cold-start cases
```

### On writing tests against this provider

Two traps cost real time here, both of which produce tests that pass whether or
not the code works:

1. **`_isRenderingRemotely` is only set inside `playSong()`**, which needs a
   configured server. A test that merely connects a fake renderer never enters
   remote mode, so any `expect(isRemotePlayback, ...)` is asserting
   `false == false`. Use `setRenderingRemotelyForTest()`.
2. **Asserting on provider flags cannot detect a deleted guard.** Removing
   `if (isRemotePlayback) return;` from a focus handler calls `pause()`, which
   leaves `isRemotePlayback` untouched. Assert on a fake renderer's call
   counters instead — `pause()` routes to `_castService.pause()` while cast is
   connected, so the counter moves.

Both P2 and P6 were verified by mutation: the guard was deleted, the test
failed, the guard was restored. Any new guard test in this area should be
checked the same way, or it is decoration.

