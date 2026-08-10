# Read the check contexts a repository's default branch actually requires, and write them out for
# `check-gating.sh` beside this file to judge (#82).
#
#   sh conformance/resolve-required-checks.sh <owner/repo> <file>
#
# It writes one context per line, sorted, and writes nothing else.
#
# Split from the check for one reason: this half cannot be exercised without GitHub and the other
# half must be exercised without it (ADR-0035). Everything that decides whether a repository
# conforms lives next door, where fixtures can drive it; the whole of this is one read.
#
# `/rules/branches/<branch>` rather than `/rulesets`, and the difference matters twice. It answers
# the question the rule is actually about — what a merge into the default branch is held to,
# whichever ruleset says so, including one the Organisation applies from above — and it is readable
# with the `contents: read` grant the caller already makes, where the rulesets endpoint wants
# repository administration, which a workflow token cannot be given.
#
# Through the interpreter, always, and never `./` — the Contents API that writes this file into the
# hub commits a plain blob and cannot set the executable bit. Same as the scripts beside it.
#
# Needs `gh` signed in, or `GH_TOKEN` set, with read access to the repository. Exit 2 when the
# arguments are wrong or the read fails: this script makes no conformance findings, so it has no
# use for the status that reports one — and a read that could not happen must never reach the
# checker as "nothing is required", which would report every job in the repository as ungated.
set -eu

if [ $# -ne 2 ]; then
  printf 'usage: sh conformance/resolve-required-checks.sh <owner/repo> <file>\n' >&2
  exit 2
fi

repository=$1
file=$2

owner=${repository%%/*}
name=${repository#*/}

if [ -z "$owner" ] || [ -z "$name" ] || [ "$owner" = "$repository" ]; then
  printf 'Not an owner/repo: %s\n' "$repository" >&2
  exit 2
fi

# The default branch is asked for rather than assumed to be `main`. Every repository in the
# Organisation uses `main`, and a script that hard-coded it would be right until the day one did
# not — at which point it would read the rules of a branch that does not exist and report an empty
# requirement, which is the one wrong answer this script must never give.
branch=$(gh api "/repos/$repository" --jq '.default_branch') || {
  printf 'Could not read %s. The token needs read access to the repository.\n' "$repository" >&2
  exit 2
}

[ -n "$branch" ] || {
  printf 'No default branch on %s.\n' "$repository" >&2
  exit 2
}

rules=$(gh api "/repos/$repository/rules/branches/$branch") || {
  printf 'Could not read the rules on %s of %s.\n' "$branch" "$repository" >&2
  exit 2
}

printf '%s' "$rules" |
  jq -r '.[] | select(.type == "required_status_checks") |
         .parameters.required_status_checks[]? | .context' |
  LC_ALL=C sort -u >"$file"

printf 'ok    resolved the required checks on %s of %s into %s\n' "$branch" "$repository" "$file"
