# KovaLink Thermion compatibility patch

This directory vendors `thermion_flutter` 0.7.0. Its Android plugin originally
compiled against API 33 while its AndroidX dependencies require API 34 or
newer. KovaLink raises the plugin `compileSdkVersion` to 36 and uses the AGP
declared by the application root instead of the plugin's legacy AGP 7.3
buildscript dependency.

Flutter 3.44 still opts out of AGP 9 Built-in Kotlin, so the patch applies the
root application's KGP through a conditional `PluginManager` call only while
that opt-out is active. With Built-in Kotlin enabled, no KGP is applied.

Remove this path dependency after upstream publishes the same compatibility
change and Android/iOS builds have been verified.

## Texture readiness and error callbacks (2026-11-25)

`ThermionWidget.create` gains `onTextureReady` and `onError`. Upstream only
reports texture allocation/binding failures to `FlutterError` and keeps
showing an empty `SizedBox`, so a caller cannot tell a blank GPU view from a
working one (KovaLink on a real Android phone showed only the HUD over the
scaffold colour). `onTextureReady` fires after a texture is registered, bound
and its first frame submitted; `onError` receives viewer-creation and texture
errors. KovaLink's `GpuRoadSurface` watchdog uses both to switch to its
software renderer.

## Rendered frame count (2026-11-25)

`ThermionFlutterPlugin.renderedFrameCount` exposes the native frame
scheduler's monotonic `dispatchedFrameCount` (-1 on platforms without it).
KovaLink's GPU watchdog records how many frames were dispatched while it
waited for a visible frame, so 설정 → 진단 can tell "the engine never
rendered" (scheduler/EGL problem) apart from "it rendered but nothing was
composited" (texture/compositor problem).
