# The Organisation's conformance checker: read a repository tree and assert that it still matches
# the conventions every repository here agrees to. Read-only, and it asks nothing of the network —
# the tree in front of it and the manifest beside it are the whole input, which is what lets the
# fixtures in the management hub exercise its failing paths.
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

# Spelled out rather than `${1:?…}`, which exits 1 in some shells and 2 in others — and 1 is the
# status this script reserves for a tree that genuinely does not conform. A caller that could not
# tell a missing argument from a violation would report the wrong thing.
if [ $# -ne 1 ]; then
  printf 'usage: sh conformance/check-conformance.sh <tree>\n' >&2
  exit 2
fi

tree=$1

[ -d "$tree" ] || {
  printf 'No such tree: %s\n' "$tree" >&2
  exit 2
}

# The manifest ships beside this script and is read from beside it, never from the tree being
# checked — a repository that could edit the contract it is held to is not being held to one.
manifest=$(dirname -- "$0")/manifest
tab=$(printf '\t')

[ -f "$manifest" ] || {
  printf 'No manifest beside the checker: %s\n' "$manifest" >&2
  exit 2
}

# Rules are named, not numbered: the name is what a failing run prints, what the fixture runner
# asserts against, and what someone greps for. A renamed rule is therefore a visible change.
map_rule='map-covers-top-level-directories'
mirrored_rule='mirrored-files-match-the-organisations-copy'
skeleton_rule='skeleton-files-keep-their-required-headings'
ceiling_rule='documents-stay-under-their-line-ceiling'

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
    # and the trailing slash are what make it a path rather than a word: `docs` in a sentence is
    # not a row, and `docs/` written as a path is. Any cell of the row counts — which column a map
    # puts the path in is the map's business, and the rule is about coverage, not layout.
    printf '%s\n' "$rows" | grep -qF "\`$name/" ||
      fail "$map_rule" "$name/ has no row in MAP.md"
  done
}

# The manifest's records of one class, as lines. A record is `class<tab>path<tab>…`, and the
# `heading` records that follow a `skeleton` one are read separately, in the order they appear —
# that order is the requirement.
manifest_records() {
  awk -F'\t' -v class="$1" '$1 == class' "$manifest"
}

# The shim the generator carries too, and for the same reason in reverse: this script ships to
# `Jerome-Group/.github` on its own and can source nothing. `sha256sum` is what a runner has,
# `shasum` is what macOS has.
file_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1"
  else
    shasum -a 256 "$1"
  fi | cut -d' ' -f1
}

# A mirrored file is a copy of an Organisation document that the next seed silently overwrites,
# so any difference is drift by definition and there is nothing to weigh: the edit is already
# lost, and the only useful thing the failure can do is say where the text actually lives
# (ADR-0031).
#
# Only files that are present are checked. A private repository carries none of the four public
# health files, and a manifest that failed on their absence would fail every private repository
# in the Organisation for holding exactly what it was seeded with. Whether a file should be there
# at all is the seed's question, and `bin/audit` already asks it.
check_mirrored_files_match_the_organisations_copy() {
  records=$(manifest_records mirrored)

  while IFS="$tab" read -r _ path expected; do
    [ -n "$path" ] || continue
    file="$tree/$path"
    [ -f "$file" ] || continue

    [ "$(file_hash "$file")" = "$expected" ] ||
      fail "$mirrored_rule" \
        "$path differs from the Organisation's copy — edit it in Jerome-Group/org, not here"
  done <<EOF
$records
EOF
}

# A document's headings, in the order it carries them. Fenced blocks are skipped, because a shell
# comment or a Markdown sample inside one is not a heading a reader can navigate to. The direction
# that matters is the permissive one: counting a quoted heading would let it *satisfy* a
# requirement, so a document that had deleted the section, or moved it, would pass on the strength
# of quoting it. Documents here quote each other's shape constantly, so this is the ordinary case
# rather than the adversarial one — `required-heading-only-in-a-fence` and
# `reordering-hidden-in-a-fence` are the two fixtures that would otherwise pass.
#
# The `#` run is measured with `match`/`RLENGTH` rather than an interval expression, which not
# every awk on a runner supports: one to six `#` and a space is two to seven characters.
headings_of() {
  awk '
    /^[[:space:]]*```/ || /^[[:space:]]*~~~/ { fenced = 1 - fenced; next }
    fenced { next }
    /^#/ { if (match($0, /^#+ /) && RLENGTH >= 2 && RLENGTH <= 7) print }
  ' "$1"
}

# Present and in order, and nothing else: the required headings are consumed in sequence against
# the headings the file actually has, so anything added between them — a heading, a section, a
# whole chapter — is simply skipped over. Deleting a required heading or moving one behind
# another is the only way to fail. That permissiveness is the point (ADR-0031): a repository owns
# every word under these headings, and owes the Organisation only the shape.
check_required_headings() {
  checked=$1
  document=$2

  present=$(headings_of "$document")
  wanted=$(awk -F'\t' -v path="$checked" '$1 == "heading" && $2 == path {print $3}' "$manifest")

  # What is left of the file below the last heading matched. A required heading found only above
  # that point is present but out of order, which is why the two are asked separately — "missing"
  # and "moved" are different mistakes with different fixes.
  remaining=$present

  while IFS= read -r heading; do
    [ -n "$heading" ] || continue

    line=$(printf '%s\n' "$remaining" | grep -nFx -- "$heading" | head -n 1 | cut -d: -f1)

    if [ -n "$line" ]; then
      remaining=$(printf '%s\n' "$remaining" | tail -n +$((line + 1)))
    elif printf '%s\n' "$present" | grep -qFx -- "$heading"; then
      # One report per file. Every later heading is now out of order too, and a wall of them
      # would bury the one that moved.
      fail "$skeleton_rule" "$checked has \"$heading\" out of the order the Organisation requires"
      return
    else
      fail "$skeleton_rule" "$checked is missing the required heading \"$heading\""
      return
    fi
  done <<EOF
$wanted
EOF
}

# A ceiling rather than a target, set high enough that it fires on bloat and never on an ordinary
# edit — see the generator, which is where the number is declared.
check_line_ceiling() {
  checked=$1
  document=$2
  ceiling=$3

  [ "$ceiling" != '-' ] || return 0

  # `awk` rather than `wc -l`, which counts newlines: a file whose last line has none would come
  # in one under its real length, and the file one line over its ceiling is exactly the one
  # somebody would trim the newline off.
  lines=$(awk 'END { print NR }' "$document")
  [ "$lines" -le "$ceiling" ] ||
    fail "$ceiling_rule" "$checked is $lines lines, over its ceiling of $ceiling"
}

check_skeleton_files_keep_their_required_headings() {
  records=$(manifest_records skeleton)

  while IFS="$tab" read -r _ path ceiling; do
    [ -n "$path" ] || continue
    file="$tree/$path"
    [ -f "$file" ] || continue

    check_required_headings "$path" "$file"
    check_line_ceiling "$path" "$file" "$ceiling"
  done <<EOF
$records
EOF
}

# Seed-only files are named by the manifest and checked by nothing, which is a decision rather
# than an omission: a `.gitignore` or a starting ADR is a gift, not a contract (ADR-0031).

check_map_covers_top_level_directories
check_mirrored_files_match_the_organisations_copy
check_skeleton_files_keep_their_required_headings

if [ "$failures" -gt 0 ]; then
  printf '\n%d conformance violation(s) in %s.\n' "$failures" "$tree" >&2
  exit 1
fi

for rule in "$map_rule" "$mirrored_rule" "$skeleton_rule" "$ceiling_rule"; do
  printf 'ok    %s\n' "$rule"
done
