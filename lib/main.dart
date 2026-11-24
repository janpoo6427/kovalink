import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:kovalink/src/app/kovalink_app.dart';
import 'package:thermion_flutter/thermion_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    // SurfaceTexture is preferred for opaque content, but SurfaceProducer is
    // required to preserve alpha when the GLB is composited over the road UI.
    ThermionFlutterPlugin.instance.setOptions(
      const ThermionFlutterOptions(
        nativeOptions: NativeOptions(
          androidTextureSource: AndroidTextureSource.surfaceProducer,
        ),
      ),
    );
  }
  runApp(const KovaLinkApp());
}
