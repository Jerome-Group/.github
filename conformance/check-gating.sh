# Hold a repository's own workflows against its own required status checks, so that a repository
# which grows a check context and forgets to gate it fails on the pull request that introduces it
# rather than drifting until somebody runs the Baseline audit by hand (#82).
#
#   sh conformance/check-gating.sh <tree> <required-checks> [repository]
#
# `required-checks` is the file `resolve-required-checks.sh` beside this one writes: the contexts
# the default branch requires, one per line. `repository` is the `owner/name` the tree belongs to,
# and the only thing it decides is which waivers apply.
#
# Two scripts because only one of them can be exercised offline — the same trade ADR-0035 records
# for the linkage check. Everything that decides whether a repository conforms is here, where the
# fixtures in the management hub drive it; the `gh api` call is next door.
#
# Job names and triggers are read **statically** out of the workflow files rather than out of run
# history. That is what makes the rule deterministic and what makes it fire on the pull request
# that adds a workflow, before any run of it has happened — the audit's live sweep can only ask
# after the fact, which for a *removal* is after the merge it needed to block (#100).
#
# Through the interpreter, always, and never `./`: this file reaches the repository it is served
# from through the Contents API, which writes a plain blob and cannot set the executable bit. Same
# as the scripts beside it.
#
# It prints one line per rule, and the failing line names the rule first. Exit 0 when the
# repository conforms, 1 when it does not, 2 when the arguments are wrong — a usage mistake is not
# a conformance finding.
set -eu

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  printf 'usage: sh conformance/check-gating.sh <tree> <required-checks> [repository]\n' >&2
  exit 2
fi

tree=$1
required_file=$2
repository=${3:-}

[ -d "$tree" ] || {
  printf 'No such tree: %s\n' "$tree" >&2
  exit 2
}

# A missing file is a usage error rather than "nothing is required". The two are indistinguishable
# once read, and the wrong one of them is a run that reports every job in the repository as
# ungated because the resolver did not get to write anything.
[ -f "$required_file" ] || {
  printf 'No required-checks file: %s\n' "$required_file" >&2
  printf 'Write it first: sh conformance/resolve-required-checks.sh <owner/repo> %s\n' \
    "$required_file" >&2
  exit 2
}

manifest=$(dirname -- "$0")/manifest
tab=$(printf '\t')

[ -f "$manifest" ] || {
  printf 'No manifest beside the checker: %s\n' "$manifest" >&2
  exit 2
}

ungated_rule='pull-request-jobs-are-required-or-waived'
unreportable_rule='jobs-that-cannot-report-on-a-pull-request-are-not-required'
unproduced_rule='every-required-check-is-produced-by-a-job'

failures=0

fail() {
  rule=$1
  detail=$2
  printf 'FAIL  %s  %s\n' "$rule" "$detail"
  failures=$((failures + 1))
}

required=$(grep -v '^[[:space:]]*$' "$required_file" || true)

# The waivers ship beside this script rather than in the tree being checked, for the reason the
# rest of the manifest does: a repository that could edit the contract it is held to is not being
# held to one. A waiver is a claim that a red check should let a merge through anyway, so it is
# made once, in the Organisation's own configuration, and travels here.
#
# `*` in place of the repository waives a context everywhere — `stamp-issue-labels` is seeded into
# every repository, so a per-repository list would be missing a line the day one is created.
waived=$(awk -F'\t' -v repo="$repository" \
  '$1 == "waived" && ($2 == "*" || $2 == repo) {print $3}' "$manifest")

# The workflow files of the tree. `.github/workflows/` and nowhere else, because that is the only
# directory GitHub runs anything out of; a workflow kept elsewhere produces no check context and
# is not what this rule is about.
workflow_files() {
  for path in "$tree"/.github/workflows/*.yml "$tree"/.github/workflows/*.yaml; do
    [ -f "$path" ] || continue
    printf '%s\n' "$path"
  done
}

# Whether a workflow can run on a pull request at all. Both `pull_request` and
# `pull_request_target` count: what the rule turns on is whether a job *can report on a pull
# request*, and both do.
#
# The three shapes `on:` is written in are all read — `on: pull_request`, `on: [push,
# pull_request]`, and the block form — because a repository writes whichever it likes and a reader
# that knew only one would answer "no" for the other two, which is the answer that fails a job
# that is gated perfectly well.
runs_on_a_pull_request() {
  awk '
    { sub(/\r$/, "") }
    /^[ \t]*#/ { next }
    { match($0, /^ */); indent = RLENGTH; rest = substr($0, indent + 1) }

    indent == 0 {
      key = rest
      sub(/[ \t]*:.*/, "", key)
      gsub(/["'"'"']/, "", key)
      in_on = (key == "on")

      if (in_on) {
        value = rest
        sub(/^[^:]*:[ \t]*/, "", value)
        sub(/[ \t]+#.*/, "", value)
        if (value ~ /pull_request/) { print "yes"; exit }
        trigger_indent = -1
      }
      next
    }

    in_on {
      if (trigger_indent < 0) trigger_indent = indent
      if (indent != trigger_indent) next

      key = rest
      sub(/^-[ \t]*/, "", key)
      sub(/[ \t]*:.*/, "", key)
      gsub(/["'"'"']/, "", key)
      if (key ~ /^pull_request(_target)?$/) { print "yes"; exit }
    }
  ' "$1"
}

# Every job of a workflow, as `kinds<tab>name`. The name is the job's `name:` where it has one and
# its id otherwise, because that is the one GitHub reports the check under — a job renamed by its
# `name:` renames its context, which is exactly the drift this rule exists to catch.
#
# The kinds say what the name can be matched against, and are a set rather than one word because a
# job can be two of them at once:
#
#   plain   the context is the name
#   caller  the job calls a reusable workflow, so the context is `<name> / <the called job>` —
#           and the called job lives in another repository, which this tree cannot read. The half
#           that is knowable is the prefix, and that is what is matched.
#   matrix  the job fans out, so its contexts are `<name> (<the values>)` — enumerable only by
#           resolving the matrix, which may itself be an expression. Prefix again.
#
# A matrix over a reusable workflow is both, and reported as `<name> (<values>) / <called job>`.
# Read as one word, whichever key came last in the file would decide — and a `caller` reading of
# that job matches nothing, which is a red check on a repository that has done nothing wrong. So
# the two accumulate, and the widest prefix either of them knows is what is matched.
#
# Indentation is measured rather than assumed: the first key under `jobs:` sets the job-id column
# and the first key inside a job sets the attribute column, so only keys in those two columns are
# read. That is what keeps a step's `name:` — or a `run: |` block that happens to contain one —
# from being read as the job's.
jobs_of() {
  awk '
    function flush(   kinds) {
      if (job == "") return
      kinds = (caller ? "caller " : "") (matrix ? "matrix " : "")
      printf "%s\t%s\n", (kinds == "" ? "plain" : kinds), (job_name != "" ? job_name : job)
      job = ""; job_name = ""; caller = 0; matrix = 0
    }

    { sub(/\r$/, "") }
    /^[ \t]*#/ || /^[ \t]*$/ { next }
    { match($0, /^ */); indent = RLENGTH; rest = substr($0, indent + 1) }

    indent == 0 {
      flush()
      in_jobs = (rest ~ /^["'"'"']?jobs["'"'"']?[ \t]*:/)
      job_indent = -1
      next
    }

    !in_jobs { next }

    {
      if (job_indent < 0) job_indent = indent
      if (indent < job_indent) next

      if (indent == job_indent) {
        flush()
        job = rest
        sub(/[ \t]*:.*/, "", job)
        gsub(/["'"'"']/, "", job)
        attribute_indent = -1
        caller = 0
        matrix = 0
        next
      }

      if (attribute_indent < 0) attribute_indent = indent
      if (indent != attribute_indent) next

      key = rest
      sub(/[ \t]*:.*/, "", key)
      value = rest
      sub(/^[^:]*:[ \t]*/, "", value)
      sub(/[ \t]+#.*/, "", value)
      gsub(/^["'"'"']|["'"'"']$/, "", value)

      if (key == "name" && value != "") job_name = value
      else if (key == "uses") caller = 1
      else if (key == "strategy") matrix = 1
    }

    END { flush() }
  ' "$1"
}

# Every job of the tree, as `pull-request-capable<tab>kinds<tab>name<tab>workflow`. Read once: three
# rules ask about the same set, and a set each of them derived for itself is a set they can
# disagree about.
all_jobs() {
  while IFS= read -r path; do
    [ -n "$path" ] || continue

    if [ -n "$(runs_on_a_pull_request "$path")" ]; then
      capable=yes
    else
      capable=no
    fi

    jobs_of "$path" | while IFS="$tab" read -r kinds name; do
      [ -n "$name" ] || continue
      printf "%s\t%s\t%s\t%s\n" "$capable" "$kinds" "$name" "${path#"$tree"/}"
    done
  done <<EOF
$(workflow_files)
EOF
}

# Whether a job could be reported under a context — the one comparison both directions use, so
# that "this job is gated" and "this context has a job" can never be answered by two rules that
# have drifted apart.
job_matches_context() {
  kinds=$1
  name=$2
  context=$3

  [ "$context" != "$name" ] || return 0

  case $kinds in
    *caller*) case $context in "$name / "*) return 0 ;; esac ;;
  esac

  case $kinds in
    *matrix*) case $context in "$name ("*) return 0 ;; esac ;;
  esac

  return 1
}

# What a job's context looks like where the tree cannot say what it is exactly. The failure has to
# name the string somebody will type into a ruleset, and for three of the four kinds that string
# is only knowable as a shape — so the shape is what is printed, rather than a bare job name the
# reader would copy and find never reports.
context_shape() {
  kinds=$1
  name=$2

  case $kinds in
    *caller*matrix* | *matrix*caller*) printf '%s (<the matrix values>) / <the called job>' "$name" ;;
    *caller*) printf '%s / <the called job>' "$name" ;;
    *matrix*) printf '%s (<the matrix values>)' "$name" ;;
    *) printf '%s' "$name" ;;
  esac
}

job_is_named_in() {
  kinds=$1
  name=$2
  list=$3

  while IFS= read -r context; do
    [ -n "$context" ] || continue
    job_matches_context "$kinds" "$name" "$context" && return 0
  done <<EOF
$list
EOF

  return 1
}

# A context produced but not required is CI that runs, goes red and blocks nothing — under a
# zero-approval Baseline that is a pull request with no reviewer at all (ADR-0017). It is the
# failure that arrives *later*, when a repository grows a real job and nobody remembers to gate
# it: `homepage` gained `deploy` and `preview` in one merge and neither was gated for a day (#81).
#
# The failure names both ways out, because they are genuinely both open and only the author knows
# which is meant. Requiring it is a round trip through the hub — see `CODING_STANDARDS.md` §6 —
# and that is the intended cost: the alternative is merging with no reviewer.
check_pull_request_jobs_are_required_or_waived() {
  while IFS="$tab" read -r capable kinds name workflow; do
    [ "$capable" = yes ] || continue

    job_is_named_in "$kinds" "$name" "$required" && continue
    job_is_named_in "$kinds" "$name" "$waived" && continue

    fail "$ungated_rule" \
      "$(context_shape "$kinds" "$name") in $workflow runs on pull requests and is neither required nor waived — require the context in the Required checks ruleset, or waive it in the Organisation's conformance manifest ($manifest)"

    # The waivers that already apply, printed rather than pointed at. They are on the runner for
    # the length of this job and nowhere in the repository being checked, so a message that only
    # named the file would be sending somebody to another repository to read something that is
    # already here.
    printf '      waived here: %s\n' \
      "$(printf '%s\n' "$waived" | grep -v '^$' | paste -sd, - || printf 'nothing')"
  done <<EOF
$jobs
EOF
}

# The opposite direction, and it is not the same rule read backwards: a job that *cannot* report on
# a pull request and is required wedges every merge on a check that will never arrive, and the pull
# request shows it as merely pending rather than as failed. `homepage:deploy` is that shape — a
# deploy fired by a push and a schedule — and so is the label stamper the seed puts in every
# repository (#66).
check_jobs_that_cannot_report_on_a_pull_request_are_not_required() {
  while IFS="$tab" read -r capable kinds name workflow; do
    [ "$capable" = no ] || continue

    while IFS= read -r context; do
      [ -n "$context" ] || continue
      job_matches_context "$kinds" "$name" "$context" || continue

      fail "$unreportable_rule" \
        "$context is required, but $name in $workflow never runs on a pull request — every merge waits on a check that cannot report; stop requiring it"
    done <<CONTEXTS
$required
CONTEXTS
  done <<EOF
$jobs
EOF
}

# A required context that nothing in the tree produces. The audit catches this too, but only after
# the apply, which is after the merge — and the merge is the thing that needed stopping: a pull
# request deleting a job whose context is still required is blocked by a requirement only that
# merge could have lifted (#100). Read statically, it is visible on the pull request instead.
#
# The failure names the ordering, because nobody derives it from a pending check.
#
# This is the one rule a waiver excuses, and the only one it can honestly excuse. A context no
# workflow file produces may still be reported by something that is not a workflow at all — an
# app, a third-party integration — which this tree cannot see and the audit's live sweep can, since
# it reads run history (ADR-0044). Without the escape, a repository requiring such a context would
# be permanently red on advice about deleting a job that does not exist. The other two rules stay
# strict: a waiver is a claim about gating, and it cannot make a merge stop hanging.
check_every_required_check_is_produced_by_a_job() {
  while IFS= read -r context; do
    [ -n "$context" ] || continue

    printf '%s\n' "$waived" | grep -qxF -- "$context" && continue

    produced=
    while IFS="$tab" read -r capable kinds name workflow; do
      [ -n "$name" ] || continue
      if job_matches_context "$kinds" "$name" "$context"; then
        produced=yes
        break
      fi
    done <<JOBS
$jobs
JOBS

    [ -z "$produced" ] || continue

    fail "$unproduced_rule" \
      "$context is required and no job in this tree produces it — stop requiring it, merge, apply, then delete the job (CODING_STANDARDS.md §5)"
  done <<EOF
$required
EOF
}

jobs=$(all_jobs)

check_pull_request_jobs_are_required_or_waived
check_jobs_that_cannot_report_on_a_pull_request_are_not_required
check_every_required_check_is_produced_by_a_job

if [ "$failures" -gt 0 ]; then
  printf '\n%d gating violation(s) in %s.\n' "$failures" "$tree" >&2
  exit 1
fi

for rule in "$ungated_rule" "$unreportable_rule" "$unproduced_rule"; do
  printf 'ok    %s\n' "$rule"
done
