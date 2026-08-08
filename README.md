# `.github`

The Jerome Group organisation's public face, its default community health files, and the
conformance check every repository calls. GitHub serves the health files here to **every**
repository the organisation owns that has not committed its own copy of a given file — private
repositories included; only this repository has to be public for that to work.

| Path | Where it shows up |
|------|-------------------|
| `profile/README.md` | The organisation's page at <https://github.com/Jerome-Group> |
| `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `SUPPORT.md`, `GOVERNANCE.md` | Every repository lacking its own copy |
| `.github/ISSUE_TEMPLATE/` | The issue forms of every repository with no `ISSUE_TEMPLATE` folder of its own |
| `.github/PULL_REQUEST_TEMPLATE.md` | The pull-request body of every repository lacking its own |
| `.github/workflows/conformance.yml` | A job on the pull requests of every repository that calls it |
| `conformance/` | The rules that job applies — read-only, and run through `sh` rather than executed |

The last two are not inherited: nothing is served from them automatically. A repository opts in by
calling the workflow at a pinned commit, which is what makes each new rule a reviewable event in
that repository rather than a silent change.

Overriding is per file, with one exception: a repository that has *any* `.github/ISSUE_TEMPLATE`
folder of its own inherits **none** of the forms here, not even the ones it did not replace.

## Editing this

**Do not edit these files here.** They are applied from the organisation's private management
hub, where they are reviewed, and an edit made in this repository is reverted by the next apply
rather than kept. Open an issue instead and it will be changed at the source.

`CODE_OF_CONDUCT.md` is the [Contributor Covenant](https://www.contributor-covenant.org)
v2.1 verbatim, with only the enforcement contact filled in — kept byte-identical to upstream so
that it is checkable against it.
