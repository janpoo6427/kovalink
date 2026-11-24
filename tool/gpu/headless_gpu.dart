// Headless GPU (Filament OpenGL) context for worker captures and tests.
//
// Runs thermion on Mesa's llvmpipe through an EGL surfaceless display, so
// the exact GPU renderer the phone uses can draw PNGs on a machine without
// a GPU or display. Used only by tool/ captures (not shipped in the app).
import 'dart:io';

import 'package:thermion_dart/thermion_dart.dart';
// ignore: implementation_imports
import 'package:thermion_dart/src/filament/src/implementation/ffi_filament_app.dart';

typedef _GetProcN = Pointer<Void> Function(Pointer<Utf8>);
typedef _GetPlatDispN =
    Pointer<Void> Function(Uint32, Pointer<Void>, Pointer<Void>);
typedef _GetPlatDispD =
    Pointer<Void> Function(int, Pointer<Void>, Pointer<Void>);
typedef _CreateN = Pointer<Void> Function(Pointer<Void>);

class HeadlessGpu {
  HeadlessGpu._(this.app, this.viewer, this.swapChain, this.width, this.height);

  final FFIFilamentApp app;
  final ThermionViewer viewer;
  SwapChain swapChain;
  int width;
  int height;

  static String get thermionLibrary =>
      Platform.environment['KOVA_THERMION_LIB'] ??
      '${Directory.current.path}/build/native_assets/linux/libthermion_dart.so';

  /// True when the native library and an EGL driver are available.
  static bool get available =>
      Platform.isLinux && File(thermionLibrary).existsSync();

  static Future<HeadlessGpu> create(
    int width,
    int height, {
    String root = '.',
  }) async {
    final egl = DynamicLibrary.open('libEGL.so.1');
    final getProc = egl.lookupFunction<_GetProcN, _GetProcN>(
      'eglGetProcAddress',
    );
    final name = 'eglGetPlatformDisplayEXT'.toNativeUtf8();
    final fp = getProc(name);
    malloc.free(name);
    if (fp == nullptr) throw StateError('EGL_EXT_platform_base missing');
    final getDisplay = fp
        .cast<NativeFunction<_GetPlatDispN>>()
        .asFunction<_GetPlatDispD>();
    const surfacelessMesa = 0x31DD;
    final display = getDisplay(surfacelessMesa, nullptr, nullptr);
    if (display == nullptr) throw StateError('no surfaceless EGL display');
    final lib = DynamicLibrary.open(thermionLibrary);
    final createPlatform = lib.lookupFunction<_CreateN, _CreateN>(
      'ThermionPlatformEGLHeadless_Create',
    );
    final platform = createPlatform(display);
    await FFIFilamentApp.create(
      config: FFIFilamentConfig(
        backend: Backend.OPENGL,
        platform: platform.cast(),
        loadResource: (uri) async {
          final path = uri.startsWith('asset://')
              ? '$root/${uri.substring(8)}'
              : uri;
          return File(path).readAsBytes();
        },
      ),
    );
    final app = FilamentApp.instance! as FFIFilamentApp;
    final viewer = ThermionViewerFFI(app: app);
    await viewer.initialized;
    final swap = await app.createHeadlessSwapChain(width, height);
    await app.renderManager.attach(viewer.view, swap);
    await viewer.setViewport(width, height);
    return HeadlessGpu._(app, viewer, swap, width, height);
  }

  Future<void> resize(int w, int h) async {
    if (w == width && h == height) return;
    await app.renderManager.detach(viewer.view, swapChain: swapChain);
    await app.destroySwapChain(swapChain);
    swapChain = await app.createHeadlessSwapChain(w, h);
    await app.renderManager.attach(viewer.view, swapChain);
    width = w;
    height = h;
    await viewer.setViewport(w, h);
  }

  /// Renders [warmup] extra frames (TAA/bloom history) then reads RGBA8
  /// pixels, top row first.
  Future<Uint8List> capture({int warmup = 0}) async {
    for (var i = 0; i < warmup; i++) {
      await app.capture(
        swapChain,
        view: viewer.view,
        pixelDataType: PixelDataType.UBYTE,
      );
    }
    final shots = await app.capture(
      swapChain,
      view: viewer.view,
      pixelDataType: PixelDataType.UBYTE,
    );
    return shots.first.$2;
  }

  Future<void> dispose() async {
    await viewer.dispose();
    await app.destroy();
  }
}
