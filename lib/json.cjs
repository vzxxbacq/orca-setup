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
    default:
      throw Error('Usage: json.cjs has|get|names|settings|diff|missing ...');
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 2;
}
