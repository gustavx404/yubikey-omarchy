# Built-in icon set

These lightweight SVGs are bundled with the plugin, so the bar and account
list do not depend on a system icon theme or a network connection.

- `yubikey.svg`: connected hardware in the bar.
- `totp.svg` and `hotp.svg`: account type in the list.
- `settings.svg` and `back.svg`: panel navigation.
- Aegis-compatible icon packs can be loaded from Settings. Their validated
  local PNG, JPEG, and sanitized SVG logos take precedence over built-in marks.
- Every issuer has a stable colored initial when a matching pack logo is not
  available; accounts without labels fall back to the TOTP or HOTP icon.

The files are original, monochrome drawings licensed with this project. The
QML `ThemedIcon` component tints them with the active Omarchy foreground color.
