// Generates authoritative DAG-CBOR fixtures for ATProto.jl using @ipld/dag-cbor
// (the same library the TypeScript reference depends on).
//
// Run from a directory with node_modules containing: multiformats,
// @ipld/dag-cbor. Writes fixtures.json (consumed by gen_fixtures_jl.py).
import { CID } from 'multiformats/cid'
import * as dagcbor from '@ipld/dag-cbor'
import * as fs from 'fs'

const hex = (b) => Buffer.from(b).toString('hex')
const unhex = (s) => new Uint8Array(Buffer.from(s, 'hex'))

// Value trees are serialized in a typed notation that gen_fixtures_jl.py
// converts to Julia literals:
//   {t:'i', v:42}      integer          {t:'big', v:'123...'}  bignum (decimal string)
//   {t:'f', v:1.5}     float64          {t:'s', v:'x'}         string
//   {t:'b', hex:'..'}  bytes            {t:'bool', v:true}     boolean
//   {t:'nul'}          null             {t:'cid', string:'..'} CID
//   {t:'arr', v:[..]}  array            {t:'map', v:{k: ..}}  map (key order as written)
const i = (v) => ({ t: 'i', v })
const big = (v) => ({ t: 'big', v: v.toString() })
const f = (v) => ({ t: 'f', v })
const s = (v) => ({ t: 's', v })
const b = (bytes) => ({ t: 'b', hex: hex(bytes) })
const bool = (v) => ({ t: 'bool', v })
const nul = () => ({ t: 'nul' })
const arr = (...v) => ({ t: 'arr', v: [...v] })
const cidv = (c) => ({ t: 'cid', string: c.toString() })

const link = CID.parse('bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku')

// --- cases -------------------------------------------------------------------
const cases = [
  // scalars
  { name: 'int_zero', value: i(0) },
  { name: 'int_small', value: i(42) },
  { name: 'int_neg', value: i(-7) },
  { name: 'int_255', value: i(255) },
  { name: 'int_256', value: i(256) },
  { name: 'int_65535', value: i(65535) },
  { name: 'int_65536', value: i(65536) },
  { name: 'int_2p32', value: i(4294967296) },
  { name: 'int_max_safe', value: i(9007199254740991) }, // 2^53-1
  { name: 'int_neg_max_safe', value: i(-9007199254740991) },
  { name: 'float_half', value: f(1.5) },
  { name: 'float_pi', value: f(3.141592653589793) },
  { name: 'float_zero', value: f(0.0) },
  { name: 'string_empty', value: s('') },
  { name: 'string_unicode', value: s('héllo wörld ✓ 中文 🎉') },
  { name: 'string_long', value: s('abc'.repeat(100)) },
  { name: 'bytes_empty', value: b(Uint8Array.of()) },
  { name: 'bytes_deadbeef', value: b(unhex('deadbeef')) },
  { name: 'bytes_zeros', value: b(new Uint8Array(32)) },
  { name: 'true', value: bool(true) },
  { name: 'false', value: bool(false) },
  { name: 'null', value: nul() },
  { name: 'cid', value: cidv(link) },

  // bignums (beyond the safe-integer range)
  { name: 'big_2p53p1', value: big(9007199254740993n) },
  { name: 'big_neg_2p53p1', value: big(-9007199254740993n) },
  { name: 'big_2p64', value: big(18446744073709551616n) },
  { name: 'big_neg_2p63', value: big(-9223372036854775808n) }, // fits int64 natively? JS BigInt used: encoder picks bignum only beyond int64/uint64 range

  // structures
  { name: 'empty_array', value: arr() },
  { name: 'nested_array', value: arr(i(1), arr(i(2), arr(i(3))), i(4)) },
  { name: 'mixed_array', value: arr(i(1), s('two'), f(3.0), bool(true), nul(), cidv(link)) },
  { name: 'simple_map', value: { t: 'map', v: { hello: s('world'), n: i(42), yes: bool(true), no: bool(false), nothing: nul() } } },
  { name: 'empty_map', value: { t: 'map', v: {} } },
  { name: 'nested_map', value: { t: 'map', v: { a: i(1), nested: { t: 'map', v: { deep: { t: 'map', v: { deeper: s('value') } } } }, b: b(unhex('00ff')) } } },
  // canonical key ordering: bytewise length-first ("a" < "aa" < "ab" < "b")
  { name: 'map_key_order', value: { t: 'map', v: { b: i(4), ab: i(3), aa: i(2), a: i(1) } } },
  { name: 'map_with_cid', value: { t: 'map', v: { link: cidv(link), n: i(7) } } },
  { name: 'map_with_bytes', value: { t: 'map', v: { data: b(unhex('deadbeef01')) } } },
  { name: 'unicode_keys', value: { t: 'map', v: { 'ünïcode': i(1), ascii: i(2) } } },
]

const fixtures = { dagcbor2: [] }
for (const c of cases) {
  const native = toNative(c.value)
  const bytes = dagcbor.encode(native)
  // sanity: decode round-trips
  const decoded = dagcbor.decode(bytes)
  const reencoded = dagcbor.encode(decoded)
  if (Buffer.compare(Buffer.from(bytes), Buffer.from(reencoded)) !== 0) {
    throw new Error(`re-encode mismatch for ${c.name}`)
  }
  fixtures.dagcbor2.push({ name: c.name, value: c.value, bytesHex: hex(bytes) })
}

function toNative(v) {
  switch (v.t) {
    case 'i': return v.v
    case 'big': return BigInt(v.v)
    case 'f': return v.v
    case 's': return v.v
    case 'b': return unhex(v.hex)
    case 'bool': return v.v
    case 'nul': return null
    case 'cid': return CID.parse(v.string)
    case 'arr': return v.v.map(toNative)
    case 'map': {
      const o = {}
      for (const [k, val] of Object.entries(v.v)) o[k] = toNative(val)
      return o
    }
    default: throw new Error('bad type')
  }
}

// merge into the shared fixtures file
const path = '/tmp/atproto-fixtures/fixtures.json'
const existing = JSON.parse(fs.readFileSync(path, 'utf8'))
existing.dagcbor2 = fixtures.dagcbor2
fs.writeFileSync(path, JSON.stringify(existing, null, 2))
console.log('dagcbor2 fixtures written:', fixtures.dagcbor2.length, 'cases')
