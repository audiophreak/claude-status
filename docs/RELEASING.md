# Releasing

Releases are built and published by GitHub Actions from a version tag, so every downloadable
archive is traceable to a commit and carries a build-provenance attestation.

## Checklist

1. Update `VERSION` and `ClaudeStatusVersion.current` (`scripts/build.sh` refuses a mismatch).
2. Move *Unreleased* notes in `CHANGELOG.md` under `## [x.y.z] — YYYY-MM-DD`. The release
   notes are taken from that section.
3. Locally: `scripts/test.sh` (includes the upgrade/rollback test against the previous public
   release), `python3 scripts/acceptance/cli_acceptance.py` for a real Claude Code session,
   `python3 scripts/acceptance/soak.py --out soak.jsonl` (31 minutes) for monitoring
   stability, and `scripts/perf.sh`. Never approve permission prompts from a test harness.
4. Push a release branch, open a pull request, wait for **CI** to pass, merge to `main`.
5. Tag and push: `git tag -a vX.Y.Z -m "Claude Status X.Y.Z" && git push origin vX.Y.Z`.
6. The **Release** workflow (`.github/workflows/release.yml`) checks that the tag matches
   `VERSION`. It runs the unit, integration and installer tests, builds the ad-hoc-signed arm64
   bundle, packages `ClaudeStatus-X.Y.Z-macos-arm64.zip` with `SHA256SUMS.txt`, attests
   provenance and creates the GitHub release.
7. Verify: download the archive, run `shasum -a 256 -c SHA256SUMS.txt` and
   `gh attestation verify ClaudeStatus-X.Y.Z-macos-arm64.zip --repo audiophreak/claude-status`.
8. Install the published archive locally with `scripts/rollback.sh <zip> --sha256 <sum>` so
   the installed build is exactly the released one, and run `claude-status-ctl selftest`.

## Signing and notarization

Archives are ad-hoc signed and **not notarized**. Notarization requires a paid Apple Developer
Program membership and a Developer ID certificate, which this project does not have. If one
becomes available, add a signing step that uses the Developer ID identity (from encrypted
repository secrets) and runs `xcrun notarytool submit --wait` plus `xcrun stapler staple` before
packaging. Then update the README, SECURITY.md and the release notes text in
`scripts/package-release.sh`.

## Homebrew (future)

The archive layout (one `.app` at the zip root, a stable versioned URL and a published
SHA-256) is what a Homebrew cask needs:

```ruby
cask "claude-status" do
  version "1.0.0"
  sha256 "<SHA256 from SHA256SUMS.txt>"
  url "https://github.com/audiophreak/claude-status/releases/download/v#{version}/ClaudeStatus-#{version}-macos-arm64.zip"
  name "Claude Status"
  desc "Menu bar monitor for local Claude Code sessions"
  homepage "https://github.com/audiophreak/claude-status"
  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"
  app "Claude Status.app"
end
```

Homebrew's main cask repository requires notarized apps, so until notarization is available a
cask would live in a personal tap (`audiophreak/homebrew-tap`).
