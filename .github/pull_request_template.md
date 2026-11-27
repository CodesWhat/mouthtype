## Change

Describe the problem, resulting behavior and relevant limits.

## Verification

List the checks actually run and any missing physical or hosted acceptance.

Promotion PRs into `main` also need this line, from a local full `swift test` run on the PR head (only documentation changes may follow it; the PR body is checked by CI):

Full suite receipt: <commit sha> <N> tests, 0 failures

## Security and data

Note changes to permissions, retained data, network access, dependencies or release authority when applicable. Keep private transcripts, recordings and credentials out of the PR.
