# Security policy

## Supported versions

| Version | Security fixes |
| --- | --- |
| 0.1.0-beta.1 | Supported through the next verified Mac prerelease |
| 0.1.0-alpha.x and superseded Mac prereleases | Upgrade to the latest published prerelease |
| Experimental Linux source | Development only; no supported desktop release |

There is no stable release yet. Fixes land on the active development branch and ship in the next verified Mac prerelease. Older builds aren't patched separately. Check [the download page](https://mouthtype.app/download) for the current version.

## Report a vulnerability

Email **[hi@scottbenson.dev](mailto:hi@scottbenson.dev)** with “Mouthtype security” in the subject. Don't put vulnerabilities, personal audio, transcripts, credentials or permission databases in public issues, discussions or pull requests. Repository collaborators can also contact the maintainer through an existing private channel.

Include the affected version or source revision, macOS version, reproduction steps, impact and a minimal synthetic example. Send sensitive evidence only after agreeing on a suitable transfer method. The maintainer will acknowledge and triage reports as availability allows; no response or fix deadline is guaranteed during prerelease testing.

## Scope

Relevant reports include unintended disclosure of recordings or text, delivery into an unintended destination, unsafe handling of imported files or downloaded models, compromised update verification, and build or release credential exposure. Mouthtype is a single-user local application with broad macOS Accessibility access. A person already controlling the user's account can read its local data and operate the same permissions; it isn't a sandbox or a defense against a compromised Mac.

See [security controls and limits](docs/SECURITY.md) for implemented safeguards, evidence and remaining gaps. A security score or notarization alone doesn't establish that an app is safe.
