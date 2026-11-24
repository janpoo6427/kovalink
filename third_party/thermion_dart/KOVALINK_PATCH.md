# KovaLink thermion_dart patch

This directory vendors `thermion_dart` 0.7.0 so the native build is
reproducible alongside the locally patched `thermion_flutter` plugin.

KovaLink adds `-Wno-return-type-c-linkage` for Android, iOS, and macOS native
builds. Thermion's generated FFI ABI returns `TFogOptions` and
`TAmbientOcclusionOptions` by value from C-linkage functions. Clang identifies
the records as C++ user-defined types because they contain default member
initializers and emits `-Wreturn-type-c-linkage` for every translation unit
that includes `TView.h`.

The warning suppression intentionally preserves Thermion's published ABI and
generated Dart bindings. Replacing the return values with output parameters
would require a coordinated upstream ABI and binding migration.

Remove this patch when upstream Thermion changes those functions to a
C-compatible ABI or suppresses the diagnostic in its own build hook.
