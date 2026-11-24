# KovaLink `flutter_webrtc` compatibility patch

This directory vendors `flutter_webrtc` 1.6.3 for the Android and iOS targets.
Its Android Gradle script neither declares nor explicitly applies the Kotlin
Gradle Plugin.

Flutter 3.44 supplies KGP while `android.builtInKotlin=false`. Flutter 3.47 and
later can instead use AGP 9 Built-in Kotlin without an incompatible plugin-level
KGP application. Remove this path dependency after upstream ships an equivalent
release and both platform builds have been verified.
