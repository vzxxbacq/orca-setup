#!/usr/bin/env node
'use strict';
// Calls the local or a paired Orca runtime through the installed Orca's RuntimeClient.
// The client keeps using Orca's own pairing store; no pairing secret is read or exported here.
// Started by orca-rpc.sh, which sets ORCA_RESOURCES_PATH to the app's Resources directory.
const fs = require('node:fs');
const path = require('node:path');

const usage = 'Usage: orca-rpc.cjs local|ENVIRONMENT METHOD [JSON], or ENVIRONMENT upload WORKTREE LOCAL_FILE RELATIVE_PATH';
const uploadLimit = 2 * 1024 * 1024;

function runtimeClient() {
  const resources = process.env.ORCA_RESOURCES_PATH;
  if (!resources) throw Error('ORCA_RESOURCES_PATH is not set; run through orca-rpc.sh');
  return require(path.join(resources, 'app.asar.unpacked/out/cli/runtime-client.js')).RuntimeClient;
}

async function main() {
  const [environment, method, ...args] = process.argv.slice(2);
  if (!environment || !method) throw Error(usage);
  const RuntimeClient = runtimeClient();
  const client = new RuntimeClient(undefined, 30000, null, environment === 'local' ? null : environment);
  if (method === 'upload') {
    const [worktree, file, relativePath] = args;
    if (!worktree || !file || !relativePath || path.isAbsolute(relativePath) || relativePath.split('/').includes('..')) {
      throw Error('Invalid upload arguments');
    }
    const content = fs.readFileSync(file);
    if (content.length > uploadLimit) throw Error('Control-file upload is limited to 2 MiB');
    await client.call('files.writeBase64', {worktree, relativePath, contentBase64: content.toString('base64')});
    console.log(JSON.stringify({uploaded: relativePath, bytes: content.length}));
    return;
  }
  const input = args[0] || (process.stdin.isTTY ? '' : fs.readFileSync(0, 'utf8').trim()) || '{}';
  const reply = await client.call(method, JSON.parse(input));
  console.log(JSON.stringify(reply.result));
}

main().catch(error => {
  console.error(error.message);
  process.exitCode = 1;
});
