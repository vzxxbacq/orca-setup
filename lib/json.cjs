#!/usr/bin/env node
'use strict';
// Small JSON helpers for the shell scripts. Reads JSON on stdin and prints names, booleans or
// non-secret settings only; callers use `has` (exit status) for anything that may hold a credential.
//
//   has <path>               exit 0 when the value at <path> is present and non-empty
//   get <path>               print the value at <path> (strings raw, everything else as JSON)
//   names <path>             print the `name` of each element of the array at <path>, one per line
//   settings [task-source]   print the desired Orca settings merged from manifest/ and manifest/local/
//   diff <desired-json>      print the keys of <desired-json> whose value differs from stdin
//   missing <name>...        print the given names absent from the `name` fields of stdin's result.skills
//   skills-pending <name>... stdin is `orca skills install --dry-run --json`: print the given names the plan would
//                            write, link, copy, restore or replace (absent or partly installed); a skill that is
//                            only kept, updated or left as edited counts as installed
//   release-asset <regex>    stdin is a GitHub release: print "tag<TAB>name<TAB>url<TAB>digest" for the one asset
//                            whose name matches; refuses drafts, prereleases and anything but exactly one match
const fs = require('node:fs');
const path = require('node:path');

function stdinJson() {
  const text = fs.readFileSync(0, 'utf8').trim();
  return text ? JSON.parse(text) : {};
}

function at(value, dotted) {
  for (const key of (dotted || '').split('.').filter(Boolean)) {
    if (value === null || typeof value !== 'object') return undefined;
    value = value[key];
  }
  return value;
}

function present(value) {
  if (value === null || value === undefined || value === false) return false;
  if (Array.isArray(value)) return value.length > 0;
  if (typeof value === 'object') return Object.keys(value).length > 0;
  return String(value).trim() !== '';
}

function clean(name) {
  return String(name).replace(/[\u0000-\u001f\u007f]/g, '?');
}

function readJson(file) {
  return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : {};
}

function merge(base, overlay) {
  if (!overlay || typeof overlay !== 'object' || Array.isArray(overlay)) return overlay === undefined ? base : overlay;
  const out = {...(base && typeof base === 'object' && !Array.isArray(base) ? base : {})};
  for (const [key, value] of Object.entries(overlay)) out[key] = merge(out[key], value);
  return out;
}

function desiredSettings(taskSource) {
  const dir = process.env.ORCA_SETUP_MANIFEST_DIR || path.join(__dirname, '..', 'manifest');
  const manifest = merge(readJson(path.join(dir, 'orca-settings.json')), readJson(path.join(dir, 'local', 'orca-settings.json')));
  let settings = {...(manifest.settings || {})};
  if (taskSource && taskSource !== '-') {
    const extra = (manifest.taskSources || {})[taskSource];
    if (!extra) throw Error(`Unknown task source: ${taskSource}`);
    settings = {...settings, ...extra};
  }
  return settings;
}

const [command, ...args] = process.argv.slice(2);
try {
  switch (command) {
    case 'has':
      process.exitCode = present(at(stdinJson(), args[0])) ? 0 : 1;
      break;
    case 'get': {
      const value = at(stdinJson(), args[0]);
      if (value !== undefined) console.log(typeof value === 'string' ? value : JSON.stringify(value));
      break;
    }
    case 'names': {
      const list = at(stdinJson(), args[0]);
      for (const item of Array.isArray(list) ? list : []) if (item && item.name) console.log(clean(item.name));
      break;
    }
    case 'settings':
      console.log(JSON.stringify(desiredSettings(args[0])));
      break;
    case 'diff': {
      const desired = JSON.parse(args[0]);
      const current = stdinJson();
      for (const [key, value] of Object.entries(desired)) {
        if (JSON.stringify(current[key]) !== JSON.stringify(value)) console.log(key);
      }
      break;
    }
    case 'missing': {
      const installed = new Set((at(stdinJson(), 'result.skills') || []).map(skill => skill.name));
      for (const name of args) if (!installed.has(name)) console.log(name);
      break;
    }
    case 'skills-pending': {
      const plan = at(stdinJson(), 'plan.skills');
      if (!Array.isArray(plan)) throw Error('not a skills install plan');
      const settled = new Set(['keep', 'update', 'leave']);
      for (const name of args) {
        const entry = plan.find(skill => skill && skill.name === name);
        const ops = entry && Array.isArray(entry.ops) ? entry.ops : [];
        if (!entry || ops.some(op => !settled.has(op && op.kind))) console.log(name);
      }
      break;
    }
    case 'release-asset': {
      const release = stdinJson();
      if (release.draft !== false || release.prerelease !== false) throw Error('not a published stable release');
      const pattern = new RegExp(args[0]);
      const assets = (Array.isArray(release.assets) ? release.assets : []).filter(asset => pattern.test(String(asset.name)));
      if (assets.length !== 1) throw Error(`expected one release asset matching ${args[0]}, found ${assets.length}`);
      const [asset] = assets;
      console.log([release.tag_name, asset.name, asset.browser_download_url, asset.digest || '-'].map(clean).join('\t'));
      break;
    }
    default:
      throw Error('Usage: json.cjs has|get|names|settings|diff|missing|skills-pending|release-asset ...');
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 2;
}
