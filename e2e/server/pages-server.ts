import * as fs from 'node:fs';
import * as http from 'node:http';
import * as path from 'node:path';
import type { AddressInfo } from 'node:net';

export interface StartPagesServerOptions {
  port?: number;
  host?: string;
  buildDir?: string;
  webDir?: string;
}

export interface PagesServer {
  url: string;
  port: number;
  host: string;
  server: http.Server;
  close: () => Promise<void>;
}

interface HeaderRule {
  pattern: string;
  headers: Array<[string, string]>;
}

interface RedirectRule {
  source: string;
  target: string;
  status: number;
}

const MIME_TYPES: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.map': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.mp4': 'video/mp4',
  '.m4a': 'audio/mp4',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.caf': 'audio/x-caf',
};

function getMimeType(filePath: string): string {
  const ext = path.extname(filePath).toLowerCase();
  return MIME_TYPES[ext] ?? 'application/octet-stream';
}

function parseHeadersFile(filePath: string): HeaderRule[] {
  if (!fs.existsSync(filePath)) return [];
  const raw = fs.readFileSync(filePath, 'utf8');
  const rules: HeaderRule[] = [];
  let current: HeaderRule | null = null;

  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;

    if (!/^\s/.test(line)) {
      current = { pattern: trimmed, headers: [] };
      rules.push(current);
      continue;
    }

    if (current) {
      const colonIdx = trimmed.indexOf(':');
      if (colonIdx > 0) {
        const name = trimmed.slice(0, colonIdx).trim();
        const value = trimmed.slice(colonIdx + 1).trim();
        current.headers.push([name, value]);
      }
    }
  }

  return rules;
}

function parseRedirectsFile(filePath: string): RedirectRule[] {
  if (!fs.existsSync(filePath)) return [];
  const raw = fs.readFileSync(filePath, 'utf8');
  const rules: RedirectRule[] = [];

  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const parts = trimmed.split(/\s+/);
    if (parts.length < 2) continue;
    const source = parts[0];
    const target = parts[1];
    const status = parts[2] ? Number.parseInt(parts[2], 10) || 200 : 200;
    rules.push({ source, target, status });
  }

  return rules;
}

function globToRegExp(pattern: string): RegExp {
  let regexStr = '^';
  for (let i = 0; i < pattern.length; i++) {
    const ch = pattern[i];
    if (ch === '*') {
      regexStr += '.*';
    } else if (ch === ':') {
      // Named segment placeholder like :rev
      let end = i + 1;
      while (end < pattern.length && /[A-Za-z0-9_]/.test(pattern[end])) end++;
      regexStr += '([^/]+)';
      i = end - 1;
    } else {
      regexStr += ch.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    }
  }
  regexStr += '$';
  return new RegExp(regexStr);
}

function matchHeaderPattern(pattern: string, pathname: string): boolean {
  if (pattern === '/*') return true;
  if (pattern === pathname) return true;
  if (pattern.endsWith('/*')) {
    const prefix = pattern.slice(0, -1); // keep trailing '/'
    if (pathname.startsWith(prefix)) return true;
  }
  return globToRegExp(pattern).test(pathname);
}

function applyRedirectRule(rule: RedirectRule, pathname: string): string | null {
  // Exact wildcard fallback handled separately for non-existent files, but still matches pattern
  const paramNames: string[] = [];
  let regexStr = '^';
  for (let i = 0; i < rule.source.length; i++) {
    const ch = rule.source[i];
    if (ch === '*') {
      paramNames.push('splat');
      regexStr += '(.*)';
    } else if (ch === ':') {
      let end = i + 1;
      while (end < rule.source.length && /[A-Za-z0-9_]/.test(rule.source[end])) end++;
      paramNames.push(rule.source.slice(i + 1, end));
      regexStr += '([^/]+)';
      i = end - 1;
    } else {
      regexStr += ch.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    }
  }
  regexStr += '$';

  const match = new RegExp(regexStr).exec(pathname);
  if (!match) return null;

  let resolved = rule.target;
  paramNames.forEach((name, idx) => {
    const val = match[idx + 1] ?? '';
    resolved = resolved.replaceAll(`:${name}`, val);
  });
  if (!resolved.startsWith('/')) resolved = `/${resolved}`;
  return resolved;
}

function resolveSafePath(rootDir: string, urlPath: string): string | null {
  let decoded: string;
  try {
    decoded = decodeURIComponent(urlPath);
  } catch {
    return null;
  }
  const rel = decoded.replace(/^\/+/, '');
  const resolved = path.resolve(rootDir, rel);
  const normalizedRoot = path.resolve(rootDir);
  if (resolved !== normalizedRoot && !resolved.startsWith(normalizedRoot + path.sep)) {
    return null;
  }
  return resolved;
}

function parseByteRange(rangeHeader: string, totalSize: number): { start: number; end: number } | 'unsatisfiable' | null {
  if (!rangeHeader.startsWith('bytes=')) return null;
  const spec = rangeHeader.slice('bytes='.length).split(',')[0].trim();
  const dashIdx = spec.indexOf('-');
  if (dashIdx === -1) return null;

  const startStr = spec.slice(0, dashIdx).trim();
  const endStr = spec.slice(dashIdx + 1).trim();

  if (startStr === '' && endStr === '') return 'unsatisfiable';

  let start: number;
  let end: number;

  if (startStr === '') {
    const suffixLen = Number.parseInt(endStr, 10);
    if (!Number.isFinite(suffixLen) || suffixLen <= 0) return 'unsatisfiable';
    start = Math.max(0, totalSize - suffixLen);
    end = totalSize - 1;
  } else {
    start = Number.parseInt(startStr, 10);
    end = endStr === '' ? totalSize - 1 : Number.parseInt(endStr, 10);
    if (!Number.isFinite(start) || !Number.isFinite(end) || start < 0 || start >= totalSize || end < start) {
      return 'unsatisfiable';
    }
    end = Math.min(end, totalSize - 1);
  }

  return { start, end };
}

export async function startPagesServer(options: StartPagesServerOptions = {}): Promise<PagesServer> {
  const host = options.host ?? '127.0.0.1';
  const port = options.port ?? 0;
  const buildDir = path.resolve(options.buildDir ?? path.resolve(__dirname, '../../build/web'));
  const webDir = path.resolve(options.webDir ?? path.resolve(__dirname, '../../web'));

  const headerRules = parseHeadersFile(path.join(webDir, '_headers'));
  const redirectRules = parseRedirectsFile(path.join(webDir, '_redirects'));

  const server = http.createServer((req, res) => {
    const method = (req.method ?? 'GET').toUpperCase();
    if (method !== 'GET' && method !== 'HEAD') {
      res.writeHead(405, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Method Not Allowed');
      return;
    }

    const reqUrl = new URL(req.url ?? '/', `http://${host}`);
    const origPathname = reqUrl.pathname;

    // Apply specific rewrite rules (non-catch-all like /_a/:rev/* -> /:splat) before disk lookup
    let diskPathname = origPathname;
    for (const rule of redirectRules) {
      if (rule.source === '/*') continue;
      const rewritten = applyRedirectRule(rule, diskPathname);
      if (rewritten) {
        diskPathname = rewritten;
        break;
      }
    }

    if (diskPathname === '/') {
      diskPathname = '/index.html';
    }

    let filePath = resolveSafePath(buildDir, diskPathname);
    if (!filePath) {
      res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Forbidden');
      return;
    }

    let stat: fs.Stats | null = null;
    try {
      stat = fs.statSync(filePath);
      if (stat.isDirectory()) {
        const indexInDir = path.join(filePath, 'index.html');
        if (fs.existsSync(indexInDir)) {
          filePath = indexInDir;
          stat = fs.statSync(filePath);
        } else {
          stat = null;
        }
      }
    } catch {
      stat = null;
    }

    // Catch-all SPA fallback from _redirects (e.g., /* /index.html 200)
    if (!stat) {
      const spaRule = redirectRules.find((r) => r.source === '/*');
      if (spaRule) {
        const fallbackPath = resolveSafePath(buildDir, spaRule.target);
        if (fallbackPath && fs.existsSync(fallbackPath)) {
          filePath = fallbackPath;
          stat = fs.statSync(filePath);
        }
      }
    }

    if (!stat || !stat.isFile()) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Not Found');
      return;
    }

    // Collect headers: _headers rules match against the original request pathname (e.g. /_a/*)
    const headersMap = new Map<string, string>();
    const canonicalNames = new Map<string, string>();
    const setHeader = (name: string, val: string) => {
      const lower = name.toLowerCase();
      canonicalNames.set(lower, name);
      headersMap.set(lower, val);
    };

    for (const rule of headerRules) {
      if (matchHeaderPattern(rule.pattern, origPathname)) {
        for (const [k, v] of rule.headers) {
          setHeader(k, v);
        }
      }
    }

    setHeader('Content-Type', getMimeType(filePath));
    setHeader('Accept-Ranges', 'bytes');

    const totalSize = stat.size;
    const rangeHeader = req.headers.range;
    let statusCode = 200;
    let start = 0;
    let end = totalSize - 1;

    if (typeof rangeHeader === 'string') {
      const parsed = parseByteRange(rangeHeader, totalSize);
      if (parsed === 'unsatisfiable') {
        const outHeaders: Record<string, string> = {
          'Content-Range': `bytes */${totalSize}`,
        };
        for (const [lower, val] of headersMap) {
          outHeaders[canonicalNames.get(lower)!] = val;
        }
        res.writeHead(416, outHeaders);
        res.end();
        return;
      }
      if (parsed) {
        statusCode = 206;
        start = parsed.start;
        end = parsed.end;
        setHeader('Content-Range', `bytes ${start}-${end}/${totalSize}`);
      }
    }

    const contentLength = totalSize === 0 ? 0 : end - start + 1;
    setHeader('Content-Length', String(contentLength));

    const outHeaders: Record<string, string> = {};
    for (const [lower, val] of headersMap) {
      outHeaders[canonicalNames.get(lower)!] = val;
    }

    res.writeHead(statusCode, outHeaders);
    if (method === 'HEAD' || contentLength === 0) {
      res.end();
      return;
    }

    const stream = fs.createReadStream(filePath, { start, end });
    stream.on('error', () => {
      if (!res.headersSent) res.writeHead(500);
      res.end();
    });
    stream.pipe(res);
  });

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => {
      server.off('error', reject);
      resolve();
    });
  });

  const addr = server.address() as AddressInfo;
  const actualHost = addr.address === '::' ? '127.0.0.1' : addr.address;
  const actualPort = addr.port;
  const url = `http://${actualHost}:${actualPort}`;

  return {
    url,
    port: actualPort,
    host: actualHost,
    server,
    close: () =>
      new Promise<void>((resolve, reject) => {
        server.close((err) => (err ? reject(err) : resolve()));
      }),
  };
}
