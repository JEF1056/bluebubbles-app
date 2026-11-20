import * as http from 'node:http';
import type { AddressInfo } from 'node:net';
import { Server as SocketIOServer, type Socket } from 'socket.io';
import {
  DEFAULT_PASSWORD,
  SAMPLE_M4A_BYTES,
  SAMPLE_MP4_BYTES,
  SAMPLE_PNG_BYTES,
  createDefaultSeed,
  makeAttachment,
  makeChat,
  makeFaceTimeSession,
  makeHandle,
  makeMessage,
  type AttachmentFixture,
  type ChatFixture,
  type ContactFixture,
  type FaceTimeSessionFixture,
  type FindMyDeviceFixture,
  type FindMyFriendFixture,
  type HandleFixture,
  type MessageFixture,
  type MockSeed,
} from './fixtures-data';

export interface RecordedRequest {
  method: string;
  path: string;
  query: Record<string, string>;
  headers: http.IncomingHttpHeaders;
  body: any;
  files?: Record<string, { filename: string; contentType: string; data: Buffer }>;
  timestamp: number;
}

export interface RouteOverrideResult {
  status?: number;
  headers?: Record<string, string>;
  body?: unknown;
}

export type RouteOverrideHandler =
  | RouteOverrideResult
  | ((req: RecordedRequest) => RouteOverrideResult | Promise<RouteOverrideResult>);

export interface StartMockBBServerOptions {
  port?: number;
  host?: string;
  password?: string;
  seed?: MockSeed;
}

interface PendingFault {
  method: string;
  matcher: string | RegExp;
  status: number;
  body: unknown;
}

interface RouteOverrideEntry {
  method: string;
  matcher: string | RegExp;
  handler: RouteOverrideHandler;
}

interface RequestWaiter {
  method: string;
  matcher: string | RegExp;
  resolve: (req: RecordedRequest) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
}

function matchesRoute(method: string, matcher: string | RegExp, reqMethod: string, reqPath: string): boolean {
  if (method !== '*' && method.toUpperCase() !== reqMethod.toUpperCase()) return false;
  if (typeof matcher === 'string') {
    return reqPath === matcher || reqPath.startsWith(matcher + '/');
  }
  return matcher.test(reqPath);
}

function matchesExactOrRegex(method: string, matcher: string | RegExp, reqMethod: string, reqPath: string): boolean {
  if (method !== '*' && method.toUpperCase() !== reqMethod.toUpperCase()) return false;
  if (typeof matcher === 'string') return reqPath === matcher;
  return matcher.test(reqPath);
}

function stripAttachmentBytes(att: AttachmentFixture): Omit<AttachmentFixture, 'bytes'> {
  const { bytes: _bytes, ...rest } = att;
  return rest;
}

function serializeMessage(msg: MessageFixture, chat?: ChatFixture): Record<string, unknown> {
  const out: Record<string, unknown> = {
    ...msg,
    attachments: (msg.attachments ?? []).map(stripAttachmentBytes),
  };
  if (chat) {
    const { lastMessage: _lm, ...chatWithoutLast } = chat;
    out.chats = [{ ...chatWithoutLast }];
  }
  return out;
}

function serializeChat(chat: ChatFixture): Record<string, unknown> {
  return {
    ...chat,
    lastMessage: chat.lastMessage ? serializeMessage(chat.lastMessage) : null,
  };
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

function parseMultipart(
  rawBody: Buffer,
  boundary: string,
): { fields: Record<string, string>; files: Record<string, { filename: string; contentType: string; data: Buffer }> } {
  const fields: Record<string, string> = {};
  const files: Record<string, { filename: string; contentType: string; data: Buffer }> = {};
  const delimiter = Buffer.from(`--${boundary}`);
  const crlfCrlf = Buffer.from('\r\n\r\n');

  let pos = rawBody.indexOf(delimiter);
  while (pos !== -1) {
    const nextPos = rawBody.indexOf(delimiter, pos + delimiter.length);
    if (nextPos === -1) break;

    // Slice part between `--boundary\r\n` and `\r\n--boundary`
    let partStart = pos + delimiter.length;
    if (rawBody[partStart] === 0x0d && rawBody[partStart + 1] === 0x0a) {
      partStart += 2;
    }
    let partEnd = nextPos;
    if (partEnd >= 2 && rawBody[partEnd - 2] === 0x0d && rawBody[partEnd - 1] === 0x0a) {
      partEnd -= 2;
    }

    const part = rawBody.subarray(partStart, partEnd);
    const headerEnd = part.indexOf(crlfCrlf);
    if (headerEnd !== -1) {
      const headerStr = part.subarray(0, headerEnd).toString('utf8');
      const bodyBuf = part.subarray(headerEnd + 4);
      const dispMatch = /name="([^"]+)"/i.exec(headerStr);
      const filenameMatch = /filename="([^"]*)"/i.exec(headerStr);
      const ctMatch = /content-type:\s*([^\r\n]+)/i.exec(headerStr);
      const fieldName = dispMatch?.[1];

      if (fieldName) {
        if (filenameMatch) {
          files[fieldName] = {
            filename: filenameMatch[1] || 'upload.bin',
            contentType: ctMatch?.[1]?.trim() || 'application/octet-stream',
            data: Buffer.from(bodyBuf),
          };
        } else {
          fields[fieldName] = bodyBuf.toString('utf8');
        }
      }
    }

    pos = nextPos;
  }

  return { fields, files };
}

async function readRawBody(req: http.IncomingMessage): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) {
    chunks.push(typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
  }
  return Buffer.concat(chunks);
}

function applyCorsHeaders(
  req: http.IncomingMessage,
  res: http.ServerResponse | Record<string, string | string[]>,
): void {
  const origin = req.headers.origin;
  const reqHeaders = req.headers['access-control-request-headers'];
  const allowOrigin = typeof origin === 'string' && origin.length > 0 ? origin : '*';
  const allowHeaders =
    typeof reqHeaders === 'string' && reqHeaders.length > 0
      ? reqHeaders
      : 'Content-Type, Authorization, X-Requested-With, Range, Accept, X-Guid';

  const pairs: Record<string, string> = {
    'Access-Control-Allow-Origin': allowOrigin,
    Vary: 'Origin',
    'Access-Control-Allow-Credentials': 'true',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': allowHeaders,
    'Access-Control-Expose-Headers': 'Content-Length, Content-Range, Accept-Ranges',
    'Cross-Origin-Resource-Policy': 'cross-origin',
  };

  if (typeof (res as http.ServerResponse).setHeader === 'function') {
    const serverRes = res as http.ServerResponse;
    for (const [k, v] of Object.entries(pairs)) {
      serverRes.setHeader(k, v);
    }
  } else {
    const headerBag = res as Record<string, string | string[]>;
    for (const [k, v] of Object.entries(pairs)) {
      headerBag[k] = v;
    }
  }
}

export class MockBBServer {
  readonly url: string;
  readonly port: number;
  readonly host: string;
  password: string;
  readonly seed: MockSeed;
  readonly httpServer: http.Server;
  readonly io: SocketIOServer;
  readonly requests: RecordedRequest[] = [];

  private pendingFaults: PendingFault[] = [];
  private routeOverrides: RouteOverrideEntry[] = [];
  private waiters: RequestWaiter[] = [];
  private socketWaiters: Array<{ resolve: (socket: Socket) => void; reject: (err: Error) => void; timer: NodeJS.Timeout }> = [];
  private sockets = new Set<Socket>();
  private rejectSocketsFlag = false;
  private uploadedBlobs = new Map<string, { filename: string; contentType: string; data: Buffer }>();
  private chatIcons = new Map<string, Buffer>();
  private chatBackgrounds = new Map<string, Buffer>();
  private fcmClientConfig: Record<string, unknown> = {
    apiKey: 'mock-fcm-api-key',
    projectId: 'mock-bb-project',
    appId: '1:000000000000:web:mock',
    messagingSenderId: '000000000000',
  };
  private registeredFcmDevices: Array<Record<string, unknown>> = [];
  private seq = 1000;

  constructor(opts: {
    url: string;
    port: number;
    host: string;
    password: string;
    seed: MockSeed;
    httpServer: http.Server;
    io: SocketIOServer;
  }) {
    this.url = opts.url;
    this.port = opts.port;
    this.host = opts.host;
    this.password = opts.password;
    this.seed = opts.seed;
    this.httpServer = opts.httpServer;
    this.io = opts.io;
    this.setupSocketIO();
  }

  private nextSeq(): number {
    this.seq += 1;
    return this.seq;
  }

  private setupSocketIO(): void {
    // Ensure Engine.IO polling responses carry COEP-safe CORS & CORP headers
    this.io.engine.on('headers', (headers: Record<string, string | string[]>, req: http.IncomingMessage) => {
      applyCorsHeaders(req, headers);
    });

    this.io.use((socket, next) => {
      if (this.rejectSocketsFlag) {
        return next(new Error('Socket rejected by fault injection'));
      }
      const queryGuid = socket.handshake.query?.guid;
      const authGuid = (socket.handshake.auth as Record<string, unknown> | undefined)?.guid;
      const guid = typeof queryGuid === 'string' ? queryGuid : typeof authGuid === 'string' ? authGuid : '';
      if (guid !== this.password) {
        return next(new Error('Unauthorized'));
      }
      return next();
    });

    this.io.on('connection', (socket) => {
      this.sockets.add(socket);

      // Wake any waitForSocket() callers
      while (this.socketWaiters.length > 0) {
        const w = this.socketWaiters.shift()!;
        clearTimeout(w.timer);
        w.resolve(socket);
      }

      socket.on('get-fcm-client', (_payload: unknown, ack?: (resp: unknown) => void) => {
        if (typeof ack === 'function') {
          ack({ status: 200, message: 'Success', data: this.fcmClientConfig });
        }
      });

      socket.on('disconnect', () => {
        this.sockets.delete(socket);
      });
    });
  }

  // ── Request Log & Fault Injection ─────────────────────────────────────────

  getRequests(method?: string, pathPrefix?: string): RecordedRequest[] {
    return this.requests.filter((r) => {
      if (method && r.method.toUpperCase() !== method.toUpperCase()) return false;
      if (pathPrefix && !r.path.startsWith(pathPrefix)) return false;
      return true;
    });
  }

  waitForRequest(method: string, pathOrPattern: string | RegExp, timeoutMs = 15_000): Promise<RecordedRequest> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((w) => w !== waiter);
        reject(new Error(`Timed out waiting for ${method} ${String(pathOrPattern)} after ${timeoutMs}ms`));
      }, timeoutMs);

      const waiter: RequestWaiter = { method, matcher: pathOrPattern, resolve, reject, timer };
      this.waiters.push(waiter);
    });
  }

  clearRequests(): void {
    this.requests.length = 0;
  }

  failNext(method: string, pathOrPattern: string | RegExp, statusCode: number, body?: unknown): void {
    this.pendingFaults.push({
      method,
      matcher: pathOrPattern,
      status: statusCode,
      body: body ?? {
        status: statusCode,
        message: 'Injected failure',
        error: { type: 'MockFaultError', message: `Injected HTTP ${statusCode}` },
      },
    });
  }

  setRouteOverride(method: string, pathOrPattern: string | RegExp, handler: RouteOverrideHandler): void {
    this.routeOverrides.push({ method, matcher: pathOrPattern, handler });
  }

  clearOverrides(): void {
    this.pendingFaults.length = 0;
    this.routeOverrides.length = 0;
  }

  setPassword(newPassword: string): void {
    this.password = newPassword;
  }

  // ── Offline Seed Mutators ─────────────────────────────────────────────────

  addChat(partial: Partial<ChatFixture> & { guid?: string } = {}): ChatFixture {
    const chat = makeChat(partial);
    this.seed.chats.unshift(chat);
    if (!this.seed.messagesByChat[chat.guid]) {
      this.seed.messagesByChat[chat.guid] = [];
    }
    if (chat.lastMessage) {
      chat.lastMessage.chatGuid = chat.guid;
      this.seed.messagesByChat[chat.guid].push(chat.lastMessage);
    }
    return chat;
  }

  addMessage(chatGuid: string, partial: Partial<MessageFixture> = {}): MessageFixture {
    const chat = this.findChat(chatGuid);
    const id = partial.originalROWID ?? this.nextSeq();
    const defaultHandle = !partial.isFromMe ? (partial.handle ?? chat?.participants[0] ?? null) : null;
    const msg = makeMessage({
      originalROWID: id,
      id,
      chatGuid,
      handle: defaultHandle,
      handleId: defaultHandle?.originalROWID ?? 0,
      dateCreated: partial.dateCreated ?? Date.now(),
      ...partial,
    });
    const list = (this.seed.messagesByChat[chatGuid] ??= []);
    list.push(msg);
    if (chat) {
      chat.lastMessage = msg;
    }
    return msg;
  }

  addFindMyDevice(device: Partial<FindMyDeviceFixture>): FindMyDeviceFixture {
    const idx = this.seed.findMyDevices.findIndex((d) => d.id === device.id);
    if (idx !== -1) {
      this.seed.findMyDevices[idx] = { ...this.seed.findMyDevices[idx], ...device } as FindMyDeviceFixture;
      return this.seed.findMyDevices[idx];
    }
    const created: FindMyDeviceFixture = {
      ...this.seed.findMyDevices[0],
      ...device,
      id: device.id ?? `device-${this.nextSeq()}`,
    };
    this.seed.findMyDevices.push(created);
    return created;
  }

  addFindMyFriend(friend: Partial<FindMyFriendFixture>): FindMyFriendFixture {
    const created: FindMyFriendFixture = {
      ...this.seed.findMyFriends[0],
      ...friend,
    };
    this.seed.findMyFriends.push(created);
    return created;
  }

  // ── Live Socket.IO Emitters & Controls ────────────────────────────────────

  emitNewMessage(chatGuid: string, partial: Partial<MessageFixture> = {}): MessageFixture {
    const chat = this.findChat(chatGuid);
    const msg = this.addMessage(chatGuid, partial);
    const data = serializeMessage(msg, chat ?? makeChat({ guid: chatGuid }));
    this.io.emit('new-message', { status: 200, message: 'New message', data });
    return msg;
  }

  emitUpdatedMessage(chatGuid: string, msgOrPatch: Partial<MessageFixture> & { guid: string }): MessageFixture {
    const chat = this.findChat(chatGuid);
    const list = this.seed.messagesByChat[chatGuid] ?? [];
    const existing = list.find((m) => m.guid === msgOrPatch.guid);
    const updated: MessageFixture = existing
      ? Object.assign(existing, msgOrPatch)
      : makeMessage({ chatGuid, ...msgOrPatch });
    const data = serializeMessage(updated, chat ?? makeChat({ guid: chatGuid }));
    this.io.emit('updated-message', { status: 200, message: 'Updated message', data });
    return updated;
  }

  emitTyping(chatGuid: string, display: boolean): void {
    this.io.emit('typing-indicator', { guid: chatGuid, display });
  }

  emitChatReadStatus(chatGuid: string, read: boolean, readAt?: number): void {
    const chat = this.findChat(chatGuid);
    if (chat) chat.hasUnreadMessage = !read;
    this.io.emit('chat-read-status-changed', {
      chatGuid,
      read,
      status: read,
      readAt: readAt ?? Date.now(),
    });
  }

  emitPinnedChats(guids: string[]): void {
    for (const chat of this.seed.chats) {
      const idx = guids.indexOf(chat.guid);
      chat.isPinned = idx !== -1;
      chat.pinIndex = idx !== -1 ? idx : null;
    }
    this.io.emit('pinned-chats-updated', { pinnedChatGuids: guids });
  }

  emitGroupNameChange(chatGuid: string, displayName: string): void {
    const chat = this.findChat(chatGuid);
    if (chat) {
      chat.displayName = displayName;
      this.io.emit('group-name-change', { chats: [serializeChat(chat)] });
    }
  }

  emitParticipantEvent(
    event: 'participant-added' | 'participant-removed' | 'participant-left',
    chatGuid: string,
    handle: HandleFixture,
  ): void {
    const chat = this.findChat(chatGuid);
    if (!chat) return;
    if (event === 'participant-added') {
      if (!chat.participants.some((p) => p.address === handle.address)) {
        chat.participants.push(handle);
      }
    } else {
      chat.participants = chat.participants.filter((p) => p.address !== handle.address);
    }
    this.io.emit(event, { chats: [serializeChat(chat)] });
  }

  emitFindMyFriend(friend: FindMyFriendFixture): void {
    const handleAddr = typeof friend.handle === 'string' ? friend.handle : friend.handle?.address;
    const idx = this.seed.findMyFriends.findIndex((f) => {
      const addr = typeof f.handle === 'string' ? f.handle : f.handle?.address;
      return addr === handleAddr;
    });
    if (idx !== -1) this.seed.findMyFriends[idx] = friend;
    else this.seed.findMyFriends.push(friend);
    this.io.emit('new-findmy-location', friend);
  }

  emitFindMyDevice(device: FindMyDeviceFixture): void {
    const idx = this.seed.findMyDevices.findIndex((d) => d.id === device.id);
    if (idx !== -1) this.seed.findMyDevices[idx] = device;
    else this.seed.findMyDevices.push(device);
    this.io.emit('new-findmy-device', device);
  }

  emitIncomingFaceTime(session: Partial<FaceTimeSessionFixture> & { caller?: string }): void {
    if (session.caller && !session.uuid) {
      this.io.emit('incoming-facetime', JSON.stringify({ caller: session.caller }));
      return;
    }
    const full = makeFaceTimeSession({ status_id: 4, status: 'incoming', ...session });
    this.upsertFaceTimeSession(full);
    this.io.emit('ft-call-status-changed', full);
  }

  emitFaceTimeStatus(session: Partial<FaceTimeSessionFixture> & { uuid: string }): void {
    const existing = this.seed.faceTimeSessions.find((s) => s.uuid === session.uuid);
    const full = makeFaceTimeSession({ ...(existing ?? {}), ...session });
    this.upsertFaceTimeSession(full);
    this.io.emit('ft-call-status-changed', full);
  }

  disconnectSockets(serverInitiated = true): void {
    for (const socket of this.sockets) {
      socket.disconnect(serverInitiated);
    }
  }

  rejectSockets(reject: boolean): void {
    this.rejectSocketsFlag = reject;
  }

  connectedSocketCount(): number {
    return this.sockets.size;
  }

  waitForSocket(timeoutMs = 15_000): Promise<Socket> {
    const existing = this.sockets.values().next().value;
    if (existing && existing.connected) {
      return Promise.resolve(existing);
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.socketWaiters = this.socketWaiters.filter((w) => w !== waiter);
        reject(new Error(`Timed out waiting for Socket.IO client after ${timeoutMs}ms`));
      }, timeoutMs);
      const waiter = { resolve, reject, timer };
      this.socketWaiters.push(waiter);
    });
  }

  async close(): Promise<void> {
    for (const w of this.waiters) {
      clearTimeout(w.timer);
      w.reject(new Error('MockBBServer closed'));
    }
    this.waiters.length = 0;

    for (const w of this.socketWaiters) {
      clearTimeout(w.timer);
      w.reject(new Error('MockBBServer closed'));
    }
    this.socketWaiters.length = 0;

    this.disconnectSockets(true);
    await new Promise<void>((resolve) => {
      this.io.close(() => resolve());
    });
    await new Promise<void>((resolve) => {
      this.httpServer.close(() => resolve());
    });
  }

  // ── Internal HTTP Request Handler ─────────────────────────────────────────

  async handleHttpRequest(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    applyCorsHeaders(req, res);

    const method = (req.method ?? 'GET').toUpperCase();
    if (method === 'OPTIONS') {
      res.writeHead(204);
      res.end();
      return;
    }

    const reqUrl = new URL(req.url ?? '/', this.url);
    const pathname = reqUrl.pathname;

    // Socket.IO handles /socket.io/* via its own listener attached to httpServer
    if (pathname.startsWith('/socket.io')) return;

    const rawBody = await readRawBody(req);
    const contentType = (req.headers['content-type'] ?? '').toLowerCase();
    let body: any = undefined;
    let files: RecordedRequest['files'] = undefined;

    if (rawBody.length > 0) {
      if (contentType.includes('multipart/form-data')) {
        const boundaryMatch = /boundary=(?:"([^"]+)"|([^;\s]+))/i.exec(req.headers['content-type'] ?? '');
        const boundary = boundaryMatch?.[1] ?? boundaryMatch?.[2];
        if (boundary) {
          const parsed = parseMultipart(rawBody, boundary);
          body = parsed.fields;
          files = parsed.files;
        }
      } else if (contentType.includes('application/x-www-form-urlencoded')) {
        body = Object.fromEntries(new URLSearchParams(rawBody.toString('utf8')).entries());
      } else {
        const text = rawBody.toString('utf8');
        try {
          body = JSON.parse(text);
        } catch {
          body = text;
        }
      }
    }

    const query: Record<string, string> = {};
    for (const [k, v] of reqUrl.searchParams.entries()) {
      query[k] = v;
    }

    const recorded: RecordedRequest = {
      method,
      path: pathname,
      query,
      headers: req.headers,
      body,
      ...(files ? { files } : {}),
      timestamp: Date.now(),
    };

    this.requests.push(recorded);
    this.notifyRequestWaiters(recorded);

    // 1. One-shot fault injection
    const faultIdx = this.pendingFaults.findIndex((f) => matchesExactOrRegex(f.method, f.matcher, method, pathname));
    if (faultIdx !== -1) {
      const [fault] = this.pendingFaults.splice(faultIdx, 1);
      this.sendJson(res, fault.status, fault.body);
      return;
    }

    // 2. Persistent route overrides
    const override = this.routeOverrides.find((o) => matchesExactOrRegex(o.method, o.matcher, method, pathname));
    if (override) {
      const result = typeof override.handler === 'function' ? await override.handler(recorded) : override.handler;
      const status = result.status ?? 200;
      if (result.headers) {
        for (const [k, v] of Object.entries(result.headers)) {
          res.setHeader(k, v);
        }
      }
      if (Buffer.isBuffer(result.body)) {
        res.setHeader('Content-Length', String(result.body.byteLength));
        res.writeHead(status);
        res.end(method === 'HEAD' ? undefined : result.body);
      } else {
        this.sendJson(res, status, result.body ?? { status, message: 'Override' });
      }
      return;
    }

    // 3. Auth check for /api/v1/* and /api/v2/*
    if (pathname.startsWith('/api/v1/') || pathname.startsWith('/api/v2/')) {
      if (pathname === '/api/v1/login' || pathname === '/api/v1/server/login') {
        const supplied = String(body?.password ?? query.guid ?? '');
        if (supplied !== this.password) {
          this.sendError(res, 401, 'Authentication Error', 'Invalid server password');
          return;
        }
        this.sendSuccess(res, { authenticated: true });
        return;
      }

      const authHeader = req.headers.authorization;
      const bearer = typeof authHeader === 'string' && authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
      const xGuid = typeof req.headers['x-guid'] === 'string' ? req.headers['x-guid'] : '';
      const suppliedGuid = query.guid ?? bearer ?? xGuid ?? '';

      if (suppliedGuid !== this.password) {
        this.sendError(res, 401, 'Authentication Error', 'Invalid or missing guid parameter');
        return;
      }
    }

    this.dispatchApiRoute(req, res, method, pathname, query, body, files);
  }

  private notifyRequestWaiters(req: RecordedRequest): void {
    const remaining: RequestWaiter[] = [];
    for (const waiter of this.waiters) {
      if (matchesExactOrRegex(waiter.method, waiter.matcher, req.method, req.path)) {
        clearTimeout(waiter.timer);
        waiter.resolve(req);
      } else {
        remaining.push(waiter);
      }
    }
    this.waiters = remaining;
  }

  private sendJson(res: http.ServerResponse, status: number, payload: unknown): void {
    const buf = Buffer.from(JSON.stringify(payload));
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader('Content-Length', String(buf.byteLength));
    res.writeHead(status);
    res.end(buf);
  }

  private sendSuccess(res: http.ServerResponse, data: unknown = null, metadata?: Record<string, unknown>): void {
    this.sendJson(res, 200, {
      status: 200,
      message: 'Success',
      data,
      ...(metadata ? { metadata } : {}),
    });
  }

  private sendError(res: http.ServerResponse, status: number, type: string, message: string): void {
    this.sendJson(res, status, {
      status,
      message,
      error: { type, message },
    });
  }

  private sendBinary(
    req: http.IncomingMessage,
    res: http.ServerResponse,
    buf: Buffer,
    contentType: string,
    filename?: string,
  ): void {
    res.setHeader('Content-Type', contentType);
    res.setHeader('Accept-Ranges', 'bytes');
    if (filename) {
      res.setHeader('Content-Disposition', `inline; filename="${filename.replace(/"/g, '')}"`);
    }

    const totalSize = buf.byteLength;
    const rangeHeader = req.headers.range;
    let status = 200;
    let slice = buf;

    if (typeof rangeHeader === 'string') {
      const parsed = parseByteRange(rangeHeader, totalSize);
      if (parsed === 'unsatisfiable') {
        res.setHeader('Content-Range', `bytes */${totalSize}`);
        res.writeHead(416);
        res.end();
        return;
      }
      if (parsed) {
        status = 206;
        slice = buf.subarray(parsed.start, parsed.end + 1);
        res.setHeader('Content-Range', `bytes ${parsed.start}-${parsed.end}/${totalSize}`);
      }
    }

    res.setHeader('Content-Length', String(slice.byteLength));
    res.writeHead(status);
    res.end((req.method ?? 'GET').toUpperCase() === 'HEAD' ? undefined : slice);
  }

  private findChat(guid: string): ChatFixture | undefined {
    return this.seed.chats.find((c) => c.guid === guid);
  }

  private allMessages(): MessageFixture[] {
    const all: MessageFixture[] = [];
    for (const [chatGuid, list] of Object.entries(this.seed.messagesByChat)) {
      for (const m of list) {
        if (!m.chatGuid) m.chatGuid = chatGuid;
        all.push(m);
      }
    }
    return all;
  }

  private findMessage(guid: string): { chatGuid: string; message: MessageFixture } | undefined {
    for (const [chatGuid, list] of Object.entries(this.seed.messagesByChat)) {
      const found = list.find((m) => m.guid === guid);
      if (found) return { chatGuid, message: found };
    }
    return undefined;
  }

  private findAttachment(guid: string): AttachmentFixture | undefined {
    for (const list of Object.values(this.seed.messagesByChat)) {
      for (const msg of list) {
        const found = msg.attachments?.find((a) => a.guid === guid);
        if (found) return found;
      }
    }
    return undefined;
  }

  private findOrCreateHandle(address: string, service = 'iMessage'): HandleFixture {
    const existing = this.seed.handles.find((h) => h.address === address && h.service === service)
      ?? this.seed.handles.find((h) => h.address === address);
    if (existing) return existing;
    const h = makeHandle({ originalROWID: this.nextSeq(), address, service });
    this.seed.handles.push(h);
    return h;
  }

  private upsertFaceTimeSession(session: FaceTimeSessionFixture): void {
    const idx = this.seed.faceTimeSessions.findIndex((s) => s.uuid === session.uuid);
    if (idx !== -1) this.seed.faceTimeSessions[idx] = session;
    else this.seed.faceTimeSessions.push(session);
  }

  private dispatchApiRoute(
    req: http.IncomingMessage,
    res: http.ServerResponse,
    method: string,
    pathname: string,
    query: Record<string, string>,
    body: any,
    files?: RecordedRequest['files'],
  ): void {
    // ── Server & FCM & Stats ────────────────────────────────────────────────
    if (method === 'GET' && (pathname === '/api/v1/ping' || pathname === '/api/v1/server/ping')) {
      this.sendSuccess(res, 'pong');
      return;
    }
    if (method === 'GET' && pathname === '/api/v1/server/info') {
      this.sendSuccess(res, this.seed.serverInfo);
      return;
    }
    if (method === 'GET' && pathname === '/api/v2/server/subscription') {
      this.sendSuccess(res, { tier: 'pro', active: true });
      return;
    }
    if (
      (method === 'GET' && (pathname === '/api/v1/server/restart/soft' || pathname === '/api/v1/server/restart/hard' || pathname === '/api/v1/server/update/check')) ||
      (method === 'POST' && (pathname === '/api/v1/server/update/install' || pathname === '/api/v1/mac/lock' || pathname === '/api/v1/mac/imessage/restart'))
    ) {
      this.sendSuccess(res, { ok: true, available: false });
      return;
    }
    if (method === 'GET' && pathname === '/api/v1/server/statistics/totals') {
      const totalMessages = this.allMessages().length;
      const totalAttachments = this.allMessages().reduce((sum, m) => sum + (m.attachments?.length ?? 0), 0);
      this.sendSuccess(res, {
        handles: this.seed.handles.length,
        messages: totalMessages,
        chats: this.seed.chats.length,
        attachments: totalAttachments,
      });
      return;
    }
    if (method === 'GET' && (pathname === '/api/v1/server/statistics/media' || pathname === '/api/v1/server/statistics/media/chat')) {
      this.sendSuccess(res, { images: 1, videos: 0, locations: 0 });
      return;
    }
    if (method === 'GET' && pathname === '/api/v1/server/logs') {
      this.sendSuccess(res, 'Mock BlueBubbles Server log output');
      return;
    }
    if (method === 'POST' && pathname === '/api/v1/fcm/device') {
      this.registeredFcmDevices.push(body ?? {});
      this.sendSuccess(res, body ?? {});
      return;
    }
    if (method === 'GET' && pathname === '/api/v1/fcm/client') {
      this.sendSuccess(res, this.fcmClientConfig);
      return;
    }

    // ── Chats ───────────────────────────────────────────────────────────────
    if (method === 'GET' && pathname === '/api/v1/chat/count') {
      const activeChats = this.seed.chats.filter((c) => !c.dateDeleted);
      const breakdown: Record<string, number> = {};
      for (const c of activeChats) {
        breakdown[c.serviceName] = (breakdown[c.serviceName] ?? 0) + 1;
      }
      this.sendSuccess(res, { total: activeChats.length, breakdown });
      return;
    }
    if (method === 'GET' && pathname === '/api/v1/chat/pinned') {
      const pinned = this.seed.chats
        .filter((c) => c.isPinned && !c.dateDeleted)
        .sort((a, b) => (a.pinIndex ?? 999) - (b.pinIndex ?? 999))
        .map(serializeChat);
      this.sendSuccess(res, pinned);
      return;
    }
    if (method === 'POST' && pathname === '/api/v1/chat/query') {
      const offset = Number(body?.offset ?? 0) || 0;
      const limit = Number(body?.limit ?? 100) || 100;
      const sort = String(body?.sort ?? '').toLowerCase();

      let chats = this.seed.chats.filter((c) => !c.dateDeleted).map((c) => {
        const msgs = this.seed.messagesByChat[c.guid] ?? [];
        if (msgs.length > 0) {
          c.lastMessage = msgs[msgs.length - 1];
        }
        return c;
      });

      if (sort === 'lastmessage') {
        chats = [...chats].sort((a, b) => (b.lastMessage?.dateCreated ?? 0) - (a.lastMessage?.dateCreated ?? 0));
      }

      const paged = chats.slice(offset, offset + limit).map(serializeChat);
      this.sendSuccess(res, paged, { total: chats.length, offset, limit });
      return;
    }
    if (method === 'POST' && pathname === '/api/v1/chat/new') {
      const addresses: string[] = Array.isArray(body?.addresses) ? body.addresses : [];
      const service: string = body?.service ?? 'iMessage';
      const initialText: string | undefined = typeof body?.message === 'string' ? body.message : undefined;
      const tempGuid: string | undefined = typeof body?.tempGuid === 'string' ? body.tempGuid : undefined;

      const participants = addresses.map((addr) => this.findOrCreateHandle(addr, service));
      const isGroup = participants.length > 1;
      const chatIdentifier = isGroup ? `chat${Date.now()}` : (participants[0]?.address ?? `+1555000${this.nextSeq()}`);
      const guid = `${service};${isGroup ? '+' : '-'};${chatIdentifier}`;

      let chat = this.findChat(guid);
      if (!chat) {
        chat = this.addChat({
          originalROWID: this.nextSeq(),
          guid,
          chatIdentifier,
          serviceName: service,
          style: isGroup ? 43 : 45,
          participants: participants.length > 0 ? participants : [this.findOrCreateHandle('+15550109999', service)],
        });
      }

      if (initialText && initialText.length > 0) {
        const msg = this.addMessage(chat.guid, {
          text: initialText,
          isFromMe: true,
          service,
          tempGuid,
        });
        this.io.emit('new-message', { status: 200, message: 'New message', data: serializeMessage(msg, chat) });
      }

      this.sendSuccess(res, serializeChat(chat));
      return;
    }

    const chatRouteMatch = /^\/api\/v1\/chat\/([^/]+)(?:\/(.*))?$/.exec(pathname);
    if (chatRouteMatch) {
      const chatGuid = decodeURIComponent(chatRouteMatch[1]);
      const sub = chatRouteMatch[2] ?? '';
      const chat = this.findChat(chatGuid);

      if (!chat) {
        this.sendError(res, 404, 'Not Found', `Chat ${chatGuid} not found`);
        return;
      }

      if (sub === 'message' && method === 'GET') {
        const after = query.after !== undefined ? Number(query.after) : undefined;
        const before = query.before !== undefined ? Number(query.before) : undefined;
        const offset = Number(query.offset ?? 0) || 0;
        const limit = Number(query.limit ?? 100) || 100;
        const sort = String(query.sort ?? 'DESC').toUpperCase();

        let msgs = [...(this.seed.messagesByChat[chatGuid] ?? [])].filter((m) => !m.dateDeleted);
        if (after !== undefined && Number.isFinite(after) && after > 0) {
          msgs = msgs.filter((m) => m.dateCreated >= after);
        }
        if (before !== undefined && Number.isFinite(before) && before > 0) {
          msgs = msgs.filter((m) => m.dateCreated <= before);
        }
        msgs.sort((a, b) => (sort === 'ASC' ? a.dateCreated - b.dateCreated : b.dateCreated - a.dateCreated));

        const paged = msgs.slice(offset, offset + limit).map((m) => serializeMessage(m));
        this.sendSuccess(res, paged);
        return;
      }

      if (sub === '' && method === 'GET') {
        this.sendSuccess(res, serializeChat(chat));
        return;
      }
      if (sub === '' && method === 'PUT') {
        if (typeof body?.displayName === 'string') {
          chat.displayName = body.displayName;
          this.io.emit('group-name-change', { chats: [serializeChat(chat)] });
        }
        this.sendSuccess(res, serializeChat(chat));
        return;
      }
      if (sub === '' && method === 'DELETE') {
        chat.dateDeleted = Date.now();
        this.sendSuccess(res, { deleted: true });
        return;
      }
      if (sub === 'read' && method === 'POST') {
        chat.hasUnreadMessage = false;
        this.io.emit('chat-read-status-changed', { chatGuid, read: true, status: true, readAt: Date.now() });
        this.sendSuccess(res, serializeChat(chat));
        return;
      }
      if (sub === 'unread' && method === 'POST') {
        chat.hasUnreadMessage = true;
        this.io.emit('chat-read-status-changed', { chatGuid, read: false, status: false });
        this.sendSuccess(res, serializeChat(chat));
        return;
      }
      if (sub === 'pin' && method === 'POST') {
        const nextPinned = typeof body?.isPinned === 'boolean' ? body.isPinned : !chat.isPinned;
        chat.isPinned = nextPinned;
        chat.pinIndex = nextPinned ? (typeof body?.pinIndex === 'number' ? body.pinIndex : 0) : null;
        const pinnedGuids = this.seed.chats.filter((c) => c.isPinned).map((c) => c.guid);
        this.io.emit('pinned-chats-updated', { pinnedChatGuids: pinnedGuids });
        this.sendSuccess(res, serializeChat(chat));
        return;
      }
      if (sub === 'typing' && (method === 'POST' || method === 'DELETE')) {
        this.sendSuccess(res, { typing: method === 'POST' });
        return;
      }
      if (sub === 'leave' && method === 'POST') {
        this.sendSuccess(res, serializeChat(chat));
        return;
      }
      if (sub === 'participant/add' && method === 'POST') {
        const address = String(body?.address ?? '');
        if (address) {
          const handle = this.findOrCreateHandle(address, chat.serviceName);
          if (!chat.participants.some((p) => p.address === address)) {
            chat.participants.push(handle);
          }
          this.io.emit('participant-added', { chats: [serializeChat(chat)] });
        }
        this.sendSuccess(res, serializeChat(chat));
        return;
      }
      if (sub === 'participant/remove' && method === 'POST') {
        const address = String(body?.address ?? '');
        if (address) {
          chat.participants = chat.participants.filter((p) => p.address !== address);
          this.io.emit('participant-removed', { chats: [serializeChat(chat)] });
        }
        this.sendSuccess(res, serializeChat(chat));
        return;
      }
      if (sub === 'icon') {
        if (method === 'GET') {
          const buf = this.chatIcons.get(chatGuid) ?? SAMPLE_PNG_BYTES;
          this.sendBinary(req, res, buf, 'image/png', 'icon.png');
          return;
        }
        if (method === 'POST') {
          const iconFile = files ? Object.values(files)[0] : undefined;
          this.chatIcons.set(chatGuid, iconFile?.data ?? SAMPLE_PNG_BYTES);
          this.sendSuccess(res, { updated: true });
          return;
        }
        if (method === 'DELETE') {
          this.chatIcons.delete(chatGuid);
          this.sendSuccess(res, { deleted: true });
          return;
        }
      }
      if (sub === 'background' && method === 'GET') {
        const buf = this.chatBackgrounds.get(chatGuid) ?? SAMPLE_PNG_BYTES;
        this.sendBinary(req, res, buf, 'image/png', 'background.png');
        return;
      }
      if (sub === 'share/contact/status' && method === 'GET') {
        this.sendSuccess(res, { shouldShare: false });
        return;
      }
      if (sub === 'share/contact' && method === 'POST') {
        this.sendSuccess(res, { shared: true });
        return;
      }
      if (sub && !sub.includes('/') && method === 'DELETE') {
        const list = this.seed.messagesByChat[chatGuid] ?? [];
        const msg = list.find((m) => m.guid === decodeURIComponent(sub));
        if (msg) msg.dateDeleted = Date.now();
        this.sendSuccess(res, { deleted: true });
        return;
      }
    }

    // ── Messages ────────────────────────────────────────────────────────────
    if (method === 'GET' && (pathname === '/api/v1/message/count' || pathname === '/api/v1/message/count/updated' || pathname === '/api/v1/message/count/me')) {
      let msgs = this.allMessages().filter((m) => !m.dateDeleted);
      if (pathname.endsWith('/me')) msgs = msgs.filter((m) => m.isFromMe);
      if (query.after) msgs = msgs.filter((m) => m.dateCreated >= Number(query.after));
      if (query.before) msgs = msgs.filter((m) => m.dateCreated <= Number(query.before));
      this.sendSuccess(res, { total: msgs.length });
      return;
    }

    if (method === 'POST' && pathname === '/api/v1/message/query') {
      const offset = Number(body?.offset ?? 0) || 0;
      const limit = Number(body?.limit ?? 100) || 100;
      const sort = String(body?.sort ?? 'DESC').toUpperCase();
      const after = body?.after !== undefined && body?.after !== null ? Number(body.after) : undefined;
      const before = body?.before !== undefined && body?.before !== null ? Number(body.before) : undefined;
      const chatGuidFilter = typeof body?.chatGuid === 'string' && body.chatGuid ? body.chatGuid : undefined;
      const where: Array<{ statement?: string; args?: Record<string, unknown> }> = Array.isArray(body?.where) ? body.where : [];

      let msgs = chatGuidFilter ? [...(this.seed.messagesByChat[chatGuidFilter] ?? [])] : this.allMessages();
      msgs = msgs.filter((m) => !m.dateDeleted);

      if (after !== undefined && Number.isFinite(after) && after > 0) {
        msgs = msgs.filter((m) => m.dateCreated >= after);
      }
      if (before !== undefined && Number.isFinite(before) && before > 0) {
        msgs = msgs.filter((m) => m.dateCreated <= before);
      }
      for (const clause of where) {
        const stmt = String(clause?.statement ?? '').toLowerCase();
        const args = clause?.args ?? {};
        if (stmt.includes('guid') && typeof args.guid === 'string') {
          msgs = msgs.filter((m) => m.guid === args.guid);
        }
        if (stmt.includes('text') && typeof args.text === 'string') {
          const needle = args.text.replace(/%/g, '').toLowerCase();
          msgs = msgs.filter((m) => (m.text ?? '').toLowerCase().includes(needle));
        }
      }

      msgs.sort((a, b) => (sort === 'ASC' ? a.dateCreated - b.dateCreated : b.dateCreated - a.dateCreated));
      const paged = msgs.slice(offset, offset + limit).map((m) => {
        const chat = m.chatGuid ? this.findChat(m.chatGuid) : undefined;
        return serializeMessage(m, chat);
      });
      this.sendSuccess(res, paged, { total: msgs.length, offset, limit });
      return;
    }

    if (method === 'POST' && pathname === '/api/v1/message/text') {
      const chatGuid = String(body?.chatGuid ?? '');
      const tempGuid = typeof body?.tempGuid === 'string' ? body.tempGuid : undefined;
      const text = String(body?.message ?? '');
      const chat = this.findChat(chatGuid);

      if (!chat) {
        this.sendError(res, 404, 'Not Found', `Chat ${chatGuid} not found`);
        return;
      }

      const id = this.nextSeq();
      const msg = this.addMessage(chatGuid, {
        originalROWID: id,
        id,
        guid: `msg-sent-${id}`,
        text,
        subject: typeof body?.subject === 'string' ? body.subject : null,
        expressiveSendStyleId: typeof body?.effectId === 'string' ? body.effectId : null,
        threadOriginatorGuid: typeof body?.selectedMessageGuid === 'string' ? body.selectedMessageGuid : null,
        threadOriginatorPart: body?.partIndex !== undefined && body?.partIndex !== null ? String(body.partIndex) : null,
        isFromMe: true,
        isDelivered: true,
        service: chat.serviceName,
        dateCreated: Date.now(),
        tempGuid,
      });

      const payload = serializeMessage(msg, chat);
      this.io.emit('new-message', { status: 200, message: 'New message', data: payload });
      this.sendSuccess(res, payload);
      return;
    }

    if (
      method === 'POST' &&
      (pathname === '/api/v1/message/attachment' ||
        pathname === '/api/v1/message/attachment/chunk' ||
        pathname === '/api/v1/message/multipart')
    ) {
      const chatGuid = String(body?.chatGuid ?? '');
      const tempGuid = typeof body?.tempGuid === 'string' ? body.tempGuid : undefined;
      const chat = this.findChat(chatGuid) ?? this.seed.chats[0];
      const uploadedFile = files?.attachment ?? (files ? Object.values(files)[0] : undefined);
      const uploadedFromBlob = typeof body?.path === 'string' ? this.uploadedBlobs.get(body.path) : undefined;
      const fileBytes = uploadedFile?.data ?? uploadedFromBlob?.data ?? SAMPLE_PNG_BYTES;
      const filename = String(body?.name ?? uploadedFile?.filename ?? uploadedFromBlob?.filename ?? 'attachment.png');
      const mimeType = uploadedFile?.contentType ?? uploadedFromBlob?.contentType ?? 'image/png';

      const attId = this.nextSeq();
      const att = makeAttachment({
        originalROWID: attId,
        id: attId,
        guid: `att-sent-${attId}`,
        transferName: filename,
        mimeType,
        isOutgoing: true,
        bytes: fileBytes,
        totalBytes: fileBytes.byteLength,
      });

      const msgId = this.nextSeq();
      const msg = this.addMessage(chat.guid, {
        originalROWID: msgId,
        id: msgId,
        guid: `msg-att-${msgId}`,
        text: typeof body?.message === 'string' ? body.message : '\uFFFC',
        isFromMe: true,
        hasAttachments: true,
        attachments: [att],
        tempGuid,
        dateCreated: Date.now(),
      });

      const payload = serializeMessage(msg, chat);
      this.io.emit('new-message', { status: 200, message: 'New message', data: payload });
      this.sendSuccess(res, payload);
      return;
    }

    if (method === 'POST' && pathname === '/api/v1/message/react') {
      const chatGuid = String(body?.chatGuid ?? '');
      const selectedGuid = String(body?.selectedMessageGuid ?? '');
      const reaction = String(body?.reaction ?? 'love');
      const partIndex = Number(body?.partIndex ?? 0) || 0;
      const chat = this.findChat(chatGuid) ?? this.seed.chats[0];

      const id = this.nextSeq();
      const msg = this.addMessage(chat.guid, {
        originalROWID: id,
        id,
        guid: `msg-react-${id}`,
        text: '',
        isFromMe: true,
        associatedMessageGuid: `p:${partIndex}/${selectedGuid}`,
        associatedMessagePart: partIndex,
        associatedMessageType: reaction,
        associatedMessageEmoji: typeof body?.emoji === 'string' ? body.emoji : null,
        dateCreated: Date.now(),
      });

      const payload = serializeMessage(msg, chat);
      this.io.emit('new-message', { status: 200, message: 'New message', data: payload });
      this.sendSuccess(res, payload);
      return;
    }

    if (pathname === '/api/v1/message/schedule') {
      if (method === 'GET') {
        this.sendSuccess(res, this.seed.scheduledMessages);
        return;
      }
      if (method === 'POST') {
        const item = {
          id: this.nextSeq(),
          type: String(body?.type ?? 'send-message'),
          payload: body?.payload ?? {},
          scheduledFor: Number(body?.scheduledFor ?? Date.now() + 60_000),
          schedule: body?.schedule ?? { type: 'once' },
          status: 'PENDING',
          created: Date.now(),
        };
        this.seed.scheduledMessages.push(item);
        this.sendSuccess(res, item);
        return;
      }
    }
    const schedMatch = /^\/api\/v1\/message\/schedule\/(\d+)$/.exec(pathname);
    if (schedMatch) {
      const schedId = Number(schedMatch[1]);
      const idx = this.seed.scheduledMessages.findIndex((s) => s.id === schedId);
      if (method === 'PUT' && idx !== -1) {
        this.seed.scheduledMessages[idx] = { ...this.seed.scheduledMessages[idx], ...(body ?? {}) };
        this.sendSuccess(res, this.seed.scheduledMessages[idx]);
        return;
      }
      if (method === 'DELETE' && idx !== -1) {
        this.seed.scheduledMessages.splice(idx, 1);
        this.sendSuccess(res, { deleted: true });
        return;
      }
    }

    const msgRouteMatch = /^\/api\/v1\/message\/([^/]+)(?:\/(.*))?$/.exec(pathname);
    if (msgRouteMatch) {
      const msgGuid = decodeURIComponent(msgRouteMatch[1]);
      const sub = msgRouteMatch[2] ?? '';
      const found = this.findMessage(msgGuid);
      if (!found) {
        this.sendError(res, 404, 'Not Found', `Message ${msgGuid} not found`);
        return;
      }
      const chat = this.findChat(found.chatGuid);

      if (sub === '' && method === 'GET') {
        this.sendSuccess(res, serializeMessage(found.message, chat));
        return;
      }
      if (sub === 'embedded-media' && method === 'GET') {
        this.sendBinary(req, res, SAMPLE_MP4_BYTES, 'video/mp4', 'embedded.mp4');
        return;
      }
      if (sub === 'edit' && method === 'POST') {
        const editedText = String(body?.editedMessage ?? body?.message ?? found.message.text);
        found.message.text = editedText;
        found.message.dateEdited = Date.now();
        found.message.attributedBody = [{ string: editedText, runs: [] }];
        const payload = serializeMessage(found.message, chat);
        this.io.emit('updated-message', { status: 200, message: 'Updated message', data: payload });
        this.sendSuccess(res, payload);
        return;
      }
      if (sub === 'unsend' && method === 'POST') {
        const partIndex = Number(body?.partIndex ?? 0) || 0;
        found.message.dateEdited = Date.now();
        found.message.messageSummaryInfo = [{ retractedParts: [partIndex] }];
        const payload = serializeMessage(found.message, chat);
        this.io.emit('updated-message', { status: 200, message: 'Updated message', data: payload });
        this.sendSuccess(res, payload);
        return;
      }
      if (sub === 'notify' && method === 'POST') {
        found.message.didNotifyRecipient = true;
        const payload = serializeMessage(found.message, chat);
        this.io.emit('updated-message', { status: 200, message: 'Updated message', data: payload });
        this.sendSuccess(res, payload);
        return;
      }
    }

    if (method === 'POST' && pathname === '/api/v2/message/app') {
      const chatGuid = String(body?.chatGuid ?? this.seed.chats[0]?.guid ?? '');
      const chat = this.findChat(chatGuid) ?? this.seed.chats[0];
      const id = this.nextSeq();
      const msg = this.addMessage(chat.guid, {
        originalROWID: id,
        id,
        guid: `msg-app-${id}`,
        text: String(body?.summary ?? body?.caption ?? 'App message'),
        isFromMe: true,
        hasApplePayloadData: true,
        balloonBundleId: String(body?.bundleId ?? 'com.apple.messages.MSMessageExtensionBalloonPlugin'),
        dateCreated: Date.now(),
      });
      this.sendSuccess(res, serializeMessage(msg, chat));
      return;
    }
    if (method === 'GET' && pathname.startsWith('/api/v2/message/app/')) {
      const guid = decodeURIComponent(pathname.slice('/api/v2/message/app/'.length));
      const found = this.findMessage(guid);
      this.sendSuccess(res, found ? serializeMessage(found.message) : null);
      return;
    }

    // ── Attachments ─────────────────────────────────────────────────────────
    if (method === 'GET' && pathname === '/api/v1/attachment/count') {
      const total = this.allMessages().reduce((sum, m) => sum + (m.attachments?.length ?? 0), 0);
      this.sendSuccess(res, { total });
      return;
    }
    if (method === 'POST' && pathname === '/api/v1/attachment/upload') {
      const file = files?.attachment ?? (files ? Object.values(files)[0] : undefined);
      const id = `upload-${this.nextSeq()}`;
      this.uploadedBlobs.set(id, {
        filename: file?.filename ?? 'upload.png',
        contentType: file?.contentType ?? 'image/png',
        data: file?.data ?? SAMPLE_PNG_BYTES,
      });
      this.sendSuccess(res, { path: id });
      return;
    }
    const attRouteMatch = /^\/api\/v1\/attachment\/([^/]+)(?:\/(.*))?$/.exec(pathname);
    if (attRouteMatch) {
      const attGuid = decodeURIComponent(attRouteMatch[1]);
      const sub = attRouteMatch[2] ?? '';
      const att = this.findAttachment(attGuid);
      if (!att) {
        this.sendError(res, 404, 'Not Found', `Attachment ${attGuid} not found`);
        return;
      }
      if (sub === '' && method === 'GET') {
        this.sendSuccess(res, stripAttachmentBytes(att));
        return;
      }
      if (sub === 'download' && (method === 'GET' || method === 'HEAD')) {
        const bytes =
          att.bytes ??
          (att.mimeType?.startsWith('video/')
            ? SAMPLE_MP4_BYTES
            : att.mimeType?.startsWith('audio/')
              ? SAMPLE_M4A_BYTES
              : SAMPLE_PNG_BYTES);
        this.sendBinary(req, res, bytes, att.mimeType || 'application/octet-stream', att.transferName);
        return;
      }
      if (sub === 'live' && (method === 'GET' || method === 'HEAD')) {
        this.sendBinary(req, res, SAMPLE_MP4_BYTES, 'video/mp4', `${attGuid}.mp4`);
        return;
      }
      if (sub === 'blurhash' && method === 'GET') {
        this.sendSuccess(res, 'LEHV6nWB2yk8pyo0adR*.7kCMdnj');
        return;
      }
    }

    // ── Handles & Contacts & iCloud & Backups ───────────────────────────────
    if (method === 'GET' && pathname === '/api/v1/handle/count') {
      this.sendSuccess(res, { total: this.seed.handles.length });
      return;
    }
    if (method === 'POST' && pathname === '/api/v1/handle/query') {
      const offset = Number(body?.offset ?? 0) || 0;
      const limit = Number(body?.limit ?? 100) || 100;
      const address = typeof body?.address === 'string' ? body.address : undefined;
      let handles = this.seed.handles;
      if (address) handles = handles.filter((h) => h.address.includes(address));
      this.sendSuccess(res, handles.slice(offset, offset + limit), { total: handles.length, offset, limit });
      return;
    }
    if (method === 'GET' && (pathname === '/api/v1/handle/availability/imessage' || pathname === '/api/v1/handle/availability/facetime')) {
      this.sendSuccess(res, { available: true });
      return;
    }
    const handleMatch = /^\/api\/v1\/handle\/([^/]+)(?:\/(.*))?$/.exec(pathname);
    if (handleMatch && method === 'GET') {
      const key = decodeURIComponent(handleMatch[1]);
      const sub = handleMatch[2] ?? '';
      if (sub === 'focus') {
        this.sendSuccess(res, { status: 'none' });
        return;
      }
      const h = this.seed.handles.find((x) => x.address === key || String(x.originalROWID) === key);
      this.sendSuccess(res, h ?? null);
      return;
    }

    if (pathname === '/api/v1/contact') {
      if (method === 'GET') {
        const offset = Number(query.offset ?? 0) || 0;
        const limit = Number(query.limit ?? 100) || 100;
        this.sendSuccess(res, this.seed.contacts.slice(offset, offset + limit));
        return;
      }
      if (method === 'POST') {
        const created: ContactFixture = {
          id: body?.id ?? `contact-${this.nextSeq()}`,
          displayName: body?.displayName ?? `${body?.firstName ?? ''} ${body?.lastName ?? ''}`.trim(),
          firstName: body?.firstName ?? '',
          lastName: body?.lastName ?? '',
          phoneNumbers: body?.phoneNumbers ?? [],
          emails: body?.emails ?? [],
          ...(body?.avatar ? { avatar: body.avatar } : {}),
        };
        this.seed.contacts.push(created);
        this.sendSuccess(res, created);
        return;
      }
      if (method === 'PUT') {
        const idx = this.seed.contacts.findIndex((c) => c.id === body?.id);
        if (idx !== -1) {
          this.seed.contacts[idx] = { ...this.seed.contacts[idx], ...(body ?? {}) };
          this.sendSuccess(res, this.seed.contacts[idx]);
          return;
        }
        this.sendError(res, 404, 'Not Found', 'Contact not found');
        return;
      }
      if (method === 'DELETE') {
        this.seed.contacts = this.seed.contacts.filter((c) => c.id !== (body?.id ?? query.id));
        this.sendSuccess(res, { deleted: true });
        return;
      }
    }
    if (method === 'POST' && pathname === '/api/v1/contact/query') {
      const addresses: string[] = Array.isArray(body?.addresses) ? body.addresses : [];
      const matched =
        addresses.length === 0
          ? this.seed.contacts
          : this.seed.contacts.filter(
              (c) =>
                c.phoneNumbers.some((p) => addresses.includes(p.address)) ||
                c.emails.some((e) => addresses.includes(e.address)),
            );
      this.sendSuccess(res, matched);
      return;
    }

    if (method === 'GET' && pathname === '/api/v1/icloud/account') {
      this.sendSuccess(res, {
        apple_id: this.seed.serverInfo.detected_icloud,
        account_name: 'E2E User',
        active_alias: this.seed.serverInfo.detected_imessage,
        vetted_aliases: [
          { Alias: this.seed.serverInfo.detected_imessage, Status: 5005 },
          { Alias: this.seed.serverInfo.detected_icloud, Status: 5005 },
        ],
      });
      return;
    }
    if (method === 'GET' && pathname === '/api/v1/icloud/contact') {
      const addr = query.address ?? '';
      const contact = this.seed.contacts.find(
        (c) => c.phoneNumbers.some((p) => p.address === addr) || c.emails.some((e) => e.address === addr),
      );
      this.sendSuccess(res, contact ?? null);
      return;
    }
    if (method === 'POST' && pathname === '/api/v1/icloud/account/alias') {
      if (typeof body?.alias === 'string') {
        this.seed.serverInfo.detected_imessage = body.alias;
      }
      this.sendSuccess(res, { alias: this.seed.serverInfo.detected_imessage });
      return;
    }

    if (pathname === '/api/v1/backup/theme') {
      if (method === 'GET') {
        this.sendSuccess(res, this.seed.themeBackup ?? []);
        return;
      }
      if (method === 'POST') {
        this.seed.themeBackup = body ?? {};
        this.sendSuccess(res, this.seed.themeBackup);
        return;
      }
      if (method === 'DELETE') {
        this.seed.themeBackup = null;
        this.sendSuccess(res, { deleted: true });
        return;
      }
    }
    if (pathname === '/api/v1/backup/settings') {
      if (method === 'GET') {
        this.sendSuccess(res, this.seed.settingsBackup ?? []);
        return;
      }
      if (method === 'POST') {
        this.seed.settingsBackup = body ?? {};
        this.sendSuccess(res, this.seed.settingsBackup);
        return;
      }
      if (method === 'DELETE') {
        this.seed.settingsBackup = null;
        this.sendSuccess(res, { deleted: true });
        return;
      }
    }

    // ── FindMy ──────────────────────────────────────────────────────────────
    if (method === 'GET' && pathname === '/api/v1/icloud/findmy/devices') {
      this.sendSuccess(res, this.seed.findMyDevices);
      return;
    }
    if (method === 'POST' && pathname === '/api/v1/icloud/findmy/devices/refresh') {
      const now = Date.now();
      const targetId = typeof body?.deviceId === 'string' ? body.deviceId : undefined;
      for (const dev of this.seed.findMyDevices) {
        if (!targetId || dev.id === targetId) {
          dev.location.timeStamp = now;
          dev.location.isLocatingInProgress = false;
          dev.location.locationFinished = true;
        }
      }
      this.sendSuccess(res, this.seed.findMyDevices);
      return;
    }
    if (method === 'GET' && pathname === '/api/v1/icloud/findmy/devices/icon') {
      this.sendBinary(req, res, SAMPLE_PNG_BYTES, 'image/png', 'device-icon.png');
      return;
    }
    if (method === 'POST' && pathname === '/api/v1/icloud/findmy/devices/ring') {
      this.sendSuccess(res, {
        deviceId: body?.deviceId,
        action: body?.action ?? 'start',
        ringing: (body?.action ?? 'start') === 'start',
      });
      return;
    }
    if (method === 'GET' && pathname === '/api/v1/icloud/findmy/devices/ble-spec') {
      this.sendSuccess(res, {
        deviceId: query.deviceId ?? '',
        manufacturerId: 76,
        serviceUuid: 'FD44',
        advertisementKey: 'mock-ble-key',
      });
      return;
    }
    if (method === 'GET' && pathname === '/api/v1/icloud/findmy/friends') {
      this.sendSuccess(res, this.seed.findMyFriends);
      return;
    }
    if (method === 'POST' && pathname === '/api/v1/icloud/findmy/friends/refresh') {
      const now = Date.now();
      const targetHandle = typeof body?.handle === 'string' ? body.handle : undefined;
      for (const fr of this.seed.findMyFriends) {
        const addr = typeof fr.handle === 'string' ? fr.handle : fr.handle?.address;
        if (!targetHandle || addr === targetHandle) {
          fr.last_updated = now;
          fr.location_finished = true;
        }
      }
      this.sendSuccess(res, this.seed.findMyFriends);
      return;
    }
    if (method === 'POST' && pathname === '/api/v1/icloud/findmy/friends/live/start') {
      const targetHandle = typeof body?.handle === 'string' ? body.handle : undefined;
      for (const fr of this.seed.findMyFriends) {
        const addr = typeof fr.handle === 'string' ? fr.handle : fr.handle?.address;
        if (!targetHandle || addr === targetHandle) {
          fr.is_live = true;
          fr.status = 'live';
          fr.last_updated = Date.now();
        }
      }
      this.sendSuccess(res, { active: true });
      return;
    }
    if (method === 'POST' && pathname === '/api/v1/icloud/findmy/friends/live/stop') {
      const targetHandle = typeof body?.handle === 'string' ? body.handle : undefined;
      for (const fr of this.seed.findMyFriends) {
        const addr = typeof fr.handle === 'string' ? fr.handle : fr.handle?.address;
        if (!targetHandle || addr === targetHandle) {
          fr.is_live = false;
        }
      }
      this.sendSuccess(res, { active: false });
      return;
    }

    // ── FaceTime ────────────────────────────────────────────────────────────
    if (method === 'GET' && pathname === '/api/v1/facetime/sessions') {
      this.sendSuccess(res, { sessions: this.seed.faceTimeSessions });
      return;
    }
    if (method === 'POST' && pathname === '/api/v1/facetime/session') {
      const link = `https://facetime.apple.com/join#v=1&p=mock-${this.nextSeq()}`;
      this.sendSuccess(res, { link });
      return;
    }
    if (method === 'POST' && pathname === '/api/v2/facetime/call') {
      const addresses: string[] = Array.isArray(body?.addresses) ? body.addresses : ['+15550100001'];
      const session = makeFaceTimeSession({
        uuid: `ft-out-${this.nextSeq()}`,
        status_id: 3,
        status: 'outgoing',
        address: addresses[0],
        is_video: body?.isAudio !== true,
        is_audio: body?.isAudio === true,
      });
      this.upsertFaceTimeSession(session);
      this.io.emit('ft-call-status-changed', session);
      this.sendSuccess(res, session);
      return;
    }
    if (method === 'POST' && pathname === '/api/v1/facetime/dtmf') {
      this.sendSuccess(res, { sent: true });
      return;
    }
    const ftLegacyMatch = /^\/api\/v1\/facetime\/(answer|leave)\/([^/]+)$/.exec(pathname);
    if (ftLegacyMatch && method === 'POST') {
      const [, action, callUuid] = ftLegacyMatch;
      const existing = this.seed.faceTimeSessions.find((s) => s.uuid === callUuid);
      if (existing) {
        existing.status_id = action === 'answer' ? 1 : 6;
        existing.status = action === 'answer' ? 'answered' : 'disconnected';
        this.io.emit('ft-call-status-changed', existing);
      }
      this.sendSuccess(res, existing ?? { uuid: callUuid, link: `https://facetime.apple.com/join#${callUuid}` });
      return;
    }
    const ftSessionMatch = /^\/api\/v1\/facetime\/session\/([^/]+)\/(answer|handoff|mute|leave|decline)$/.exec(pathname);
    if (ftSessionMatch && method === 'POST') {
      const [, callUuid, action] = ftSessionMatch;
      const existing = this.seed.faceTimeSessions.find((s) => s.uuid === callUuid);
      if (existing) {
        if (action === 'answer') {
          existing.status_id = 1;
          existing.status = 'answered';
        } else if (action === 'leave' || action === 'decline') {
          existing.status_id = 6;
          existing.status = 'disconnected';
        }
        this.io.emit('ft-call-status-changed', existing);
      }
      this.sendSuccess(res, existing ?? { uuid: callUuid, action });
      return;
    }

    // ── Stickers & Genmoji stubs ────────────────────────────────────────────
    if (pathname.startsWith('/api/v1/sticker') || pathname.startsWith('/api/v1/genmoji')) {
      this.sendSuccess(res, method === 'GET' ? [] : { ok: true });
      return;
    }

    this.sendError(res, 404, 'Not Found', `Route not found: ${method} ${pathname}`);
  }
}

export async function startMockBBServer(options: StartMockBBServerOptions = {}): Promise<MockBBServer> {
  const host = options.host ?? '127.0.0.1';
  const port = options.port ?? 0;
  const password = options.password ?? DEFAULT_PASSWORD;
  const seed = options.seed ?? createDefaultSeed();

  let instance: MockBBServer;
  const httpServer = http.createServer((req, res) => {
    void instance.handleHttpRequest(req, res).catch((err) => {
      if (!res.headersSent) {
        res.writeHead(500, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ status: 500, message: String(err) }));
      } else {
        res.end();
      }
    });
  });

  const io = new SocketIOServer(httpServer, {
    cors: {
      origin: (origin, cb) => cb(null, origin || true),
      credentials: true,
    },
    allowEIO3: true,
  });

  await new Promise<void>((resolve, reject) => {
    httpServer.once('error', reject);
    httpServer.listen(port, host, () => {
      httpServer.off('error', reject);
      resolve();
    });
  });

  const addr = httpServer.address() as AddressInfo;
  const actualHost = addr.address === '::' ? '127.0.0.1' : addr.address;
  const actualPort = addr.port;
  const url = `http://${actualHost}:${actualPort}`;

  instance = new MockBBServer({
    url,
    port: actualPort,
    host: actualHost,
    password,
    seed,
    httpServer,
    io,
  });

  return instance;
}
