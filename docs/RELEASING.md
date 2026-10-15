# Private alpha releases

Release metadata lives in packaging/Version.plist. The display version includes the prerelease label; Apple’s marketing version and positive integer build number remain numeric. Increment the build number for each distributed build.

Follow the CodesWhat dev-branch, reviewed-PR and main-sync procedure. Keep deferred work out of the candidate, preserve dirty checkouts, and tag only the reviewed main revision. Sign the annotated `v<display version>` tag with the existing GitHub-recognized release signing key and push it. The release helper refuses a dirty source tree or a HEAD that does not match that tag.

Run `python3 scripts/package-release.py --notary-profile mouthtype-notary --output-dir /absolute/path/to/release-output` from the exact tagged source. It builds, signs, submits to Apple, waits with a ten-minute limit, staples, makes the final ZIP, extracts it, and requires signature/staple/Gatekeeper checks to pass on the extracted app. The ZIP contains the app, alpha install notes and license. The helper never installs or launches the app and refuses to replace an existing release-output directory.

The notarization profile must already be stored in Keychain. Never commit private keys or passwords. If Apple rejects a submission, inspect the saved notarization result and log rather than forcing acceptance. If the bounded wait expires, the submission continues at Apple; inspect its saved submission ID before attempting another upload.

Attach the final ZIP, SHA-256 file and release manifest to a private GitHub prerelease for the matching tag. Read the uploaded release back and compare a downloaded artifact’s checksum. Keep first-install, third-party-app and recognition limitations visible in release notes; do not describe unperformed checks as passed.
