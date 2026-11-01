#!/usr/bin/env python3
"""
Validates the tenants repo and detects CROSS-TEAM ACCESS REQUESTS.

Layout it understands:   apps/<app>/values.yaml                 (common, declared once)
                         apps/<app>/<env>/values.yaml           (optional env layer)
                         apps/<app>/<env>/<cluster>/values.yaml (leaf; `enabled: true` turns the site on)
                         apps/<app>/grants/<grantee>.yaml       (what <app> allows <grantee> to use)

Rules (each one is a real failure mode we want to catch BEFORE merge):
  R1  names: apps, envs, clusters follow the convention (the ApplicationSet derives everything from the path)
  R2  ownership: every apps/<app>/ has a CODEOWNERS rule (otherwise nobody reviews that team's PRs)
  R3  a user may reference ANOTHER team's topic ("<team>.<topic>") only if
        - that team exists and really declares the topic,
        - the topic is deployed in the SAME env/cluster (owner leaf enabled), and
        - the owner has granted it in apps/<owner>/grants/<me>.yaml   <- otherwise: PENDING REQUEST
  R4  own topic references must exist in the same effective config

Exit codes:  0 = all good   1 = errors   2 = no errors but PENDING access requests (blocks the PR until granted)
"""
import argparse, copy, json, os, re, sys
import yaml

NAME = re.compile(r"^[a-z][a-z0-9-]*$")
ENVS = {"dev", "stg", "prod"}
OPS_ORDER = ["Read", "Write", "Describe", "DescribeConfigs"]


def load(path):
    with open(path) as f:
        return yaml.safe_load(f) or {}


def deep_merge(base, over):
    """Same semantics as Helm: maps merge recursively, everything else (lists, scalars) is replaced."""
    out = copy.deepcopy(base)
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = copy.deepcopy(v)
    return out


def discover(root):
    """-> {app: {"common": {...}, "leaves": {(env, cluster): effective_values}, "grants": {grantee: {...}}}}"""
    apps = {}
    apps_dir = os.path.join(root, "apps")
    for app in sorted(os.listdir(apps_dir)):
        adir = os.path.join(apps_dir, app)
        if not os.path.isdir(adir):
            continue
        common_path = os.path.join(adir, "values.yaml")
        common = load(common_path) if os.path.exists(common_path) else {}
        entry = {"common": common, "leaves": {}, "grants": {}}
        for env in sorted(os.listdir(adir)):
            edir = os.path.join(adir, env)
            if not os.path.isdir(edir) or env == "grants":
                continue
            env_vals_path = os.path.join(edir, "values.yaml")
            env_vals = load(env_vals_path) if os.path.exists(env_vals_path) else {}
            for cluster in sorted(os.listdir(edir)):
                cdir = os.path.join(edir, cluster)
                leaf_path = os.path.join(cdir, "values.yaml")
                if os.path.isdir(cdir) and os.path.exists(leaf_path):
                    eff = deep_merge(deep_merge(common, env_vals), load(leaf_path))
                    entry["leaves"][(env, cluster)] = eff
        gdir = os.path.join(adir, "grants")
        if os.path.isdir(gdir):
            for fn in sorted(os.listdir(gdir)):
                if fn.endswith(".yaml"):
                    g = load(os.path.join(gdir, fn))
                    entry["grants"][g.get("grantee", fn[:-5])] = g
        apps[app] = entry
    return apps


def codeowned_apps(root):
    """apps that have a `/apps/<app>/ @owner` line in CODEOWNERS."""
    for p in (".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS"):
        full = os.path.join(root, p)
        if os.path.exists(full):
            owned = {}
            for line in open(full):
                line = line.strip()
                m = re.match(r"^/apps/([^/\s]+)/?\s+(@\S+)", line)
                if m:
                    owned[m.group(1)] = m.group(2)
            return owned
    return None


def sort_ops(ops):
    return sorted(set(ops), key=lambda o: OPS_ORDER.index(o) if o in OPS_ORDER else 99)


def analyse(root):
    apps = discover(root)
    errors, requests = [], []

    # R1 - names
    for app, a in apps.items():
        if not NAME.match(app):
            errors.append(f"R1 apps/{app}: team name must match {NAME.pattern}")
        for (env, cluster) in a["leaves"]:
            if env not in ENVS:
                errors.append(f"R1 apps/{app}/{env}: env must be one of {sorted(ENVS)}")
            if not re.match(r"^[a-z][a-z0-9]*$", cluster):
                errors.append(f"R1 apps/{app}/{env}/{cluster}: cluster name must be lowercase alphanumeric")

    # R2 - CODEOWNERS
    owners = codeowned_apps(root)
    if owners is None:
        errors.append("R2 no CODEOWNERS file found (.github/CODEOWNERS)")
    else:
        for app in apps:
            if app not in owners:
                errors.append(f"R2 apps/{app}/ has no CODEOWNERS rule: nobody would be asked to review changes to it")

    # R3/R4 - access references
    for app, a in apps.items():
        for (env, cluster), eff in sorted(a["leaves"].items()):
            if not eff.get("enabled"):
                continue
            own_topics = set((eff.get("topics") or {}).keys())
            for uname, u in sorted((eff.get("users") or {}).items()):
                for acc in u.get("access") or []:
                    ref = acc["topic"]
                    ops = sort_ops(acc.get("operations", []))
                    where = f"apps/{app}/{env}/{cluster} user '{uname}'"
                    if "." not in ref or ref.split(".", 1)[0] == app:
                        short = ref.split(".", 1)[-1]
                        if short not in own_topics:
                            errors.append(f"R4 {where}: topic '{short}' is not declared by team {app} in this env/cluster")
                        continue
                    owner, short = ref.split(".", 1)
                    if owner not in apps:
                        errors.append(f"R3 {where}: topic '{ref}' - there is no team '{owner}' (apps/{owner}/ does not exist)")
                        continue
                    oleaf = apps[owner]["leaves"].get((env, cluster))
                    if not oleaf or not oleaf.get("enabled"):
                        errors.append(f"R3 {where}: topic '{ref}' is not deployed in {env}/{cluster} (apps/{owner}/{env}/{cluster} is missing or enabled: false)")
                        continue
                    if short not in (oleaf.get("topics") or {}):
                        errors.append(f"R3 {where}: team {owner} does not declare topic '{short}' in {env}/{cluster}")
                        continue
                    granted = (((apps[owner]["grants"].get(app) or {}).get("topics") or {}).get(short) or {}).get("operations", [])
                    missing = [o for o in ops if o not in granted]
                    if missing:
                        requests.append({
                            "owner": owner, "grantee": app, "topic": short, "operations": ops,
                            "missing": missing, "env": env, "cluster": cluster, "user": uname,
                        })
    return errors, requests


def aggregate(requests):
    """one entry per (owner, grantee, topic) with the union of operations and where it is needed"""
    agg = {}
    for r in requests:
        k = (r["owner"], r["grantee"], r["topic"])
        e = agg.setdefault(k, {"owner": r["owner"], "grantee": r["grantee"], "topic": r["topic"], "operations": [], "needed_by": []})
        e["operations"] = sort_ops(e["operations"] + r["operations"])
        e["needed_by"].append(f'{r["user"]} @ {r["env"]}/{r["cluster"]}')
    for e in agg.values():
        e["needed_by"] = sorted(set(e["needed_by"]))
    return sorted(agg.values(), key=lambda e: (e["owner"], e["grantee"], e["topic"]))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    ap.add_argument("--report", help="write the JSON report here (input of open_grant_prs.py)")
    args = ap.parse_args()

    errors, requests = analyse(args.root)
    pending = aggregate(requests)

    for e in errors:
        print(f"ERROR   {e}")
    for p in pending:
        print(f"PENDING {p['grantee']} -> {p['owner']}.{p['topic']} {p['operations']}  (needed by: {', '.join(p['needed_by'])})")
        print(f"        no grant in apps/{p['owner']}/grants/{p['grantee']}.yaml -> team {p['owner']} must approve")
    if not errors and not pending:
        print("OK      all access references are valid and granted")

    if args.report:
        with open(args.report, "w") as f:
            json.dump({"errors": errors, "pending": pending}, f, indent=2)

    sys.exit(1 if errors else 2 if pending else 0)


if __name__ == "__main__":
    main()
