#!/usr/bin/env node
'use strict';
// Read-only readiness audit of agent and cloud configuration.
// Prints names, booleans and auth modes only, never credential values, as one line:
//   READINESS_JSON {...}
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const cp = require('node:child_process');
const {createRequire} = require('node:module');

const home = os.homedir();
const inHome = relative => path.join(home, relative);
const exists = relative => fs.existsSync(inHome(relative));
const has = value => value !== null && value !== undefined && String(value).trim() !== '';
const envReference = /(?:process\.env\.|env\.|\$\{?)([A-Z][A-Z0-9_]+)/g;

function json(relative) {
  try {
    return JSON.parse(fs.readFileSync(inHome(relative), 'utf8'));
  } catch {
    return null;
  }
}

// Runs a command that prints JSON status; only the parsed object is kept, stderr is discarded.
function command(args) {
  try {
    const result = cp.spawnSync(args[0], args.slice(1), {encoding: 'utf8', timeout: 20000, stdio: ['ignore', 'pipe', 'ignore']});
    return {status: result.status, json: JSON.parse(result.stdout || '{}')};
  } catch {
    return {status: null, json: {}};
  }
}

const variables = [
  'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'OPENAI_API_KEY', 'DEEPSEEK_API_KEY', 'GEMINI_API_KEY', 'GOOGLE_API_KEY',
  'GOOGLE_APPLICATION_CREDENTIALS', 'GOOGLE_CLOUD_PROJECT', 'GOOGLE_GENAI_USE_VERTEXAI', 'ARK_API_KEY', 'VOLC_ACCESSKEY',
  'VOLC_SECRETKEY', 'GITHUB_TOKEN', 'GH_TOKEN', 'LINEAR_API_KEY', 'BRAVE_API_KEY', 'TAVILY_API_KEY',
];
const out = {environment: Object.fromEntries(variables.map(name => [name, has(process.env[name])]))};

// Claude Code
const claudeSettings = json('.claude/settings.json') || {};
const claudeAuth = command(['claude', 'auth', 'status', '--json']);
out.claude = {
  statusExit: claudeAuth.status,
  loggedIn: claudeAuth.json.loggedIn,
  authMethod: claudeAuth.json.authMethod,
  apiProvider: claudeAuth.json.apiProvider,
  configuredEnvironment: Object.fromEntries(Object.entries(claudeSettings.env || {})
    .filter(([name]) => variables.includes(name) || name === 'ANTHROPIC_BASE_URL')
    .map(([name, value]) => [name, has(value)])),
  apiKeyHelperConfigured: has(claudeSettings.apiKeyHelper),
  plugins: Object.keys(claudeSettings.enabledPlugins || {}),
  mcpNames: Object.keys((json('.claude.json') || {}).mcpServers || {}),
};

// Gemini
const geminiSettings = json('.gemini/settings.json') || {};
const geminiCreds = json('.gemini/oauth_creds.json');
out.gemini = {
  selectedType: geminiSettings.security?.auth?.selectedType,
  oauthFile: !!geminiCreds,
  hasAccessToken: has(geminiCreds?.access_token),
  hasRefreshToken: has(geminiCreds?.refresh_token),
  accessExpired: geminiCreds?.expiry_date ? geminiCreds.expiry_date < Date.now() : null,
  mcpNames: Object.keys(geminiSettings.mcpServers || {}),
};

// DeepSeek (dsh): YAML is parsed with the js-yaml copy bundled in the dsh package, when available.
let yaml;
for (const pkg of [
  inHome('.local/lib/node_modules/@deepseek-ai/dsh/package.json'),
  '/opt/homebrew/lib/node_modules/@deepseek-ai/dsh/package.json',
  '/usr/local/lib/node_modules/@deepseek-ai/dsh/package.json',
]) {
  try {
    yaml = require(createRequire(pkg).resolve('js-yaml'));
    break;
  } catch {
    // try the next prefix
  }
}
out.dsh = {patchExists: exists('.dsh/cordis.patch.yml'), parserAvailable: !!yaml, credentialFields: [], envReferences: [], providerPlugins: []};

function inspect(value, keys = []) {
  if (!value || typeof value !== 'object') return;
  for (const [key, child] of Object.entries(value)) {
    const trail = [...keys, key];
    if (/api.?key|access.?token|auth.?token|secret|password/i.test(key) && typeof child !== 'object') {
      const refs = typeof child === 'string' ? [...child.matchAll(envReference)].map(m => m[1]) : [];
      out.dsh.credentialFields.push({field: trail.join('.'), configured: has(child), envReferences: refs, referencedEnvPresent: refs.every(n => has(process.env[n]))});
    }
    if (/@deepseek-ai\/.*(?:model|provider|api)/.test(key)) out.dsh.providerPlugins.push(key);
    if (typeof child === 'string') {
      for (const m of child.matchAll(envReference)) out.dsh.envReferences.push({name: m[1], present: has(process.env[m[1]])});
    }
    if (typeof child === 'object') inspect(child, trail);
  }
}

if (yaml && out.dsh.patchExists) {
  try {
    inspect(yaml.load(fs.readFileSync(inHome('.dsh/cordis.patch.yml'), 'utf8')));
  } catch {
    out.dsh.parseFailed = true;
  }
}
out.dsh.credentialStoreExists = exists('.dsh/.credentials.yaml');
out.dsh.homeEnvExists = exists('.dsh/.env');
out.dsh.storedRefs = {};
if (yaml && out.dsh.credentialStoreExists) {
  try {
    const store = yaml.load(fs.readFileSync(inHome('.dsh/.credentials.yaml'), 'utf8'));
    out.dsh.storedRefs = Object.fromEntries(Object.entries(store?.refs || {}).map(([name, value]) => [name, has(value)]));
    out.dsh.grantProviders = Object.keys(store?.records || {});
  } catch {
    out.dsh.storeParseFailed = true;
  }
}
if (out.dsh.homeEnvExists) {
  const text = fs.readFileSync(inHome('.dsh/.env'), 'utf8');
  out.dsh.homeEnvNames = [...text.matchAll(/^\s*(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=/gm)].map(m => m[1]);
}

// Pi
const piAuth = json('.pi/agent/auth.json');
out.pi = {authFile: !!piAuth, providers: Object.keys(piAuth || {})};

// Codex
const codexConfig = exists('.codex/config.toml') ? fs.readFileSync(inHome('.codex/config.toml'), 'utf8') : '';
out.codex = {
  configExists: !!codexConfig,
  authFile: exists('.codex/auth.json'),
  mcpNames: [...codexConfig.matchAll(/^\[mcp_servers\.([^\]]+)\]/gm)].map(m => m[1]).filter(name => !name.endsWith('.env')),
  pluginEntries: [...codexConfig.matchAll(/^\[plugins\.([^\]]+)\]/gm)].map(m => m[1]),
  globalInstructions: exists('.codex/AGENTS.md'),
};

// Cloud and registry configuration: presence only.
out.cloud = {
  gcloudConfig: exists('.config/gcloud'),
  gcloudADC: exists('.config/gcloud/application_default_credentials.json'),
  awsConfig: exists('.aws/config'),
  awsCredentials: exists('.aws/credentials'),
  azureConfig: exists('.azure'),
  dockerConfig: exists('.docker/config.json'),
  npmConfig: exists('.npmrc'),
  ghConfig: exists('.config/gh/hosts.yml'),
};

console.log('READINESS_JSON ' + JSON.stringify(out));
