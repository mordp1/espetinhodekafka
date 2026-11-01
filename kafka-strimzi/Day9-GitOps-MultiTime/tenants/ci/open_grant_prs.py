#!/usr/bin/env python3
"""
Turns the PENDING access requests found by validate.py into pull requests for the OWNER team.

For every (owner, grantee) pair it:
  1. branches off <remote>/<base> in a throw-away `git worktree` (your checkout is never touched),
  2. writes/extends apps/<owner>/grants/<grantee>.yaml  (a file inside the OWNER's folder),
  3. commits and pushes  access-request/<grantee>-to-<owner>   (deterministic name => re-running UPDATES the same PR),
  4. with --create-pr: opens (or updates) the PR with the `gh` CLI. CODEOWNERS then requests the review
     of the owner team automatically, because the changed file is under /apps/<owner>/.

Merging that PR == the owner approves. The requester's own PR stays red until then (validate.py exits 2).
"""
import argparse, json, os, subprocess, sys, tempfile, shutil
import yaml


def run(cmd, cwd=None, check=True, capture=True):
    r = subprocess.run(cmd, cwd=cwd, check=False, text=True,
                       stdout=subprocess.PIPE if capture else None, stderr=subprocess.STDOUT if capture else None)
    if check and r.returncode != 0:
        sys.exit(f"command failed ({r.returncode}): {' '.join(cmd)}\n{r.stdout or ''}")
    return (r.stdout or "").strip()


def group(pending):
    g = {}
    for p in pending:
        g.setdefault((p["owner"], p["grantee"]), []).append(p)
    return g


def grant_path(owner, grantee):
    return f"apps/{owner}/grants/{grantee}.yaml"


def merged_grant(existing, grantee, items, requested_by):
    doc = existing or {"grantee": grantee, "topics": {}}
    doc.setdefault("topics", {})
    order = ["Read", "Write", "Describe", "DescribeConfigs"]
    for it in items:
        cur = doc["topics"].setdefault(it["topic"], {"operations": []})
        ops = set(cur.get("operations", [])) | set(it["operations"])
        cur["operations"] = [o for o in order if o in ops]
        cur["requestedIn"] = requested_by or "n/a"
    return doc


HEADER = ("# GRANTS given by team {owner} to team {grantee}. This file lives in the OWNER's folder, so CODEOWNERS\n"
          "# forces {owner} to approve every change. Merging a PR that edits this file == \"{owner} agrees\".\n")


def body(owner, grantee, items, requested_by):
    rows = "\n".join(f"| `{owner}.{i['topic']}` | {', '.join(i['operations'])} | {'; '.join(i['needed_by'])} |" for i in items)
    return f"""## Access request: team `{grantee}` -> topics of team `{owner}`

Opened automatically by CI because a PR from **{grantee}** references topics owned by **{owner}**.

| Topic | Operations requested | Needed by |
|---|---|---|
{rows}

**Requested in:** {requested_by or 'n/a'}

### What approving means
Merging this PR adds `{grant_path(owner, grantee)}`. After that, `{grantee}`'s PR passes the access check and the
ACLs are rendered into their `KafkaUser`s. Nothing is created in Kafka by *this* PR: it only records consent.

### Reviewer checklist ({owner})
- [ ] Does `{grantee}` have a legitimate need for these topics?
- [ ] Are the operations the minimum (prefer `Read`, `Describe` only)?
- [ ] Does the topic carry data that `{grantee}` is allowed to see (PII / data-residency per region)?

To **deny**: close this PR. The requester's PR stays blocked.
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--report", required=True, help="JSON written by validate.py --report")
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    ap.add_argument("--remote", default="origin")
    ap.add_argument("--base", default="main")
    ap.add_argument("--requested-by", default=os.environ.get("REQUESTED_BY", ""), help="URL of the requester's PR")
    ap.add_argument("--push", action="store_true", help="push the access-request branches")
    ap.add_argument("--create-pr", action="store_true", help="open/update the PR with `gh` (implies --push)")
    args = ap.parse_args()

    pending = json.load(open(args.report))["pending"]
    if not pending:
        print("no pending access requests")
        return
    root = os.path.abspath(args.root)
    run(["git", "fetch", args.remote, args.base], cwd=root)

    for (owner, grantee), items in sorted(group(pending).items()):
        branch = f"access-request/{grantee}-to-{owner}"
        path = grant_path(owner, grantee)
        wt = tempfile.mkdtemp(prefix="grant-wt-")
        try:
            run(["git", "worktree", "add", "-q", "-B", branch, wt, f"{args.remote}/{args.base}"], cwd=root)
            full = os.path.join(wt, path)
            existing = yaml.safe_load(open(full)) if os.path.exists(full) else None
            doc = merged_grant(existing, grantee, items, args.requested_by)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w") as f:
                f.write(HEADER.format(owner=owner, grantee=grantee))
                yaml.safe_dump(doc, f, sort_keys=False, default_flow_style=False)
            run(["git", "add", path], cwd=wt)
            if not run(["git", "status", "--porcelain"], cwd=wt):
                print(f"[{owner} <- {grantee}] branch {branch}: grant file already up to date")
            else:
                run(["git", "-c", "user.name=kafka-access-bot", "-c", "user.email=kafka-access-bot@users.noreply.github.com",
                     "commit", "-q", "-m", f"access-request: {grantee} -> {owner} ({', '.join(i['topic'] for i in items)})"], cwd=wt)
                print(f"[{owner} <- {grantee}] committed {path} on branch {branch}")
            if args.push or args.create_pr:
                run(["git", "push", "-q", "--force-with-lease", "-u", args.remote, branch], cwd=wt)
                print(f"[{owner} <- {grantee}] pushed {args.remote}/{branch}")
            title = f"[access-request] {grantee} -> {owner}: " + ", ".join(f"{i['topic']} ({'/'.join(i['operations'])})" for i in items)
            if args.create_pr:
                existing_pr = run(["gh", "pr", "list", "--head", branch, "--base", args.base, "--json", "number", "-q", ".[0].number"], cwd=wt, check=False)
                bf = os.path.join(wt, ".pr-body.md"); open(bf, "w").write(body(owner, grantee, items, args.requested_by))
                if existing_pr:
                    run(["gh", "pr", "edit", existing_pr, "--title", title, "--body-file", bf], cwd=wt)
                    print(f"[{owner} <- {grantee}] updated PR #{existing_pr}")
                else:
                    run(["gh", "label", "create", "access-request", "--color", "FBCA04", "--force"], cwd=wt, check=False)
                    url = run(["gh", "pr", "create", "--base", args.base, "--head", branch, "--title", title, "--body-file", bf, "--label", "access-request"], cwd=wt)
                    print(f"[{owner} <- {grantee}] opened PR {url}")
            else:
                print(f"[{owner} <- {grantee}] (dry) PR title: {title}")
                print("---- PR body ----\n" + body(owner, grantee, items, args.requested_by) + "-----------------")
        finally:
            run(["git", "worktree", "remove", "--force", wt], cwd=root, check=False)
            shutil.rmtree(wt, ignore_errors=True)


if __name__ == "__main__":
    main()
