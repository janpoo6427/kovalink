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
