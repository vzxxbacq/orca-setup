#!/usr/bin/env node
'use strict';
// Pairing role from saved environments and the runtime device registry; started by role.sh, which may run it
// with Orca's bundled runtime (ELECTRON_RUN_AS_NODE) when Node.js is not installed yet.
// Only scope, name and last-seen time are read from the registry; tokens and device ids are never printed.
// Exit status: 0 consistent, 1 dual role or a conflict with ROLE_EXPECT, 3 role unknown (unreadable store).
const fs = require('node:fs');
const path = require('node:path');

const env = process.env;
const dir = env.ROLE_USER_DATA_DIR;
const recentDays = Number(env.ROLE_RECENT_DAYS || 30);
const clean = name => String(name || '(unnamed)').replace(/[\u0000-\u001f\u007f]/g, '?');

// A missing file means an empty store; one that exists but cannot be used makes the role unknown.
class StoreError extends Error {}
function readStore(file) {
  const full = path.join(dir, file);
  if (!fs.existsSync(full)) return null;
  try {
    return JSON.parse(fs.readFileSync(full, 'utf8'));
  } catch {
    throw new StoreError(`${file} exists but is not valid JSON`);
  }
}

function savedEnvironments() {
  if (env.ROLE_ENVIRONMENTS_SOURCE === 'cli') {
    try {
      const list = JSON.parse(env.ROLE_ENVIRONMENTS_JSON).result.environments;
      if (Array.isArray(list)) return list;
    } catch {
      // fall back to the pairing store file
    }
  }
  const store = readStore('orca-environments.json');
  if (store === null) return [];
  if (!store || !Array.isArray(store.environments)) throw new StoreError('orca-environments.json has an unexpected shape');
  return store.environments;
}

function devices() {
  const store = readStore('orca-devices.json');
  if (store === null) return [];
  if (!Array.isArray(store)) throw new StoreError('orca-devices.json has an unexpected shape (not an array)');
  return store.filter(d => d && typeof d === 'object');
}

let environmentNames;
let registry;
try {
  environmentNames = savedEnvironments().map(e => clean(e && e.name));
  registry = devices();
} catch (error) {
  if (!(error instanceof StoreError)) throw error;
  console.log('ROLE unknown');
  console.log(`reason: ${error.message}`);
  process.exit(3);
}

const cutoff = Date.now() - recentDays * 24 * 3600 * 1000;
const runtime = registry.filter(d => d.scope === 'runtime');
const recent = runtime.filter(d => Number(d.lastSeenAt || d.pairedAt || 0) >= cutoff).map(d => clean(d.name));
const mobile = registry.filter(d => d.scope === 'mobile').length;

const role = environmentNames.length && recent.length ? 'dual'
  : environmentNames.length ? 'client' : recent.length ? 'server' : 'none';
const conflict = role === 'dual'
  || (env.ROLE_EXPECT === 'server' && environmentNames.length > 0)
  || (env.ROLE_EXPECT === 'client' && recent.length > 0);

console.log(`ROLE ${role}`);
console.log(`saved environments: ${environmentNames.length}`);
console.log(`runtime clients seen in the last ${recentDays} days: ${recent.length} (of ${runtime.length})`);
console.log(`mobile pairings: ${mobile} (not counted)`);
if (conflict || env.ROLE_NAMES === 'yes') {
  for (const name of environmentNames) console.log(`  saved environment: ${name}`);
  for (const name of recent) console.log(`  runtime client: ${name}`);
}
if (conflict) {
  const wanted = env.ROLE_EXPECT || 'one role';
  if (environmentNames.length && wanted !== 'client') {
    console.log('CONFLICT this host saves environments; remove them with `environment rm` to keep it a server');
  }
  if (recent.length && wanted !== 'server') {
    console.log('CONFLICT this host accepts runtime clients; revoke them in Settings > Remote Orca Servers to keep it a client');
  }
  process.exitCode = 1;
}
