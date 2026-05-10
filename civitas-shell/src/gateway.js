import { EventEmitter } from 'events';
import { WebSocket } from 'ws';
import { randomUUID } from 'crypto';

const PROTOCOL_VERSION = 3;
const CLIENT_ID = "gateway-client";
const CLIENT_MODE = "backend";
const CLIENT_VERSION = '0.1.0';

export class GatewayClient extends EventEmitter {
  constructor(opts) {
    super();
    this.url = opts.url ?? 'ws://127.0.0.1:18789';
    this.token = opts.token ?? null;
    this.password = opts.password ?? null;
    this.ws = null;
    this.pending = new Map();
    this.defaultTimeoutMs = opts.timeoutMs ?? 30_000;
    this.connected = false;
    this._reconnectTimer = null;
    this._closed = false; // set true on explicit close() to stop reconnect loop
  }

  connect() {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.url, {
        agent: false,
      });
      this.ws = ws;
      let settled = false;
      const fail = (err) => {
        if (settled) return;
        settled = true;
        reject(err);
        ws.terminate();
      };

      ws.on('open', () => {
        // wait for connect.challenge before sending connect
      });

      ws.on('message', (data) => {
        let frame;
        try { frame = JSON.parse(data.toString()); } catch { return; }

        if (frame.type === 'event') {
          if (frame.event === 'connect.challenge') {
            // send connect request — nonce only needed for device-key auth, not token auth
            this._sendConnect().then((helloOk) => {
              if (settled) return;
              settled = true;
              this.connected = true;
              resolve(helloOk);
            }).catch(fail);
            return;
          }
          // broadcast all other events to listeners
          this.emit('event', frame);
          return;
        }

        if (frame.type === 'res') {
          const pending = this.pending.get(frame.id);
          if (!pending) return;
          this.pending.delete(frame.id);
          if (frame.ok) pending.resolve(frame.payload);
          else pending.reject(Object.assign(
            new Error(frame.error?.message ?? 'gateway error'),
            { code: frame.error?.code, details: frame.error?.details }
          ));
        }
      });

      ws.on('error', (err) => fail(err));
      ws.on('close', (code, reason) => {
        const msg = `gateway disconnected (${code}: ${reason?.toString() ?? 'no reason'})`;
        // reject any pending requests
        for (const p of this.pending.values()) p.reject(new Error(msg));
        this.pending.clear();
        this.connected = false;
        if (!settled) fail(new Error(msg));
        this.emit('close', code);
        // auto-reconnect unless explicitly closed
        if (!this._closed) this._scheduleReconnect();
      });
    });
  }

  _sendConnect() {
    const auth = this.token ? { token: this.token }
      : this.password ? { password: this.password }
      : undefined;
    return this.request('connect', {
      minProtocol: PROTOCOL_VERSION,
      maxProtocol: PROTOCOL_VERSION,
      client: {
        id: CLIENT_ID,
        version: CLIENT_VERSION,
        platform: process.platform,
        mode: CLIENT_MODE,
      },
      caps: [],
      auth,
      role: 'operator',
      // FIXME(v1): scope list hardcoded; update if OpenClaw adds scopes civitas-shell needs
      scopes: ["operator.admin","operator.read","operator.write","operator.approvals","operator.pairing","operator.talk.secrets"],
    });
  }

  request(method, params, opts = {}) {
    return new Promise((resolve, reject) => {
      const id = randomUUID();
      const frame = { type: 'req', id, method, params };
      const timeoutMs = opts.timeoutMs === null ? null
        : (typeof opts.timeoutMs === 'number' ? opts.timeoutMs : this.defaultTimeoutMs);
      let timer = null;
      if (timeoutMs !== null) {
        timer = setTimeout(() => {
          this.pending.delete(id);
          reject(new Error(`gateway request timeout: ${method}`));
        }, timeoutMs);
        timer.unref?.();
      }
      this.pending.set(id, {
        resolve: (v) => { if (timer) clearTimeout(timer); resolve(v); },
        reject: (e) => { if (timer) clearTimeout(timer); reject(e); },
      });
      this.ws.send(JSON.stringify(frame));
    });
  }

  _scheduleReconnect(delayMs = 3000) {
    if (this._reconnectTimer) return;
    this._reconnectTimer = setTimeout(() => {
      this._reconnectTimer = null;
      if (this._closed) return;
      this.connect().then(() => {
        this.emit('reconnect');
      }).catch(() => {
        // connect failed; schedule another attempt
        if (!this._closed) this._scheduleReconnect(Math.min(delayMs * 2, 30_000));
      });
    }, delayMs);
    this._reconnectTimer.unref?.();
  }

  close() {
    this._closed = true;
    if (this._reconnectTimer) { clearTimeout(this._reconnectTimer); this._reconnectTimer = null; }
    this.ws?.close();
  }
}
