"""Collect complete public organisation issue/PR records through GitHub GraphQL."""

import json
import subprocess

ORG = "Jerome-Group"
REPOSITORY = "nameWithOwner isPrivate owner { login }"
FIELDS = "id number title url createdAt closedAt"


def graphql(query, **variables):
    command = ["gh", "api", "graphql", "-f", f"query={query}"]
    for key, value in variables.items():
        command += ["-f", f"{key}={value}"]
    result = json.loads(subprocess.check_output(command, text=True))
    if result.get("errors"):
        raise RuntimeError("Incomplete GitHub response; retaining previous snapshot")
    return result["data"]


def public_repository(repository):
    return (
        repository is not None
        and repository["isPrivate"] is False
        and repository["owner"]["login"].lower() == ORG.lower()
    )


def pages(fetch):
    cursor = None
    seen = set()
    while True:
        page = fetch(cursor)
        yield from page["nodes"]
        info = page["pageInfo"]
        if not info["hasNextPage"]:
            return
        cursor = info["endCursor"]
        if not cursor or cursor in seen:
            raise ValueError("Pagination did not advance")
        seen.add(cursor)


def repositories(api=graphql):
    query = f"""query($cursor:String) {{ organization(login:"{ORG}") {{
      repositories(first:100,after:$cursor,privacy:PUBLIC) {{
        pageInfo {{ hasNextPage endCursor }} nodes {{ {REPOSITORY} }}
      }}
    }} }}"""
    return list(
        pages(
            lambda cursor: api(query, **({"cursor": cursor} if cursor else {}))[
                "organization"
            ]["repositories"]
        )
    )


def records(repository, connection, api):
    extra = ""
    if connection == "pullRequests":
        extra = f"""body mergedAt closingIssuesReferences(first:100) {{
          pageInfo {{ hasNextPage }}
          nodes {{ {FIELDS} closed repository {{ {REPOSITORY} }} }}
        }}"""
    query = f"""query($name:String!,$cursor:String) {{
      repository(owner:"{ORG}",name:$name) {{ {REPOSITORY}
        {connection}(first:100,after:$cursor) {{
          pageInfo {{ hasNextPage endCursor }} nodes {{ {FIELDS} {extra} }}
        }}
      }} }}"""

    def fetch(cursor):
        result = api(
            query,
            name=repository["nameWithOwner"].split("/")[1],
            **({"cursor": cursor} if cursor else {}),
        )["repository"]
        if not public_repository(result):
            raise ValueError("Repository visibility or ownership changed")
        return result[connection]

    return list(pages(fetch))


def collect(api=graphql):
    selected = repositories(api)
    issues, pulls = [], []
    for repository in selected:
        if not public_repository(repository):
            raise ValueError("Non-public or external repository in public inventory")
        for connection, target in [("issues", issues), ("pullRequests", pulls)]:
            for item in records(repository, connection, api):
                item["repository"] = repository
                target.append(item)
    if {r["nameWithOwner"] for r in repositories(api)} != {
        r["nameWithOwner"] for r in selected
    }:
        raise ValueError("Public inventory changed during collection; retry")
    return selected, issues, pulls
