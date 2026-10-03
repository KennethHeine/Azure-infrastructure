#!/usr/bin/env python3
"""Validate exact ownership boundaries before deploying/pruning the DNS zone."""
import json
from pathlib import Path
import re
root = Path(__file__).resolve().parent
seen = set()
for filename in ("records.platform.json", "records.app.json", "records.external.json"):
    document = json.loads((root / filename).read_text())
    for record in document["records"]:
        key = (record["type"], record["name"])
        if key[0] not in ("A", "CNAME", "TXT", "MX") or not re.fullmatch(r"[@A-Za-z0-9_.-]+", key[1]):
            raise ValueError("Invalid DNS record identity")
        if key in seen:
            raise ValueError("DNS record has more than one owner")
        seen.add(key)
        if filename == "records.external.json":
            if set(record) != {"type", "name", "owner"} or not record["owner"].strip():
                raise ValueError("External records need a concrete owner, no static values")
        elif not record.get("values") or int(record["ttl"]) < 1:
            raise ValueError("Static record missing values or TTL")
print("DNS ownership validation passed")
