#!/usr/bin/env python3
"""Mutate a coordination.k8s.io Lease JSON document for CAS replace via stdin/stdout.

Environment:
  JARVIS_CAS_MODE=acquire|heartbeat|release|touch
  JARVIS_CAS_HOLDER, JARVIS_CAS_DURATION, JARVIS_CAS_RUN_ID
  JARVIS_CAS_SCORE, JARVIS_CAS_MODEL (touch)
Exit 2 = logical conflict (foreign live holder / wrong holder).
"""
from __future__ import annotations

import datetime
import json
import os
import sys


def main() -> int:
    obj = json.load(sys.stdin)
    mode = os.environ["JARVIS_CAS_MODE"]
    holder = os.environ.get("JARVIS_CAS_HOLDER", "")
    duration = int(os.environ.get("JARVIS_CAS_DURATION", "60") or "60")
    run_id = os.environ.get("JARVIS_CAS_RUN_ID", "")
    score = os.environ.get("JARVIS_CAS_SCORE", "")
    model = os.environ.get("JARVIS_CAS_MODEL", "")
    now = datetime.datetime.now(datetime.timezone.utc)
    micro = now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond:06d}Z"
    rfc = now.strftime("%Y-%m-%dT%H:%M:%SZ")

    spec = obj.setdefault("spec", {})
    meta = obj.setdefault("metadata", {})
    ann = meta.setdefault("annotations", {})

    cur_holder = spec.get("holderIdentity") or ""
    renew = spec.get("renewTime")
    dur = int(spec.get("leaseDurationSeconds") or 60)
    expired = True
    if renew:
        try:
            renew_dt = datetime.datetime.fromisoformat(renew.replace("Z", "+00:00"))
            expired = now.timestamp() > renew_dt.timestamp() + dur
        except Exception:
            expired = True

    if mode == "acquire":
        if cur_holder and cur_holder != holder and not expired:
            print(f"fail lease held by {cur_holder}", file=sys.stderr)
            return 2
        spec["holderIdentity"] = holder
        spec["leaseDurationSeconds"] = duration
        spec["acquireTime"] = micro
        spec["renewTime"] = micro
        ann["jarvis.watchtower/run-id"] = run_id
        ann["jarvis.watchtower/last-activity-at"] = rfc
    elif mode == "heartbeat":
        if cur_holder != holder:
            print(
                f"fail heartbeat: lease held by {cur_holder or 'none'}, not {holder}",
                file=sys.stderr,
            )
            return 2
        if expired:
            print("fail heartbeat: lease already expired", file=sys.stderr)
            return 2
        spec["leaseDurationSeconds"] = duration
        spec["renewTime"] = micro
        ann["jarvis.watchtower/last-activity-at"] = rfc
    elif mode == "release":
        if holder and cur_holder and cur_holder != holder and not expired:
            print(
                f"fail release: lease held by {cur_holder}, not {holder}",
                file=sys.stderr,
            )
            return 2
        spec["holderIdentity"] = ""
        spec["leaseDurationSeconds"] = 60
        spec["renewTime"] = micro
        ann["jarvis.watchtower/run-id"] = ""
        ann["jarvis.watchtower/last-activity-at"] = rfc
    elif mode == "touch":
        ann["jarvis.watchtower/last-activity-at"] = rfc
        if score != "":
            ann["jarvis.watchtower/metrics-warmth-score"] = score
        if model != "":
            ann["jarvis.watchtower/metrics-model"] = model
    else:
        print(f"fail unknown CAS mode {mode}", file=sys.stderr)
        return 1

    meta.pop("managedFields", None)
    meta.pop("creationTimestamp", None)
    meta.pop("uid", None)
    meta.pop("generation", None)
    obj["metadata"] = meta
    obj["spec"] = spec
    json.dump(obj, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
