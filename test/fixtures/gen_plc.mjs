// Generates secp256k1 public-key recovery + PLC operation fixtures using
// @noble/curves (the TS reference's crypto stack).
import { secp256k1 } from '@noble/curves/secp256k1.js'
import { sha256 } from '@noble/hashes/sha2.js'
import * as dagcbor from '@ipld/dag-cbor'
import { base58btc } from 'multiformats/bases/base58'
import * as crypto from 'node:crypto'
import * as fs from 'fs'

const unhex = (s) => new Uint8Array(Buffer.from(s, 'hex'))
const hex = (b) => Buffer.from(b).toString('hex')
const b64url = (b) => Buffer.from(b).toString('base64url')

const fixtures = {}

// --- pubkey recovery -----------------------------------------------------------
// noble 2.x: sign() returns plain compact bytes; recovery bit is found by
// trying candidates against the known public key (valid recids reject otherwise)
function signRecoverable(digest, priv) {
  const sig = secp256k1.sign(digest, priv, { prehash: false })
  const expected = secp256k1.getPublicKey(priv, false)
  for (let recid = 0; recid < 4; recid++) {
    try {
      const pub = secp256k1.Signature.fromBytes(sig, 'compact')
        .addRecoveryBit(recid).recoverPublicKey(digest).toBytes(false)
      if (Buffer.from(pub).equals(Buffer.from(expected))) {
        return { sig65: new Uint8Array([...sig, recid]), recid }
      }
    } catch { /* invalid candidate */ }
  }
  throw new Error('no valid recovery id found')
}

fixtures.recovery = []
for (let i = 0; i < 8; i++) {
  const priv = new Uint8Array(32)
  priv[31] = i + 1
  const digest = sha256(new TextEncoder().encode(`recovery fixture ${i}`))
  const { sig65, recid } = signRecoverable(digest, priv)
  fixtures.recovery.push({
    priv_hex: hex(priv),
    digest_hex: hex(digest),
    sig65_hex: hex(sig65),
    recid,
    pub_uncompressed_hex: hex(secp256k1.getPublicKey(priv, false)),
  })
}

// --- ripemd160 availability check ------------------------------------------------
let ripemd160 = null
try {
  crypto.createHash('ripemd160')
  ripemd160 = (bytes) => new Uint8Array(crypto.createHash('ripemd160').update(bytes).digest())
  fixtures.ripemd160 = { available: true, vectors: [] }
  for (const s of ['', 'a', 'abc', 'message digest', 'abcdefghijklmnopqrstuvwxyz']) {
    fixtures.ripemd160.vectors.push({
      input_hex: hex(new TextEncoder().encode(s)),
      digest_hex: hex(ripemd160(new TextEncoder().encode(s))),
    })
  }
} catch {
  fixtures.ripemd160 = { available: false, vectors: [] }
}

// --- PLC operations ---------------------------------------------------------------
function makeKeys() {
  const k1 = new Uint8Array(32); k1[0] = 0x11
  const k2 = new Uint8Array(32); k2[0] = 0x22
  const k3 = new Uint8Array(32); k3[0] = 0x33
  return [k1, k2, k3]
}
function didKeyFor(priv, prefix) {
  const compressed = secp256k1.getPublicKey(priv, true)
  return 'did:key:' + base58btc.encode(new Uint8Array([...prefix, ...compressed]))
}

const SECP256K1_PREFIX = [0xe7, 0x01]
const [k1, k2, k3] = makeKeys()
const rotationKeys = [
  didKeyFor(k1, SECP256K1_PREFIX),
  didKeyFor(k2, SECP256K1_PREFIX),
  didKeyFor(k3, SECP256K1_PREFIX),
]
const atprotoKey = didKeyFor(new Uint8Array(32).fill(0x44), [0x80, 0x24]) // p256

// LegacyCreate (genesis): recoverable signature
const legacyCreate = {
  type: 'plc1',
  handle: 'alice.example.com',
  services: {
    atproto_pds: { type: 'AtprotoPersonalDataServer', endpoint: 'https://example.com' },
  },
  alsoKnownAs: ['at://alice.example.com'],
  rotationKeys,
  verificationMethods: { atproto: atprotoKey },
  prev: null,
}
const genesisBytes = dagcbor.encode(legacyCreate)
const genesisDigest = sha256(genesisBytes)
const genesisSigBytes = signRecoverable(genesisDigest, k1).sig65

const ALPHABET = 'abcdefghijklmnopqrstuvwxyz234567'
function base32LowerNoPad(bytes) {
  let acc = 0, bits = 0, out = ''
  for (const b of bytes) {
    acc = (acc << 8) | b; bits += 8
    while (bits >= 5) { bits -= 5; out += ALPHABET[(acc >> bits) & 31] }
  }
  if (bits > 0) out += ALPHABET[(acc << (5 - bits)) & 31]
  return out
}
const genesisDid =
  'did:plc:' + base32LowerNoPad(ripemd160 ? ripemd160(sha256(genesisBytes)) : new Uint8Array(15)).slice(0, 24)

const legacyCreateSigned = { ...legacyCreate, sig: b64url(genesisSigBytes) }

// follow-up Operation: rotation-key-signed compact sigs
const op1 = {
  type: 'plc1',
  prev: genesisDid, // NOTE: real plc uses prev = hash of previous op; fixture
                    // uses the did for signature-verification purposes only
  services: {
    atproto_pds: { type: 'AtprotoPersonalDataServer', endpoint: 'https://example.com' },
  },
  alsoKnownAs: ['at://new-handle.example.com'],
  rotationKeys,
  verificationMethods: { atproto: atprotoKey },
}
const op1Bytes = dagcbor.encode(op1)
const op1Digest = sha256(op1Bytes)
const op1Sig1 = secp256k1.sign(op1Digest, k1, { prehash: false })
const op1Sig2 = secp256k1.sign(op1Digest, k2, { prehash: false })
const op1Signed = { ...op1, sigs: [b64url(op1Sig1), b64url(op1Sig2)] }

fixtures.plc = {
  ripemd_available: !!ripemd160,
  genesis_did: genesisDid,
  genesis_op_bytes_hex: hex(genesisBytes),
  genesis_digest_hex: hex(genesisDigest),
  legacy_create: legacyCreateSigned,
  op1_bytes_hex: hex(op1Bytes),
  op1_digest_hex: hex(op1Digest),
  operation: op1Signed,
  rotation_keys: rotationKeys,
}

const path = '/tmp/atproto-fixtures/fixtures.json'
const existing = JSON.parse(fs.readFileSync(path, 'utf8'))
Object.assign(existing, fixtures)
fs.writeFileSync(path, JSON.stringify(existing, null, 2))
console.log('recovery:', fixtures.recovery.length, 'ripemd:', fixtures.ripemd160.available, 'genesis did:', genesisDid)
