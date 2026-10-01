# Security

## Threat model

The plugin reads existing OATH credentials from YubiKey hardware over CCID. Credential secrets stay on the key. The plugin does not enroll credentials or write OTP secrets to disk.

The QML panel runs inside Omarchy's long-lived `omarchy-shell`, so a QML defect can affect that shell. Password entry and the unlocked-key password cache remain in shell memory until the connected-key inventory changes. The helper receives passwords over stdin, validates a fixed JSON schema, disables core dumps, and disables same-user ptrace access with `PR_SET_DUMPABLE`.

Account listing and code generation run in a transient `systemd-run --user` service. The service allows only `AF_UNIX` sockets and has `NoNewPrivileges`. Bubblewrap gives it a read-only system view, a private temporary directory, the helper file, and the PC/SC socket. Code generation also receives only the Wayland socket needed for clipboard access. Hardware discovery is a separate short-lived helper with read-only USB metadata access. The QML-launched processes use an explicit environment allowlist; helper subprocesses use absolute paths.

OTP generation and clipboard ownership stay inside the helper. It marks copied values sensitive, keeps the code in process memory only for the configured timeout (at most two minutes), and clears the clipboard only when it still contains that code. TOTP values use the earlier of the selected timeout and their expiry.

Optional account icons use the Aegis icon-pack ZIP format. The helper parses the untrusted archive in a network-restricted sandbox, accepts bounded PNG/JPEG assets and sanitized SVGs, and writes only into the plugin's ignored `icons/custom` data directory. The shell displays only validated local image paths; no icon files or manifests are executed.

The plugin does not type codes with `wtype`: that avoids clipboard exposure but can send a valid OTP to the wrong window if focus changes. Clipboard copying remains the explicit user action.

## What this does not protect against

- Malware or a compromised process running as the same user can read the clipboard, inspect shell memory, or interact with the YubiKey.
- A compromised Omarchy shell or modified plugin source can observe password input and alter the interface.
- Other clipboard managers may ignore the sensitive-data hint or retain clipboard history.
- Physical theft, malicious host firmware, compromised YubiKey firmware, and attacks against the operating system are outside this plugin's protection.
- Touch-required accounts still depend on the key's physical touch confirmation; this does not protect against malware already controlling the user's session.

## Reporting a vulnerability

Please report security issues privately through the repository's GitHub **Security → Report a vulnerability** flow. If private reporting is unavailable, contact the maintainer through GitHub before sharing exploit details publicly. Do not include live OTP values, OATH passwords, or YubiKey secrets in a report.

## Maintainer release checks

- Review the helper, QML, and dependency changes before publishing.
- Use signed release tags and publish checksums for release artifacts.
- Protect the `main` branch and require strong account authentication, including a hardware security key where available.
- Run `python -m unittest discover -s tests` and `omarchy plugin validate .` before a release.

The repository's GitHub branch protection, account authentication, and signing keys are maintainer-side settings; this plugin cannot configure or verify them.
