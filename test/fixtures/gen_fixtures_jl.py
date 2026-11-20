#!/usr/bin/env python3
"""Regenerate test/fixtures/reference_fixtures.jl from fixtures.json.

fixtures.json is produced by /tmp/atproto-fixtures/gen.mjs using the same
multiformats/@noble libraries the TypeScript reference depends on.
"""
import json
import os
import sys

src = sys.argv[1] if len(sys.argv) > 1 else "/tmp/atproto-fixtures/fixtures.json"
dst = os.path.join(os.path.dirname(os.path.abspath(__file__)), "reference_fixtures.jl")

f = json.load(open(src))

with open(dst, "w") as out:
    w = out.write
    w("# Generated from multiformats/@noble (the TS reference's own libraries).\n")
    w("# Do not edit by hand. Regenerate via gen_fixtures_jl.py.\n")
    w("const FIXTURES = (\n")

    w("  multibase = [\n")
    for v in f["multibase"]:
        w(f"    (hex = \"{v['hex']}\", prefix = '{v['prefix']}', encoded = \"{v['encoded']}\"),\n")
    w("  ],\n")

    w("  cids = [\n")
    for v in f["cids"]:
        w(f"    (input_hex = \"{v['inputHex']}\", v0_string = \"{v['v0String']}\", "
          f"v1_string = \"{v['v1String']}\", v1_base58 = \"{v['v1Base58']}\", "
          f"v1_bytes = \"{v['v1Bytes']}\", multihash_hex = \"{v['multihashHex']}\"),\n")
    w("  ],\n")

    w("  cid_parses = [\n")
    for v in f["cidParses"]:
        w(f"    (string = \"{v['string']}\", bytes = \"{v['bytes']}\", "
          f"version = {v['version']}, codec = {v['codec']}),\n")
    w("  ],\n")

    w("  keys = [\n")
    for v in f["keys"]:
        w(f"    (curve = :{v['curve']}, jwt_alg = \"{v['jwtAlg']}\", "
          f"priv_hex = \"{v['privHex']}\", pub_uncompressed = \"{v['pubUncompressedHex']}\", "
          f"pub_compressed = \"{v['pubCompressedHex']}\", did_key = \"{v['didKey']}\", "
          f"data_hex = \"{v['dataHex']}\", msg_hash = \"{v['msgHashHex']}\", "
          f"sig_compact = \"{v['sigCompactHex']}\"),\n")
    w("  ],\n")

    w("  dagcbor = [\n")
    for v in f["dagcbor"]:
        w(f"    (name = :{v['name']}, bytes_hex = \"{v['bytesHex']}\"),\n")
    w("  ],\n")

    def value_lit(v):
        t = v["t"]
        if t == "i":
            return f"(t = :i, v = {v['v']})"
        if t == "f":
            return f"(t = :f, v = {v['v']!r})"
        if t == "s":
            esc = v["v"].replace("\\", "\\\\").replace('\"', '\\"')
            return f'(t = :s, v = "{esc}")'
        if t == "b":
            return f"(t = :b, hex = \"{v['hex']}\")"
        if t == "bool":
            return f"(t = :bool, v = {'true' if v['v'] else 'false'})"
        if t == "nul":
            return "(t = :nul,)"
        if t == "cid":
            return f'(t = :cid, string = "{v['string']}")'
        if t == "arr":
            items = ", ".join(value_lit(x) for x in v["v"])
            return f"(t = :arr, v = [{items}])"
        if t == "map":
            pairs = ", ".join(
                f'"{k.replace('\"', '\\\" ')} " ' for k in v["v"]
            )  # placeholder, replaced below
            pairs = ", ".join(
                '"%s" => %s' % (k.replace("\\", "\\\\").replace('\"', '\\"'), value_lit(val))
                for k, val in v["v"].items()
            )
            return f"(t = :map, v = [{pairs}])"
        raise ValueError(f"unknown fixture type {t}")

    w("  recovery = [\n")
    for v in f.get("recovery", []):
        w(f"    (priv_hex = \"{v['priv_hex']}\", digest_hex = \"{v['digest_hex']}\", "
          f"sig65_hex = \"{v['sig65_hex']}\", recid = {v['recid']}, "
          f"pub_uncompressed = \"{v['pub_uncompressed_hex']}\"),\n")
    w("  ],\n")

    w("  ripemd160 = [\n")
    for v in f.get("ripemd160", {}).get("vectors", []):
        w(f"    (input_hex = \"{v['input_hex']}\", digest_hex = \"{v['digest_hex']}\"),\n")
    w("  ],\n")

    if "plc" in f:
        plc = f["plc"]
        w("  plc = (\n")
        w(f"    genesis_did = \"{plc['genesis_did']}\",\n")
        w(f"    genesis_op_bytes = \"{plc['genesis_op_bytes_hex']}\",\n")
        w(f"    genesis_digest = \"{plc['genesis_digest_hex']}\",\n")
        w(f"    ripemd_available = {str(plc['ripemd_available']).lower()},\n")
        w(f"    legacy_create_sig = \"{plc['legacy_create']['sig']}\",\n")
        w(f"    op1_bytes = \"{plc['op1_bytes_hex']}\",\n")
        w(f"    op1_digest = \"{plc['op1_digest_hex']}\",\n")
        w(f"    op1_sigs = [{', '.join('\"%s\"' % s for s in plc['operation']['sigs'])}],\n")
        w(f"    rotation_keys = [{', '.join('\"%s\"' % k for k in plc['rotation_keys'])}],\n")
        w("  ),\n")

    w("  dagcbor2 = [\n")
    for v in f["dagcbor2"]:
        w(f"    (name = :{v['name']}, value = {value_lit(v['value'])}, bytes_hex = \"{v['bytesHex']}\"),\n")
    w("  ],\n")

    w(")\n")

print(f"regenerated {dst}")
