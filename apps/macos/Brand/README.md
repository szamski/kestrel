# Kestrel app icon

`dev/Kestrel.icon` and `prod/Kestrel.icon` are the same Icon Composer project. The only
difference is that `prod` sets `"hidden": true` on the group "Debug / Tests / Nightly Background".
After editing the icon in Icon Composer, save it as `dev/Kestrel.icon`, copy it over
`prod/Kestrel.icon`, and hide that group again.

Debug builds use `dev`, Release builds use `prod` (`EXCLUDED_SOURCE_FILE_NAMES` per configuration
in `T3Code.xcodeproj`). Xcode's `actool` does not accept a symlinked `.icon`, so both are real copies.
