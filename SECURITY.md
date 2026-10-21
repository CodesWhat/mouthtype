# Security policy

## Supported versions

| Version | Security fixes |
| --- | --- |
| 0.5.x | Supported. Security fixes ship in 0.5.x patch releases or the next minor release |
| 0.4.x | Unsupported. Upgrade to 0.5.0 |
| 0.3.x | Unsupported. Upgrade to 0.5.0 |
| 0.2.x | Unsupported. Upgrade to 0.5.0 |
| 0.1.x | Unsupported. Upgrade to 0.5.0 |
| 0.1.0-rc.x, 0.1.0-beta.x and 0.1.0-alpha.x | Unsupported. Upgrade to 0.5.0 |
| Experimental Linux source | Development only; no supported desktop release |

Fixes land on the active development branch and ship in a 0.4.x patch release or the next minor release. Older builds aren't patched separately. Check [the download page](https://mouthtype.app/download) for the current version.

## Report a vulnerability

Email **[security@codeswhat.com](mailto:security@codeswhat.com)** with “Mouthtype security” in the subject, or use [GitHub's private vulnerability reporting](https://github.com/CodesWhat/mouthtype/security/advisories/new). Don't put vulnerabilities, personal audio, transcripts, credentials or permission databases in public issues, discussions or pull requests.

Include the affected version or source revision, macOS version, reproduction steps, impact and a minimal synthetic example. Send sensitive evidence only after agreeing on a suitable transfer method. You can expect an acknowledgement within 7 days and a status update after triage. Fix timing depends on severity and maintainer availability, and no fix deadline is guaranteed. Reporters are credited in the release notes unless they prefer to stay anonymous.

## Scope

Relevant reports include unintended disclosure of recordings or text, delivery into an unintended destination, unsafe handling of imported files or downloaded models, compromised update verification, and build or release credential exposure. Mouthtype is a single-user local application with broad macOS Accessibility access. A person already controlling the user's account can read its local data and operate the same permissions; it isn't a sandbox or a defense against a compromised Mac.

See [security controls and limits](docs/SECURITY.md) for implemented safeguards, evidence and remaining gaps. A security score or notarization alone doesn't establish that an app is safe.
