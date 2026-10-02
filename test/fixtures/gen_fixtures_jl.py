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

    w(")\n")

print(f"regenerated {dst}")
