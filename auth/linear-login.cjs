#!/usr/bin/env node
'use strict';
// A private terminal prompt: the key never appears in process arguments, shell history or output.
// It is passed on stdin to `orca-rpc.sh local linear.connect`, which stores it inside Orca.
const {spawnSync} = require('node:child_process');
const path = require('node:path');
const readline = require('node:readline');
const {Writable} = require('node:stream');

if (!process.stdin.isTTY) {
  console.error('Run in an interactive terminal');
  process.exit(1);
}
process.stdout.write('Paste Linear API key (hidden), then press Enter: ');
const silent = new Writable({write(_chunk, _encoding, callback) { callback(); }});
const rl = readline.createInterface({input: process.stdin, output: silent, terminal: true});
rl.on('SIGINT', () => {
  rl.close();
  process.exit(130);
});
rl.once('line', line => {
  rl.close();
  process.stdout.write('\n');
  const key = line.trim();
  if (!key) {
    process.exitCode = 1;
    return;
  }
  const rpc = path.join(__dirname, '..', 'orca', 'orca-rpc.sh');
  const result = spawnSync('bash', [rpc, 'local', 'linear.connect'], {input: JSON.stringify({apiKey: key}), encoding: 'utf8'});
  if (result.status !== 0) {
    console.error('Linear connection failed. Check the key and network in Orca Settings.');
    process.exitCode = 1;
  } else {
    console.log('Linear connected.');
  }
});
