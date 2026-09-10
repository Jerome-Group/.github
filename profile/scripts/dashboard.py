"""Render a public organisation activity snapshot; no private or personal totals."""

import datetime as dt
import html
import json
import sys
from collections import Counter
from pathlib import Path

from assistance import summarize_assistance
from collect import collect, public_repository


def summarize(repositories, issues, pulls, today):
    names = {r["nameWithOwner"] for r in repositories if public_repository(r)}
    issues = {
        i["id"]: i
        for i in issues
        if public_repository(i["repository"])
        and i["repository"]["nameWithOwner"] in names
    }
    pulls = {
        p["id"]: p
        for p in pulls
        if public_repository(p["repository"])
        and p["repository"]["nameWithOwner"] in names
    }
    resolved = {}
    events = []

    def event(item, action, timestamp):
        events.append(
            dict(
                date=timestamp,
                action=action,
                title=item["title"],
                url=item["url"],
                repository=item["repository"]["nameWithOwner"],
                number=item["number"],
            )
        )

    for issue in issues.values():
        event(issue, "Issue opened", issue["createdAt"])
    merged = 0
    for pull in pulls.values():
        event(pull, "PR opened", pull["createdAt"])
        if not pull["mergedAt"]:
            continue
        merged += 1
        event(pull, "PR merged", pull["mergedAt"])
        references = pull["closingIssuesReferences"]
        if references["pageInfo"]["hasNextPage"]:
            raise ValueError("Closing issue references truncated; retaining snapshot")
        for issue in references["nodes"]:
            if (
                public_repository(issue["repository"])
                and issue["repository"]["nameWithOwner"] in names
                and issue["id"] in issues
                and issue["closed"]
                and issue["closedAt"]
                and issue["closedAt"] >= pull["mergedAt"]
            ):
                resolved[issue["id"]] = issue
    for issue in resolved.values():
        event(issue, "Linked issue resolved", issue["closedAt"])
    start = today - dt.timedelta(days=364)
    days = Counter(
        e["date"][:10] for e in events if str(start) <= e["date"][:10] <= str(today)
    )
    return {
        "repositories": sorted(names),
        "counts": [len(pulls), merged, len(resolved)],
        "assistance": summarize_assistance(pulls.values()),
        "start": str(start),
        "end": str(today),
        "days": dict(sorted(days.items())),
        "recent": sorted(events, key=lambda e: (e["date"], e["url"]), reverse=True)[:6],
    }


def panel(title, body, height):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="820" height="{height}" viewBox="0 0 820 {height}" role="img">
<title>{html.escape(title)}</title>
<rect width="820" height="{height}" rx="16" fill="#0d1422"/>
<g font-family="Segoe UI,Arial,sans-serif">{body}</g></svg>'''


def text(x, y, value, size=14, color="#dbe4f0"):
    return f'<text x="{x}" y="{y}" font-size="{size}" fill="{color}">{html.escape(str(value))}</text>'


def counters(snapshot, updated):
    labels = ["PRs opened", "PRs merged", "Linked issues resolved"]
    colors = ["#a78bfa", "#2dd4bf", "#fbbf24"]
    body = text(28, 37, "Building together", 20)
    body += text(610, 37, "ALL TIME · PUBLIC", 12, "#94a3b8")
    for index, (count, label, color) in enumerate(
        zip(snapshot["counts"], labels, colors)
    ):
        x = 28 + index * 260
        body += (
            f'<rect x="{x}" y="58" width="244" height="100" rx="10" fill="#172033"/>'
        )
        body += text(x + 18, 104, f"{count:,}", 34, color)
        body += text(x + 18, 135, label, 15)
    body += text(28, 189, f"Updated {updated} · All contributors", 12, "#94a3b8")
    return panel("Public organisation PR and linked issue totals", body, 210)


def calendar(snapshot):
    start = dt.date.fromisoformat(snapshot["start"])
    end = dt.date.fromisoformat(snapshot["end"])
    sunday = start - dt.timedelta(days=(start.weekday() + 1) % 7)
    palette = ["#202c40", "#255e63", "#268e88", "#2cc5ae", "#8af0cc"]
    days = snapshot["days"]
    maximum = max(days.values(), default=1) or 1
    body = text(28, 32, "A year of public activity", 20)
    body += text(625, 32, f"{sum(days.values()):,} events", 13)
    date = start
    months = set()
    while date <= end:
        offset = (date - sunday).days
        x = 28 + offset // 7 * 14
        count = days.get(str(date), 0)
        level = min(4, max(1, round(count / maximum * 4))) if count else 0
        if date.day == 1 and date.strftime("%Y-%m") not in months and x < 755:
            body += text(x, 54, date.strftime("%b"), 10, "#94a3b8")
            months.add(date.strftime("%Y-%m"))
        body += f'<rect x="{x}" y="{65 + offset % 7 * 14}" width="11" height="11" rx="2" fill="{palette[level]}"><title>{date}: {count} events</title></rect>'
        date += dt.timedelta(days=1)
    body += text(
        28,
        187,
        f"{start} → {end} · Issue/PR openings, PR merges and linked resolutions · UTC",
        12,
        "#94a3b8",
    )
    return panel("365 days of public organisation issue and PR activity", body, 207)


def activity(snapshot):
    body = text(28, 36, "Recent activity", 20)
    for index, item in enumerate(snapshot["recent"]):
        y = 74 + index * 61
        title = item["title"]
        title = title if len(title) <= 72 else title[:69] + "…"
        body += text(28, y, title, 15)
        body += text(
            28,
            y + 22,
            f"{item['repository']}#{item['number']} · {item['action']} · {item['date'][:10]}",
            12,
            "#94a3b8",
        )
    if not snapshot["recent"]:
        body += text(28, 78, "No public issue or PR activity yet.")
    return panel(
        "Recent public organisation activity; links in snapshot README",
        body,
        70 + max(1, len(snapshot["recent"])) * 61,
    )


def assistance(snapshot):
    body = text(28, 36, "Claude & Codex assistance", 20)
    body += text(
        28, 62, "Merged public PRs · declared model families · all time", 12, "#94a3b8"
    )
    total = sum(snapshot["assistance"].values())
    colors = ["#e6a77c", "#2dd4bf", "#a78bfa", "#fbbf24", "#94a3b8", "#64748b"]
    for index, ((label, count), color) in enumerate(
        zip(snapshot["assistance"].items(), colors)
    ):
        y = 96 + index * 35
        width = 420 * count / total if total else 0
        share = f"{100 * count / total:.1f}%" if total else "0.0%"
        body += text(28, y, label, 14)
        body += f'<rect x="192" y="{y - 14}" width="420" height="18" rx="4" fill="#172033"/>'
        body += f'<rect x="192" y="{y - 14}" width="{width:.1f}" height="18" rx="4" fill="{color}"/>'
        body += text(630, y, f"{count:,} PRs · {share}", 14)
    body += text(
        28,
        310,
        "One category per PR. Attribution is not lines of code, effort or app usage.",
        12,
        "#94a3b8",
    )
    return panel("Merged PRs by declared Claude and Codex/OpenAI assistance", body, 331)


def markdown(snapshot, updated):
    result = f"""# Organisation activity snapshot

Updated {updated}. Public Jerome-Group repositories; all contributors, including bots.

| All-time metric | Count |
| --- | ---: |
| PRs opened | {snapshot["counts"][0]} |
| PRs merged | {snapshot["counts"][1]} |
| Distinct linked issues resolved | {snapshot["counts"][2]} |

A linked resolution is a currently closed public organisation issue referenced by a merged
public organisation PR, with its latest closure at or after that merge. Each issue counts once.
This measures linkage, not causal proof or who clicked Close. Links and reopened issues can
change historical totals. Deleted records and repositories no longer public are excluded.

The calendar spans {snapshot["start"]} to {snapshot["end"]} inclusive, in UTC. Each issue opening,
PR opening, PR merge and distinct linked resolution counts as one event. It is not GitHub's
personal contribution calendar; commits, reviews and comments are not included.
Recent activity shows the six latest events from the same complete collection.

Daily scheduled refreshes may be delayed by GitHub. Failed collection keeps the previous
snapshot and its timestamp. Historical snapshots contain information public when collected.

## Recent activity

"""
    for item in snapshot["recent"]:
        title = (
            html.escape(item["title"])
            .replace("[", "&#91;")
            .replace("]", "&#93;")
            .replace("\n", " ")
            .replace("\r", " ")
        )
        result += f"- {item['date'][:10]} · {item['action']} · [{item['repository']}#{item['number']}: {title}]({item['url']})\n"
    result += (
        "\n## Declared assistance\n\n| Merged PR category | Count |\n| --- | ---: |\n"
    )
    for label, count in snapshot["assistance"].items():
        result += f"| {label} | {count} |\n"
    result += (
        "\nEach merged PR counts once, using only Assisted-by entries in its final contiguous "
        "trailer block. Claude/Anthropic names map to Claude; Codex/OpenAI/GPT and o1/o3/o4 "
        "names map to Codex / OpenAI. Both means both families were declared. Other / mixed "
        "covers other models and contradictory declarations. Unassisted requires explicit none; "
        "missing trailers are Undeclared, including unlabelled bot PRs. Percentages use all "
        "merged public PRs as the denominator. PR bodies can be edited retrospectively. "
        "This is model-family attribution, not proof of the application used, effort, code volume "
        "or authorship share. Commit trailers are not counted separately.\n"
    )
    result += "\n## Included public repositories\n\n"
    result += "\n".join(
        f"- [{name}](https://github.com/{name})" for name in snapshot["repositories"]
    )
    return result + "\n"


def main():
    now = dt.datetime.now(dt.timezone.utc)
    snapshot = summarize(*collect(), now.date())
    updated = now.strftime("%d %b %Y %H:%M UTC")
    files = {
        "counters.svg": counters(snapshot, updated),
        "calendar.svg": calendar(snapshot),
        "activity.svg": activity(snapshot),
        "assistance.svg": assistance(snapshot),
        "README.md": markdown(snapshot, updated),
        "snapshot.json": json.dumps(dict(snapshot, updated=updated), indent=2) + "\n",
    }
    output = Path(sys.argv[1])
    output.mkdir(parents=True, exist_ok=True)
    for name, content in files.items():
        (output / name).write_text(content, encoding="utf-8")


if __name__ == "__main__":
    main()
