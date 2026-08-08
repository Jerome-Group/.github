# The Organisation's conformance checker: read a repository tree and assert that it still matches
# the conventions every repository here agrees to. Read-only, and it asks nothing of the network —
# the tree in front of it is the whole input, which is what lets the fixtures in the management
# hub exercise its failing paths.
#
#   sh conformance/check-conformance.sh <tree>
#
# Through the interpreter, always, and never `./`: this file reaches the repository it is served
# from through the Contents API, which writes a plain blob and has no way to set the executable
# bit — the same platform limit that forced `bin/seed-templates` to exist for the `CLAUDE.md`
# symlink. A caller that relied on the bit would work in a clone and fail here.
#
# It prints one line per rule, and the failing line names the rule first, so a caller can tell
# *which* rule went red rather than only that something did. Exit 0 when the tree conforms, 1 when
# it does not, 2 when the arguments are wrong — a usage mistake is not a conformance finding.
set -eu

tree=${1:?usage: sh conformance/check-conformance.sh <tree>}

[ -d "$tree" ] || {
  printf 'No such tree: %s\n' "$tree" >&2
  exit 2
}

# Rules are named, not numbered: the name is what a failing run prints, what the fixture runner
# asserts against, and what someone greps for. A renamed rule is therefore a visible change.
map_rule='map-covers-top-level-directories'

failures=0

fail() {
  rule=$1
  detail=$2
  printf 'FAIL  %s  %s\n' "$rule" "$detail"
  failures=$((failures + 1))
}

# `MAP.md` is the manifest, and this is the one rule that holds it to its own claim: a repository
# grows a top-level directory and the map is supposed to grow a row in the same pull request.
# Nothing enforced that, so the map drifted quietly and a reader who trusted it was misled — worse
# than having no map at all (`CODING_STANDARDS.md` §4).
#
# A row rather than a mention, because prose is not navigation: the table is what a reader steers
# by, and a directory named in a sentence somewhere in the file leaves the table wrong. A row that
# points deeper — `docs/adr/` for `docs/` — counts, since that is the entry point a reader wants.
check_map_covers_top_level_directories() {
  map="$tree/MAP.md"

  if [ ! -f "$map" ]; then
    fail "$map_rule" 'MAP.md is missing, so no directory has a row'
    return
  fi

  rows=$(grep '^[[:space:]]*|' "$map" || true)

  # Both globs, because `.github/` is a top-level directory like any other and is the one most
  # likely to be forgotten. `.` and `..` always match the second glob; a directory with no visible
  # entries leaves the first glob unexpanded, and the literal is not a directory, so it falls out.
  for path in "$tree"/* "$tree"/.*; do
    [ -d "$path" ] || continue
    name=${path##*/}
    case $name in
      . | .. | .git) continue ;;
    esac

    # `grep -F`, so a name carrying a regular-expression character — `.github` again — is matched
    # as the literal it is rather than as a pattern that would also match `xgithub`. The backtick
    # and the trailing slash are what make the match a path in the entry-point column and not a
    # word that happens to appear in a description.
    printf '%s\n' "$rows" | grep -qF "\`$name/" ||
      fail "$map_rule" "$name/ has no row in MAP.md"
  done
}

check_map_covers_top_level_directories

if [ "$failures" -gt 0 ]; then
  printf '\n%d conformance violation(s) in %s.\n' "$failures" "$tree" >&2
  exit 1
fi

printf 'ok    %s\n' "$map_rule"
