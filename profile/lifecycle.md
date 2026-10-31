# Complete profile snapshots

The daily workflows collect and render into a fresh directory, copy every required output,
then publish one Git commit to `profile-data`. A failure before a successful push leaves the
previous remote snapshot visible. The authored profile and source remain on `main`.

## Bounded model

[Source](model/Lifecycle.tla), [passing configuration](model/pass.cfg),
[broken configuration](model/broken.cfg), [view](model/view.mjs),
[chart source](model/chart.mmd).

TLC 1.7.4 checked 25 states and 54 transitions. The chart has ten arrows. CompleteSnapshot,
FailureRetains, MainUnchanged and the deadlock check pass. Each of two independent publishers
has one attempt, one complete previous snapshot and one abstract new generation. The personal
publisher has five file keys; the organisation publisher has seven, including the artwork.

The broken configuration permits publishing a new README and timestamp before rendering the
other files. CompleteSnapshot fails on the shortest path, state 0 awaiting refresh, state 1
personal refresh starts, state 2 incomplete output is pushed. The normal workflows prevent this
exact path by requiring successful generation before publication. Explicit per-file copies also
reject a missing required output. This is source linkage, not a remote failure injection.

The model assumes successful generation produces coherent contents and timestamps and that a
successful Git push is atomic. It omits retries, competing writers, moving source revisions,
pagination, changing public visibility, source accuracy, schedules, caches and liveness. It does
not prove real workflow code, monotonic freshness across runs or the availability of GitHub.
The chart omits steps that keep the same displayed label.

## Reproduce

Install the pstack statechart skill, its pinned TLC 1.7.4 and Java 21. From this profile directory,
run the following with a fresh output directory. Replace `STATECHART_SKILL` with its installed
absolute directory. Use `broken.cfg` to reproduce the counterexample.

```sh
STATECHART_SKILL/scripts/statechart model/Lifecycle.tla --config model/pass.cfg --view model/view.mjs --out NEW-OUT
```

Pele 1.9.0 renders the generated Mermaid to SVG. The checked-in chart is a presentation of the
model. Project groupings in the separate project map describe identity, not this lifecycle.
