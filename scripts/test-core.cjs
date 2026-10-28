// Runs the actual ArkTS protocol/store code with explicit platform adapters.
// Native mDNS, permissions and ArkUI still require a HarmonyOS device.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const net = require('node:net');
const { spawn, execFileSync } = require('node:child_process');
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'lanchat-harmony-test-'));
const stores = [];
const prefCache = new Map();
const copyCalls = [];
let failFolderCopy = false;
function nativePath(uriOrPath) {
  return typeof uriOrPath === 'string' && uriOrPath.startsWith('file://') ? decodeURIComponent(new URL(uriOrPath).pathname) : uriOrPath;
}
// Keep these runtime types separate. FileUri does NOT inherit URI operations
// on the user's device, despite the SDK's TypeScript declaration.
class FileUriAdapter {
  constructor(uriOrPath) {
    this.url = uriOrPath.startsWith('file://') ? new URL(uriOrPath) : require('node:url').pathToFileURL(uriOrPath);
  }
  get name() { return path.basename(nativePath(this.url.href)); }
}
class URIAdapter {
  constructor(value) { this.url = new URL(value); }
  getSegment() { return this.url.pathname.split('/').filter(Boolean).map(segment => decodeURIComponent(segment)); }
  addSegment(segment) {
    const result = new URL(this.url.href);
    result.pathname = result.pathname.replace(/\/$/, '') + '/' + encodeURIComponent(segment);
    return new URIAdapter(result.href);
  }
  toString() { return this.url.href; }
}
const fsAdapter = {
  OpenMode: { READ_ONLY: 0, READ_WRITE: 2, CREATE: 64, TRUNC: 512 },
  mkdirSync: (p, recursive = false) => {
    if (fs.existsSync(p)) throw new Error("File exists (HarmonyOS mkdir semantics)");
    return fs.mkdirSync(p, { recursive });
  },
  accessSync: p => fs.existsSync(p),
  openSync: (p, mode = 0) => ({ fd: fs.openSync(typeof p === 'string' && p.startsWith('file://') ? new URL(p) : p, (mode & 64) ? ((mode & 512) ? 'w+' : 'wx+') : (mode & 2) ? 'r+' : 'r') }),
  closeSync: file => fs.closeSync(typeof file === 'number' ? file : file.fd),
  statSync: p => typeof p === 'number' ? fs.fstatSync(p) : fs.statSync(p),
  readSync: (fd, buffer, opts = {}) => fs.readSync(fd, Buffer.from(buffer), 0, opts.length ?? buffer.byteLength, opts.offset ?? null),
  writeSync: (fd, data, opts = {}) => typeof data === 'string' ? fs.writeSync(fd, data) : fs.writeSync(fd, Buffer.from(data), 0, opts.length ?? data.byteLength, opts.offset ?? null),
  readTextSync: p => fs.readFileSync(p, 'utf8'),
  lstatSync: p => {
    try { return fs.lstatSync(nativePath(p)); }
    catch (error) { if (error.code === 'ENOENT') error.code = 13900002; throw error; }
  },
  listFileSync: p => fs.readdirSync(p),
  rmdirSync: p => fs.rmdirSync(p),
  copy: async (src, dest) => {
    const source = nativePath(src), destination = nativePath(dest);
    copyCalls.push({ source: src, destination: dest });
    const stat = fs.statSync(source);
    if (stat.isDirectory()) {
      // Match OpenHarmony FileCopyManager: the destination must already exist
      // and be a directory; the source basename is created INSIDE it.
      if (!fs.existsSync(destination) || !fs.statSync(destination).isDirectory() || destination === source || destination.startsWith(source + path.sep)) {
        const error = new Error('Invalid argument'); error.code = 13900020; throw error;
      }
      const target = path.join(destination, path.basename(source));
      if (failFolderCopy) {
        fs.mkdirSync(target, { recursive: true });
        fs.writeFileSync(path.join(target, 'partial'), 'interrupted');
        const error = new Error('No space left on device'); error.code = 13900028; throw error;
      }
      fs.cpSync(source, target, { recursive: true, dereference: false, force: true });
    } else { fs.copyFileSync(source, destination); }
  },
  renameSync: fs.renameSync,
  unlinkSync: fs.unlinkSync,
  copyFile: async (source, target) => {
    const bytes = fs.readFileSync(source);
    if (typeof target === 'number') fs.writeSync(target, bytes); else fs.writeFileSync(target, bytes);
  }
};
const util = {
  generateRandomUUID: () => crypto.randomUUID(),
  TextEncoder: class { encodeInto(s) { return new Uint8Array(Buffer.from(s, 'utf8')); } },
  TextDecoder: class { constructor(_, options) { this.decoder = new TextDecoder('utf-8', options); } decodeToString(b) { return this.decoder.decode(b); } },
  Base64Helper: class { encodeToStringSync(b) { return Buffer.from(b).toString('base64'); } decodeSync(s) { return new Uint8Array(Buffer.from(s, 'base64')); } }
};
let pickedDirectory = [];
const sharedContacts = [];
const removedContacts = [];
let rejectContactDonation = false;
global.$r = name => name;
const kits = {
  'BuildProfile': { default: { BUNDLE_NAME: 'com.hohode.localchat' } },
  '@kit.PerformanceAnalysisKit': { hilog: { warn: () => {} } },
  '@kit.IntentsKit': { insightIntent: {
    shareIntent: async (_, intents) => {
      if (rejectContactDonation) throw new Error('Not allowlisted');
      sharedContacts.push(...intents);
    },
    deleteEntity: async (_, type, ids) => removedContacts.push(...ids)
  } },
  '@kit.ShareKit': { systemShare: { getContactInfo: async want => {
    if (!want.contact) throw new Error('No contact');
    return want.contact;
  }, getSharedData: async want => {
    if (want.parseError) throw new Error('Invalid share data');
    return { getRecords: () => want.records || [] };
  } } },
  '@kit.ArkUI': { FrameCallback: class {}, KeyboardAvoidMode: {}, window: {}, promptAction: {} },
  '@kit.ArkTS': { util, uri: { URI: URIAdapter } }, '@kit.NetworkKit': { socket: {}, mdns: {} },
  '@kit.ArkData': { preferences: { getPreferencesSync: context => {
    if (!prefCache.has(context.filesDir)) prefCache.set(context.filesDir, new Map());
    const values = prefCache.get(context.filesDir);
    return { getSync: (key, fallback) => values.get(key) ?? fallback, putSync: (key, value) => values.set(key, value), flush: async () => {} };
  } } },
  '@kit.CoreFileKit': { fileIo: fsAdapter, picker: { DocumentSelectMode: { FOLDER: 1 }, DocumentViewPicker: class { async select() { return pickedDirectory; } } }, fileUri: { getUriFromPath: p => require('node:url').pathToFileURL(p).href, FileUri: FileUriAdapter } },
  '@kit.MediaLibraryKit': { photoAccessHelper: {} }, '@kit.ImageKit': { image: {} },
  '@kit.BasicServicesKit': { deviceInfo: { brand: 'Test' }, pasteboard: {} }
};
const cache = new Map();
function load(file) {
  file = path.resolve(file);
  if (cache.has(file)) return cache.get(file).exports;
  let source = fs.readFileSync(file, 'utf8');
  if (file.endsWith('/pages/Index.ets')) {
    // Exercise the actual navigation/scroll controller; ArkUI builders require a device.
    source = source.slice(0, source.indexOf('  build() {')) + '\n}\n';
    source = source.replace(/@Entry\s*\n@Component\s*\nstruct Index/, 'export class Index')
      .replace(/^(\s*)@[^\n]*?private /gm, '$1private ');
  }
  const compiled = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} }; cache.set(file, module);
  const localRequire = name => {
    if (kits[name]) return kits[name];
    if (name.startsWith('.')) return load(path.resolve(path.dirname(file), `${name}.ets`));
    throw new Error(`Unexpected native dependency ${name}`);
  };
  new Function('require', 'module', 'exports', compiled)(localRequire, module, module.exports);
  return module.exports;
}
const source = path.join(root, 'entry/src/main/ets');
const { Packet, Framer, encodePacket, messageDate } = load(`${source}/network/Wire.ets`);
const { Channel } = load(`${source}/network/LanNetwork.ets`);
const { ChatStore } = load(`${source}/store/ChatStore.ets`);
const { ASSISTANT_ID } = load(`${source}/model/Models.ets`);
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function wait(check, label, timeout = 10000) {
  const deadline = Date.now() + timeout;
  while (!check()) { if (Date.now() > deadline) throw new Error(`Timed out: ${label}`); await delay(20); }
}
function createStore(name) {
  const filesDir = path.join(temporary, name); fs.mkdirSync(filesDir, { recursive: true });
  const store = new ChatStore({ filesDir, resourceManager: { getMediaContent: async () => new Uint8Array([1, 2, 3]) } }); stores.push(store); return store;
}
function recordingChannel(store) {
  const channel = new Channel(); const sent = [];
  channel.client = { send: async ({data}) => sent.push(...new Framer().append(data)), close: async () => {} };
  store.network.channels.push(channel);
  return { channel, sent };
}
async function core() {
  const packet = new Packet('text'); packet.text = '你好 HarmonyOS 👋\n多行消息';
  const bytes = new Uint8Array(encodePacket(packet));
  const parser = new Framer(); let decoded = [];
  for (const byte of bytes) decoded.push(...parser.append(new Uint8Array([byte]).buffer));
  assert.equal(decoded[0].text, packet.text);
  const joined = new Uint8Array(bytes.length * 2); joined.set(bytes); joined.set(bytes, bytes.length);
  assert.equal(new Framer().append(joined.buffer).length, 2);
  for (const b of [[0,0,0,0], [255,255,255,255], [0,2,0,1]]) assert.throws(() => new Framer().append(new Uint8Array(b).buffer));
  assert.throws(() => encodePacket(Object.assign(new Packet('text'), { text: 'x'.repeat(131072) })));
  console.log('PASS protocol: fragmented/coalesced UTF-8, big-endian framing, invalid lengths');
  const store = createStore('core'); const {channel, sent} = recordingChannel(store);
  assert.equal(store.hello().deviceType, 'Phone');
  const peer = crypto.randomUUID();
  await store.process(Object.assign(new Packet('hello'), {sender:peer, name:'Mac', deviceType:'PC', supportsProgress:true}), channel);
  assert.equal(store.peers[0].deviceType, 'PC');
  await store.process(Object.assign(new Packet('hello'), {sender:peer, name:'Phone', deviceType:'Phone'}), channel);
  assert.equal(store.peers[0].deviceType, 'Phone');
  await store.process(Object.assign(new Packet('hello'), {sender:peer, name:'Legacy'}), channel);
  assert.equal(store.peers[0].deviceType, '');
  let alerts = 0; let badge = -1;
  store.onIncoming = () => alerts++; store.onUnreadChange = count => badge = count;
  const text = Object.assign(new Packet('text'), {text:'你好'});
  await store.process(text, channel); await store.process(text, channel);
  assert.equal(store.messages.length, 1); assert.equal(sent.filter(p=>p.kind==='ack').length,2);
  assert.equal(alerts, 1); assert.equal(store.unreadCount(peer), 1); assert.equal(badge, 1);
  store.activePeer = peer; store.setForeground(true);
  assert.equal(store.unreadCount(), 0); assert.equal(badge, 0);
  const visible = Object.assign(new Packet('text'), {text:'前台消息'});
  await store.process(visible, channel);
  assert.equal(alerts, 2); assert.equal(store.unreadCount(), 0);
  store.setForeground(false);
  const background = Object.assign(new Packet('text'), {text:'后台消息'});
  await store.process(background, channel);
  assert.equal(store.unreadCount(), 1); assert.equal(badge, 1);
  store.markRead(peer); assert.equal(badge, 0);
  console.log('PASS unread: dedup notification, foreground read, background unread, badge clearing');
  const data = crypto.randomBytes(140000);
  const offer = Object.assign(new Packet('offer'), { name:'../../安全.bin', size:data.length, sentAt:1700000000123 });
  await store.process(offer, channel);
  assert.equal(store.messages.find(m=>m.id===offer.id).date,1700000000123);
  for (let offset=0; offset<data.length; offset+=49152) {
    await store.process(Object.assign(new Packet('chunk', offer.id), {data:data.subarray(offset,offset+49152).toString('base64')}),channel);
  }
  await store.process(new Packet('end',offer.id),channel);
  const received = store.messages.find(m=>m.id===offer.id);
  assert.equal(received.name,'安全.bin'); assert.equal(received.status,'已保存');
  assert.deepEqual(fs.readFileSync(received.path),data);
  const empty = Object.assign(new Packet('offer'),{ name:'安全.bin', size:0 });
  await store.process(empty,channel); await store.process(new Packet('end',empty.id),channel);
  assert.notEqual(store.messages.find(m=>m.id===empty.id).path,received.path);
  const broken=Object.assign(new Packet('offer'),{name:'broken.bin',size:20});
  await store.process(broken,channel);
  const partial=store.incoming.get(`${peer}:${broken.id}`).path;
  await store.process(new Packet('end',broken.id),channel);
  assert.equal(fs.existsSync(partial),false);
  const overflow=Object.assign(new Packet('offer'),{name:'overflow.bin',size:1});
  await store.process(overflow,channel);
  await store.process(Object.assign(new Packet('chunk',overflow.id),{data:'YWJj'}),channel);
  assert.equal(store.incoming.size,0);
  const sourceFile=path.join(temporary,'from-phone.bin');fs.writeFileSync(sourceFile,data);
  await store.stageUri(peer,sourceFile); assert.equal(store.attachments(peer).length,1);
  await store.submit(peer,'phone says hi');
  const outgoing=sent.findLast(p=>p.kind==='offer');
  await store.process(new Packet('accept',outgoing.id),channel);
  await wait(()=>sent.some(p=>p.kind==='end'&&p.id===outgoing.id),'outgoing completion');
  assert.deepEqual(Buffer.concat(sent.filter(p=>p.kind==='chunk'&&p.id===outgoing.id).map(p=>Buffer.from(p.data,'base64'))),data);
  await store.process(new Packet('complete',outgoing.id),channel);
  assert.equal(store.messages.find(m=>m.id===outgoing.id).status,'对方已接收');
  await store.submit(ASSISTANT_ID,'离线笔记');
  const toDelete = JSON.parse(JSON.stringify(store.messages.find(m=>m.id===text.id)));
  store.removeMessage(toDelete); assert(!store.messages.some(m=>m.id===text.id));
  const fileToDelete = JSON.parse(JSON.stringify(store.messages.find(m=>m.id===outgoing.id)));
  assert(fs.existsSync(fileToDelete.path));
  store.deleteMessage(fileToDelete);
  assert(!fs.existsSync(fileToDelete.path));
  assert(!store.messages.some(m=>m.id===fileToDelete.id));
  store.persist();
  const restored=new ChatStore(store.context);stores.push(restored);
  assert(!restored.messages.some(m=>m.id===fileToDelete.id));
  assert(restored.messages.some(m=>m.text==='离线笔记')); assert.equal(restored.peers[0].online,false);
  const timeout=Object.assign(new Packet('offer'),{name:'timeout',size:2});await store.process(timeout,channel);
  store.incoming.get(`${peer}:${timeout.id}`).lastProgress=Date.now()-130000;store.checkTransfers();
  assert.equal(store.incoming.size,0);
  console.log('PASS store: Phone handshake, type refresh, dedup/ack, binary+empty transfer, collision/path protection, overflow/incomplete cleanup, outgoing chunks, timeout, history, assistant, deletion');
}
async function attachmentOnly() {
  for (const extension of ['png','bin']) {
    const store=createStore(`attachment-only-${extension}`); const peer=crypto.randomUUID();
    const {channel,sent}=recordingChannel(store);
    await store.process(Object.assign(new Packet('hello'),{sender:peer,name:'Receiver'}),channel);
    assert.equal(await store.submit(peer,'   '),false);
    assert.equal(store.messages.length,0);
    const source=path.join(temporary,`only.${extension}`);
    const bytes=extension==='png' ? Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=','base64') : crypto.randomBytes(8000);
    fs.writeFileSync(source,bytes); await store.stageUri(peer,source);
    // Attachment-only submission must not depend on native empty-string encoding.
    const encodeInto = util.TextEncoder.prototype.encodeInto;
    util.TextEncoder.prototype.encodeInto = function (text) {
      assert.notEqual(text, '', 'attachment-only send must skip text encoding');
      return encodeInto.call(this, text);
    };
    try { assert.equal(await store.submit(peer,''),true); }
    finally { util.TextEncoder.prototype.encodeInto = encodeInto; }
    assert.equal(store.attachments(peer).length,0);
    assert.equal(sent.filter(p=>p.kind==='text').length,0);
    const offer=sent.find(p=>p.kind==='offer'); assert(offer);
    assert.equal(store.messages.length,1); assert.equal(store.messages[0].name,`only.${extension}`);
    await store.process(new Packet('accept',offer.id),channel);
    await wait(()=>sent.some(p=>p.kind==='end'&&p.id===offer.id),'attachment-only send');
    assert.deepEqual(Buffer.concat(sent.filter(p=>p.kind==='chunk').map(p=>Buffer.from(p.data,'base64'))),bytes);
    await store.process(new Packet('complete',offer.id),channel);
    assert.equal(store.messages[0].status,'对方已接收');
  }
  console.log('PASS attachment-only: image and file without text, exact bytes, receipt, empty submission rejected');
}
async function incomingShare() {
  const store = createStore('incoming-share');
  const peer = crypto.randomUUID();
  const { channel, sent } = recordingChannel(store);
  await store.process(Object.assign(new Packet('hello'), { sender: peer, name: 'Share receiver' }), channel);
  const original = path.join(temporary, 'share-file.bin');
  const bytes = crypto.randomBytes(9000); fs.writeFileSync(original, bytes);
  const draft = path.join(temporary, 'existing-draft.bin'); fs.writeFileSync(draft, 'draft');
  await store.stageUri(peer, draft);
  // Back-to-back Want deliveries must remain independent; no sends before confirmation.
  await Promise.all([
    store.receiveShare({ contact: { contactType: 'Contact', contactId: peer }, records: [{ utd: 'general.file', uri: `file://${original}` }] }),
    store.receiveShare({ records: [{ utd: 'general.file', uri: `file://${original}` }, { utd: 'general.file', uri: `file://${original}` }] })
  ]);
  assert.equal(store.incomingShares.length, 2);
  assert.equal(store.incomingShares[0].peer, peer);
  assert.equal(store.incomingShares[1].peer, '');
  assert.equal(store.incomingShares[1].files.length, 1);
  assert.notEqual(store.incomingShares[0].files[0].path, store.incomingShares[1].files[0].path);
  assert.equal(sent.filter(p => p.kind === 'offer').length, 0);
  const first = store.incomingShares[0];
  const canceledPath = store.incomingShares[1].files[0].path;
  store.cancelShare(store.incomingShares[1].id);
  assert(!fs.existsSync(canceledPath)); assert(fs.existsSync(original));
  const originalPersist = store.persist;
  store.persist = () => false;
  const donatedBeforeFailure = sharedContacts.length;
  assert.equal(await store.sendShare(first.id, peer), false);
  await delay(0);
  assert.equal(sharedContacts.length, donatedBeforeFailure);
  assert.equal(store.incomingShares.length, 1); assert.equal(store.messages.length, 0);
  assert(fs.existsSync(first.files[0].path));
  store.persist = originalPersist;
  const results = await Promise.all([store.sendShare(first.id, peer), store.sendShare(first.id, peer)]);
  assert.deepEqual(results, [true, false]);
  assert.equal(store.incomingShares.length, 0);
  await wait(() => sharedContacts.some(i => i.intentEntityInfo.entityId === peer), 'contact donation');
  const donated = sharedContacts.find(i => i.intentEntityInfo.entityId === peer);
  assert.equal(donated.intentEntityInfo.name, 'Share receiver');
  assert.equal(donated.intentEntityInfo.extras.shareParams.abilityName, 'EntryAbility');
  assert.equal(donated.intentActionInfo.actionMode, 'EXECUTED');
  assert.equal(store.attachments(peer).length, 1); // Existing composer files are untouched.
  assert.equal(store.messages.length, 1);
  const offer = sent.find(p => p.kind === 'offer'); assert(offer);
  await store.process(new Packet('accept', offer.id), channel);
  await wait(() => sent.some(p => p.kind === 'end' && p.id === offer.id), 'shared file transfer');
  assert.deepEqual(Buffer.concat(sent.filter(p => p.kind === 'chunk').map(p => Buffer.from(p.data, 'base64'))), bytes);
  await store.process(new Packet('complete', offer.id), channel);
  assert.equal(store.messages[0].status, '对方已接收');
  // A failed item rolls back the entire batch and leaves the receiver usable.
  const before = fs.readdirSync(path.join(store.root, 'files')).sort();
  await store.receiveShare({ records: [{ utd: 'general.file', uri: `file://${original}` }, { utd: 'general.file', uri: 'file:///missing-share-file' }] });
  assert.equal(store.incomingShares.length, 0);
  assert.deepEqual(fs.readdirSync(path.join(store.root, 'files')).sort(), before);
  assert.match(store.error, /接收分享失败/);
  await store.receiveShare({ records: Array.from({ length: 10 }, () => ({ utd: 'general.file', uri: `file://${original}` })) });
  assert.equal(store.incomingShares.length, 0);
  await store.receiveShare({ records: [{ utd: 'general.file', uri: 'https://example.com/file' }] });
  assert.equal(store.incomingShares.length, 0);
  await store.receiveShare({ records: [{ utd: 'general.plain-text', content: '外部文字' }, { utd: 'general.hyperlink', content: 'https://example.com' }] });
  assert.equal(await store.sendShare(store.incomingShares[0].id, ASSISTANT_ID), true);
  assert.equal(store.messages.at(-1).text, '外部文字\nhttps://example.com');
  await store.receiveShare({ parseError: true, uri: `file://${original}` });
  assert.equal(store.incomingShares.length, 1);
  assert.equal(await store.sendShare(store.incomingShares[0].id, ASSISTANT_ID), true);
  assert.deepEqual(fs.readFileSync(store.messages.at(-1).path), bytes);
  await store.receiveShare({ parseError: true });
  assert.equal(store.incomingShares.length, 0);
  await store.receiveShare({ records: [{ utd: 'general.plain-text', content: '文'.repeat(12000) }] });
  assert.equal(store.incomingShares.length, 0);
  // Stale or empty IDs must not preselect any recipient.
  for (const contact of [
    { contactType: 'Contact', contactId: 'removed-device' },
    { contactType: 'Contact', contactId: '' }
  ]) {
    await store.receiveShare({ contact, records: [{ utd: 'general.plain-text', content: 'test' }] });
    assert.equal(store.incomingShares[0].peer, '');
    store.cancelShare(store.incomingShares[0].id);
  }
  rejectContactDonation = true;
  await store.receiveShare({ contact: { contactType: 'Contact', contactId: ASSISTANT_ID },
    records: [{ utd: 'general.plain-text', content: 'allowlist fallback' }] });
  assert.equal(store.incomingShares[0].peer, ASSISTANT_ID);
  assert.equal(await store.sendShare(store.incomingShares[0].id, ASSISTANT_ID), true);
  await delay(0);
  rejectContactDonation = false;
  store.peers.find(p => p.id === peer).online = false;
  store.removePeer(store.peers.find(p => p.id === peer));
  await wait(() => removedContacts.includes(peer), 'contact removal');
  // Queue remains usable after parse and size failures.
  await store.receiveShare({ records: [{ utd: 'general.file', uri: `file://${original}` }] });
  store.cancelShare(store.incomingShares[0].id);
  assert.equal(store.incomingShares.length, 0);
  console.log('PASS incoming share: serialized imports, dedup, explicit confirmation, cancellation cleanup, save failure retry, draft isolation, exact-byte transfer, rollback, limits, text/link assistant, recommended contact routing/donation/removal, unavailable service fallback');
}
async function offlineDelivery() {
  const store = createStore('offline'); const peer = crypto.randomUUID();
  store.peers.push({id:peer,name:'Offline',online:false});
  assert.equal(await store.submit(peer,'重启后留言'),true);
  const source = path.join(temporary,'offline.bin'); const bytes = crypto.randomBytes(120000);
  fs.writeFileSync(source,bytes); await store.stageUri(peer,source);
  assert.equal(await store.submit(peer,''),true); fs.unlinkSync(source);
  const cancelled = await store.submit(peer,'取消留言'); assert(cancelled);
  store.removeMessage(store.messages.at(-1));
  const originalDate=1700000000123;
  store.messages.forEach(m=>m.date=originalDate); store.persist();
  const restored = createStore('offline');
  assert.equal(restored.messages.length,2); assert(restored.messages.every(m=>m.pendingDelivery&&m.status==='等待对方上线'));
  const {channel,sent} = recordingChannel(restored);
  await restored.process(Object.assign(new Packet('hello'),{sender:peer,name:'Receiver'}),channel);
  assert.equal(sent.filter(p=>p.kind==='text').length,1);
  assert.equal(sent.filter(p=>p.kind==='offer').length,1);
  assert(sent.filter(p=>p.kind==='text'||p.kind==='offer').every(p=>p.sentAt===originalDate));
  const receivedText=Object.assign(new Packet('text'),{text:'原始时间',sentAt:originalDate});
  await restored.process(receivedText,channel);
  assert.equal(restored.messages.find(m=>m.id===receivedText.id).date,originalDate);
  await restored.process(Object.assign(new Packet('text',receivedText.id),{text:'原始时间',sentAt:Date.now()}),channel);
  assert.equal(restored.messages.find(m=>m.id===receivedText.id).date,originalDate);
  for (const sentAt of [undefined,-1,Infinity,253402300800000,'invalid']) {
    assert(Math.abs(messageDate({sentAt})-Date.now())<1000);
  }
  const text = restored.messages.find(m=>m.mine&&!m.name); const file = restored.messages.find(m=>m.name);
  await restored.process(new Packet('ack',text.id),channel);
  await restored.process(new Packet('accept',file.id),channel);
  await wait(()=>sent.some(p=>p.kind==='end'&&p.id===file.id),'offline file end');
  assert.deepEqual(Buffer.concat(sent.filter(p=>p.kind==='chunk').map(p=>Buffer.from(p.data,'base64'))),bytes);
  await restored.process(new Packet('complete',file.id),channel);
  const count=sent.length; await restored.flushOutbox(peer);
  assert.equal(sent.length,count); assert(restored.messages.every(m=>!m.pendingDelivery));
  // Lost completion: repeated offer for an already received file acknowledges it again.
  const received = {id:'received-again',peer,mine:false,name:'a.bin',bytes:3,status:'已保存'};
  restored.messages.push(received);
  await restored.process(Object.assign(new Packet('offer',received.id),{name:'a.bin',size:3}),channel);
  assert.equal(sent.at(-1).kind,'complete'); assert.equal(restored.messages.filter(m=>m.id===received.id).length,1);
  console.log('PASS offline: durable text/file queue, restart, source removal, cancellation, reconnect, receipt deduplication');
}
async function folders() {
  const store = createStore('folders'); const { channel, sent } = recordingChannel(store);
  const peer = crypto.randomUUID();
  await store.process(Object.assign(new Packet('hello'), { sender: peer, name: 'Folder peer', supportsFolders: true }), channel);
  const offer = (id, name, size, entryCount) => Object.assign(new Packet('offer', id), { name, size, isDirectory: true, entryCount });
  const entry = (id, name, size, isDirectory) => Object.assign(new Packet('entry', id), { name, size, isDirectory });
  await store.process(offer('valid', '目录', 3, 3), channel);
  await store.process(entry('valid', '空目录', 0, true), channel);
  await store.process(entry('valid', '空文件', 0, false), channel);
  await store.process(entry('valid', '文本', 3, false), channel);
  await store.process(Object.assign(new Packet('chunk', 'valid'), {data: Buffer.from('abc').toString('base64')}), channel);
  await store.process(new Packet('end', 'valid'), channel);
  const saved = store.messages.find(m => m.id === 'valid');
  assert.equal(saved.status, '已保存'); assert(saved.isDirectory);
  assert.equal(fs.readFileSync(path.join(saved.path, '文本'), 'utf8'), 'abc');
  assert(fs.statSync(path.join(saved.path, '空目录')).isDirectory());
  assert.equal(fs.statSync(path.join(saved.path, '空文件')).size, 0);
  await store.process(offer('collision', '目录', 0, 0), channel);
  await store.process(new Packet('end', 'collision'), channel);
  const collision = store.messages.find(m => m.id === 'collision');
  assert.equal(collision.status, '已保存'); assert.notEqual(collision.path, saved.path);
  for (const bad of ['../escape', '/absolute', 'a/../b', 'a//b', 'a/', 'a\\b', 'a\0b']) {
    const id = crypto.randomUUID();
    await store.process(offer(id, 'unsafe', 0, 1), channel);
    const partial = store.incoming.get(`${peer}:${id}`).path;
    await store.process(entry(id, bad, 0, false), channel);
    assert(!store.incoming.has(`${peer}:${id}`)); assert(!fs.existsSync(partial));
    assert(sent.some(p => p.id === id && p.kind === 'reject'));
  }
  for (const [id, size, count] of [['incomplete', 0, 1], ['short-file', 3, 1], ['duplicate', 0, 2]]) {
    await store.process(offer(id, id, size, count), channel);
    const partial = store.incoming.get(`${peer}:${id}`).path;
    if (id === 'short-file') { await store.process(entry(id, 'file', 3, false), channel); }
    if (id === 'duplicate') {
      await store.process(entry(id, 'same', 0, true), channel);
      await store.process(entry(id, 'same', 0, true), channel);
    }
    await store.process(new Packet('end', id), channel);
    assert.notEqual(store.messages.find(m => m.id === id).status, '已保存'); assert(!fs.existsSync(partial));
  }
  await store.process(offer('cancel', 'cancel', 0, 1), channel);
  const partial = store.incoming.get(`${peer}:cancel`).path;
  await store.process(entry('cancel', 'nested', 0, true), channel);
  store.fail(`${peer}:cancel`, '连接断开，请重试', false);
  assert(!fs.existsSync(partial));
  const original = path.join(temporary, '离线 文件夹');
  fs.mkdirSync(path.join(original, '嵌套', '空目录'), { recursive: true });
  fs.writeFileSync(path.join(original, '嵌套', '内容'), 'folder bytes');
  const offline = createStore('folder-offline');
  await offline.stageUri(peer, original); assert(offline.attachments(peer)[0].isDirectory);
  await offline.submit(peer, ''); fs.rmSync(original, { recursive: true });
  const restored = createStore('folder-offline');
  const r = recordingChannel(restored);
  await restored.process(Object.assign(new Packet('hello'), { sender: peer, name: 'Old peer' }), r.channel);
  assert(!r.sent.some(p => p.kind === 'offer')); assert(restored.messages[0].pendingDelivery);
  await restored.process(Object.assign(new Packet('hello'), { sender: peer, name: 'New peer', supportsFolders: true }), r.channel);
  const pending = r.sent.find(p => p.kind === 'offer'); assert(pending.isDirectory); assert.equal(pending.entryCount, 3);
  await restored.process(new Packet('accept', pending.id), r.channel);
  await wait(() => r.sent.some(p => p.kind === 'end'), 'offline folder transmission');
  assert.equal(Buffer.concat(r.sent.filter(p => p.kind === 'chunk').map(p => Buffer.from(p.data, 'base64'))).toString(), 'folder bytes');
  await restored.process(new Packet('complete', pending.id), r.channel);
  assert(!restored.messages[0].pendingDelivery);
  const exportRoot = path.join(temporary, 'folder-export'); fs.mkdirSync(exportRoot);
  pickedDirectory = [require('node:url').pathToFileURL(exportRoot).href];
  const limitedFileUri = new FileUriAdapter(pickedDirectory[0]);
  assert.equal(limitedFileUri.addSegment, undefined, 'FileUri adapter must not invent URI methods');
  assert.equal(limitedFileUri.getSegment, undefined, 'FileUri is not a URI runtime subclass');
  assert.throws(() => limitedFileUri.addSegment('child'), /addSegment/, 'reproduce the real-device missing-method error');
  const savedPath = saved.path;
  await store.exportFile(saved);
  assert.equal(saved.path, ''); assert(saved.savedUri); assert(!fs.existsSync(savedPath));
  assert.equal(fs.readFileSync(path.join(exportRoot, '目录', '文本'), 'utf8'), 'abc');
  assert(fs.statSync(path.join(exportRoot, '目录', '空目录')).isDirectory());
  fs.mkdirSync(path.join(exportRoot, path.basename(collision.path))); store.error = '';
  const collisionSource = collision.path;
  await store.exportFile(collision);
  assert.match(store.error, /已存在/); assert.equal(collision.path, collisionSource); assert(fs.existsSync(collisionSource));
  assert.equal(fs.readFileSync(path.join(exportRoot, '目录', '文本'), 'utf8'), 'abc');
  const preciseName = '一部分待提取的图片 100% #相册';
  const preciseSource = path.join(temporary, preciseName);
  fs.mkdirSync(path.join(preciseSource, '子目录', '空目录'), { recursive: true });
  fs.writeFileSync(path.join(preciseSource, '子目录', '照片.txt'), '中文及特殊字符');
  const preciseUri = require('node:url').pathToFileURL(preciseSource).href;
  const nonexistentDestination = require('node:url').pathToFileURL(path.join(temporary, 'missing-destination')).href;
  await assert.rejects(fsAdapter.copy(preciseUri, nonexistentDestination), error => error.code === 13900020, 'old child-destination call reproduces Invalid argument');
  const importedStore = createStore('native-folder-copy');
  await importedStore.stageUri(ASSISTANT_ID, preciseUri);
  const importedFolder = importedStore.attachments(ASSISTANT_ID)[0];
  assert.equal(fs.readFileSync(path.join(importedFolder.path, '子目录', '照片.txt'), 'utf8'), '中文及特殊字符');
  assert(!fs.existsSync(path.join(importedFolder.path, preciseName)), 'import must not double-nest the root');
  assert(fs.statSync(path.join(importedFolder.path, '子目录', '空目录')).isDirectory());
  await importedStore.submit(ASSISTANT_ID, '');
  const importedMessage = importedStore.messages.at(-1);
  const sourceBeforeFailure = importedMessage.path;
  const failureDestination = path.join(temporary, 'save-failure'); fs.mkdirSync(failureDestination);
  pickedDirectory = [require('node:url').pathToFileURL(failureDestination).href];
  failFolderCopy = true;
  await importedStore.exportFile(importedMessage);
  assert.equal(importedMessage.path, sourceBeforeFailure);
  assert.equal(importedMessage.savedUri, '');
  assert.equal(fs.readFileSync(path.join(sourceBeforeFailure, '子目录', '照片.txt'), 'utf8'), '中文及特殊字符');
  assert.match(importedStore.error, /13900028/);
  const cacheBeforeFailure = fs.readdirSync(path.join(importedStore.root, 'files')).sort();
  await assert.rejects(importedStore.stageUri(ASSISTANT_ID, preciseUri));
  assert.deepEqual(fs.readdirSync(path.join(importedStore.root, 'files')).sort(), cacheBeforeFailure, 'failed imports clean their isolated staging tree');
  failFolderCopy = false;
  const successDestination = path.join(temporary, '选择保存目录 100% #'); fs.mkdirSync(successDestination);
  // Use a document-provider authority, not a sandbox URI.
  const documentUri = new URL(require('node:url').pathToFileURL(successDestination).href);
  documentUri.hostname = 'docs';
  pickedDirectory = [documentUri.href];
  const beforeCopies = copyCalls.length;
  await Promise.all([importedStore.exportFile(importedMessage), importedStore.exportFile(importedMessage)]);
  assert.equal(copyCalls.length - beforeCopies, 1, 'repeated taps cannot move the same folder twice');
  assert.equal(copyCalls.at(-1).destination, documentUri.href, 'the exact picker-granted parent URI is passed to native copy');
  assert.equal(fs.readFileSync(path.join(successDestination, preciseName, '子目录', '照片.txt'), 'utf8'), '中文及特殊字符');
  assert(!fs.existsSync(sourceBeforeFailure));
  assert.equal(importedMessage.path, '');
  assert.equal(nativePath(importedMessage.savedUri), path.join(successDestination, preciseName));
  assert.equal(new URL(importedMessage.savedUri).hostname, 'docs');
  assert(fs.existsSync(preciseSource), 'selected source folders are not removed by import');
  pickedDirectory = [];
  console.log('PASS native folder copy: FileUri without inherited URI methods, explicit ArkTS URI class, existing-parent contract, original Invalid argument reproduction, no double nesting, Chinese/space/percent/hash names, document-provider URI, partial copy failure keeps source, import cleanup, retry and repeated-tap protection');
  console.log('PASS folders: nested/empty directories and files, collision handling, traversal/duplicate/missing entries, short files, cancellation cleanup, durable offline folder queue, old-client negotiation, folder export and overwrite protection');
}
async function scrollNavigation() {
  global.Edge = { Bottom: 1 }; global.Curve = { EaseOut: 1 };
  global.Scroller = class {
    offset = 0; maximum = 9000; calls = [];
    currentOffset() { return { xOffset: 0, yOffset: this.offset }; }
    isAtEnd() { return this.offset === this.maximum; }
    scrollEdge() { this.offset = this.maximum; this.calls.push(this.offset); }
    scrollTo(options) { this.offset = Math.min(this.maximum, options.yOffset); this.calls.push(this.offset); }
  };
  const { Index } = load(`${source}/pages/Index.ets`);
  const store = createStore('scroll-navigation');
  const page = new Index(); page.store = store; page.pageActive = true; page.isWide = true;
  const frames = [];
  page.getUIContext = () => ({ postFrameCallback: frame => frames.push(frame),
    getFocusController: () => ({ clearFocus() {} }), animateTo: (options, action) => { action(); options.onFinish?.(); } });
  const layout = () => { for (let n = 0; frames.length && n < 20; n++) { const batch = frames.splice(0); for (const frame of batch) frame.onIdle(0); } assert.equal(frames.length, 0); };
  const a = crypto.randomUUID(), b = crypto.randomUUID(), fresh = crypto.randomUUID();
  store.peers = [a, b, fresh].map(id => ({ id, name: id, online: false }));
  store.messages = [a, b].flatMap(peer => Array.from({ length: 30 }, (_, index) => ({ id: `${peer}-${index}`, peer, mine: false, text: '历史消息', name: '', unread: false })));
  store.saveScrollPosition(a, { offset: 375, atBottom: false });
  store.saveScrollPosition(b, { offset: 875, atBottom: false });
  assert.equal(createStore('scroll-navigation').scrollPosition(a).offset, 375);
  page.selectPeer(a); layout(); assert.equal(page.scroller.offset, 375);
  page.scroller.offset = 520; page.saveScrollPosition();
  page.selectPeer(b); layout(); assert.equal(page.scroller.offset, 875);
  page.selectPeer(a); layout(); assert.equal(page.scroller.offset, 520);
  const before = page.scroller.calls.length;
  store.messages.push({ id: 'visible-new', peer: a, mine: false, text: '新消息', name: '', unread: false });
  page.updateState(); layout(); assert.equal(page.scroller.calls.length, before, 'reading older messages does not jump');
  page.selectPeer(b); layout();
  store.messages.find(m => m.peer === a).unread = true;
  page.selectPeer(a); layout(); assert.equal(page.scroller.offset, page.scroller.maximum);
  assert.equal(store.unreadCount(a), 0, 'unread captured before badge clears');
  page.scroller.offset = 650; page.followLatest = false; page.saveScrollPosition();
  page.changeHistoryQuery('查找'); page.scroller.offset = 10;
  page.changeHistoryQuery(''); layout(); assert.equal(page.scroller.offset, 650, 'search does not overwrite reading bookmark');
  page.selectPeer(b); page.selectPeer(a); layout(); assert.equal(page.scroller.offset, 650, 'stale frame callback cannot scroll another contact');
  page.scrollToLatest(); layout(); assert.equal(page.scroller.offset, page.scroller.maximum);
  assert.equal(store.scrollPosition(a).atBottom, true);
  page.selectPeer(fresh); layout(); assert.equal(page.scroller.offset, page.scroller.maximum, 'first visit starts at latest');
  page.selectPeer(b); layout(); page.scroller.offset = 432;
  page.goBack(); layout(); assert.equal(page.selected, ''); assert.equal(store.scrollPosition(b).offset, 432);
  store.requestedPeer = a; store.messages.find(m => m.peer === a).unread = true;
  page.updateState(); layout(); assert.equal(page.selected, a); assert.equal(page.scroller.offset, page.scroller.maximum);
  store.saveScrollPosition(a, { offset: -1, atBottom: false }); assert(store.scrollPosition(a).offset >= 0);
  console.log('PASS scroll controller: per-contact persistence/restart, unread-before-markRead, first visit, exact offset restore, search isolation, latest action, no forced jump while reading, fast contact switches, back navigation and notification entry (Node UI adapter)');
}
async function networkRecovery() {
  const { LanNetwork } = load(`${source}/network/LanNetwork.ets`);
  const native = { servers: [], discoveries: [], clients: [], registrations: new Map(), removed: [],
    failAdd: 0, failRemove: 0, skipStart: 0, nextListen: undefined, resolveHook: undefined, remotes: [] };
  class Events {
    handlers = new Map();
    on(event, callback) { this.handlers.set(event, callback); }
    off(event) { this.handlers.delete(event); }
    emit(event, value) { this.handlers.get(event)?.(value); }
  }
  class Server extends Events {
    closed = false;
    constructor() { super(); this.port = 20000 + native.servers.length; native.servers.push(this); }
    async listen() { if (native.nextListen) { const task = native.nextListen; native.nextListen = undefined; await task; } }
    async getLocalAddress() { return { address: '0.0.0.0', port: this.port }; }
    async close() { this.closed = true; }
  }
  class Discovery extends Events {
    stopped = false;
    constructor() { super(); native.discoveries.push(this); }
    startSearchingMDNS() {
      if (native.skipStart > 0) { native.skipStart--; return; }
      this.emit('discoveryStart', { errorCode: 0 });
      for (const service of native.remotes) this.emit('serviceFound', service);
    }
    stopSearchingMDNS() { this.stopped = true; this.emit('discoveryStop', { errorCode: 0 }); }
  }
  class Client extends Events {
    closed = false; silent = false;
    constructor() { super(); native.clients.push(this); }
    async bind() {}
    async connect(options) { this.port = options.address.port; }
    async send({data}) {
      if (this.closed) throw new Error('socket closed');
      if (this.silent) return;
      for (const packet of new Framer().append(data)) {
        const reply = packet.kind === 'hello' ? Object.assign(new Packet('hello'), {
          sender: native.remotes.find(service => service.port === this.port)?.serviceName, supportsHeartbeat: true
        }) : packet.kind === 'ping' ? new Packet('pong', packet.id) : undefined;
        if (reply) queueMicrotask(() => { if (!this.closed) this.emit('message', { message: encodePacket(reply) }); });
      }
    }
    async close() { if (!this.closed) { this.closed = true; queueMicrotask(() => this.emit('close')); } }
  }
  const socketKit = kits['@kit.NetworkKit'].socket, mdnsKit = kits['@kit.NetworkKit'].mdns;
  socketKit.constructTCPSocketServerInstance = () => new Server();
  socketKit.constructTCPSocketInstance = () => new Client();
  mdnsKit.addLocalService = async (_, service) => {
    if (native.failAdd > 0) { native.failAdd--; throw new Error('mDNS unavailable after resume'); }
    if (native.registrations.has(service.serviceName)) throw new Error('service already registered');
    const value = { ...service }; native.registrations.set(value.serviceName, value); return value;
  };
  mdnsKit.removeLocalService = async (_, service) => {
    if (native.failRemove > 0) { native.failRemove--; throw new Error('mDNS remove unavailable'); }
    const current = native.registrations.get(service.serviceName);
    if (current && current.port !== service.port) throw new Error('obsolete service port');
    native.removed.push(service); native.registrations.delete(service.serviceName);
  };
  mdnsKit.createDiscoveryService = () => new Discovery();
  mdnsKit.resolveLocalService = async (_, service) => native.resolveHook ? native.resolveHook(service) : { ...service, host: { address: '127.0.0.1' } };
  const deviceId = crypto.randomUUID(), remote = { serviceName: crypto.randomUUID(), serviceType: '_lanternchat._tcp', port: 30100 };
  native.remotes.push(remote);
  const network = new LanNetwork({}, deviceId, () => Object.assign(new Packet('hello'), { sender: deviceId, supportsHeartbeat: true }));
  network.operationTimeout = 80; network.cleanupTimeout = 20;
  const states = [], closed = [];
  network.onState = (ready, detail) => states.push({ ready, detail });
  network.onClose = channel => closed.push(channel.id);
  network.onPacket = async (packet, channel) => {
    if (packet.kind === 'hello') { channel.peer = packet.sender; channel.heartbeat = packet.supportsHeartbeat === true; }
    if (packet.kind === 'ping') await channel.send(new Packet('pong', packet.id));
  };
  const retry = async () => {
    network.retryAt = 0; network.tick();
    await wait(() => network.resourcesReady && !network.starting && !network.recoveryQueued, 'automatic network recovery');
  };
  try {
    await Promise.all([network.start(), network.start()]);
    assert.equal(native.servers.length, 1, 'concurrent start calls share a listener');
    assert(network.resourcesReady); assert.equal(states.at(-1).ready, true, 'errorCode zero is success');
    await wait(() => network.channelFor(remote.serviceName), 'initial mDNS/TCP handshake');
    const healthy = network.channelFor(remote.serviceName);
    const firstServer = native.servers.at(-1), firstDiscovery = native.discoveries.at(-1);
    const staleFound = firstDiscovery.handlers.get('serviceFound');
    const staleAccept = firstServer.handlers.get('connect');
    await network.resume();
    await wait(() => healthy.resumeProbeDeadline === 0, 'foreground ping receives pong');
    assert.equal(network.channelFor(remote.serviceName), healthy, 'healthy TCP sessions survive resource recovery');
    assert(firstServer.closed); assert(firstDiscovery.stopped);
    assert.notEqual(native.servers.at(-1).port, firstServer.port);
    assert.equal(native.registrations.get(deviceId).port, native.servers.at(-1).port, 'fresh listening port is advertised for Mac');
    const phantom = { serviceName: crypto.randomUUID(), serviceType: remote.serviceType, port: 30101 };
    staleFound(phantom); assert(!network.found.has(phantom.serviceName), 'stale discovery callbacks are ignored');
    let staleConnectionClosed = false;
    staleAccept({ close: async () => { staleConnectionClosed = true; } });
    assert(staleConnectionClosed, 'an old listener cannot accept a new channel');
    // A retained socket can silently die in background without close/error events.
    healthy.client.silent = true; healthy.lastSeen = Date.now() - 120000;
    await network.resume(); network.tick();
    assert(network.channels.includes(healthy), 'foreground probe grants a response grace period');
    healthy.resumeProbeDeadline = Date.now() - 1; network.tick();
    await wait(() => network.channelFor(remote.serviceName) && network.channelFor(remote.serviceName) !== healthy, 'silent background socket reconnects');
    assert.equal(closed.filter(id => id === healthy.id).length, 1);
    // Old async resolutions must not clear a newer attempt for the same peer.
    const slow = { serviceName: crypto.randomUUID(), serviceType: remote.serviceType, port: 30102 };
    native.remotes.push(slow);
    let resolveOld, resolveNew, resolutions = 0;
    native.resolveHook = service => service.serviceName !== slow.serviceName ? Promise.resolve({ ...service, host: { address: '127.0.0.1' } }) :
      new Promise(resolve => { if (++resolutions === 1) resolveOld = resolve; else resolveNew = resolve; });
    network.discovery.emit('serviceFound', slow);
    await wait(() => resolveOld, 'old slow resolution');
    await network.resume(); await wait(() => resolveNew, 'fresh slow resolution');
    resolveOld({ ...slow, host: { address: '127.0.0.1' } }); await delay(0);
    assert(network.connecting.has(slow.serviceName), 'old resolution cannot erase the new generation attempt');
    resolveNew({ ...slow, host: { address: '127.0.0.1' } });
    await wait(() => network.channelFor(slow.serviceName), 'new generation connects');
    native.resolveHook = undefined;
    network.server.emit('error', new Error('listener invalidated in background'));
    assert(!network.resourcesReady); await retry();
    network.discovery.emit('discoveryStop', { errorCode: 1 });
    assert(!network.resourcesReady); await retry();
    // Failed unregisters need to be retried, otherwise a stale advertisement
    // prevents registering this same stable device ID indefinitely.
    native.failRemove = 2;
    await network.resume(); assert(!network.resourcesReady); assert(network.staleRegistrations.length > 0);
    await retry(); assert.equal(network.staleRegistrations.length, 0);
    network.rememberStaleRegistration({ ...network.registered, port: firstServer.port });
    await network.resume();
    assert(network.resourcesReady, 'cleanup uses the latest advertisement port, not stale metadata');
    native.failAdd = 1;
    await network.resume(); assert(!network.resourcesReady);
    await retry();
    native.skipStart = 1;
    await network.resume(); assert(!network.resourcesReady, 'missing discovery-start event is bounded, not falsely ready');
    await retry();
    // An old resolver that never completes cannot permanently block retries.
    const hanging = { serviceName: crypto.randomUUID(), serviceType: remote.serviceType, port: 30103 };
    native.remotes.push(hanging);
    let hangOnce = true;
    native.resolveHook = service => service.serviceName === hanging.serviceName && hangOnce ?
      (hangOnce = false, new Promise(() => {})) : Promise.resolve({ ...service, host: { address: '127.0.0.1' } });
    network.discovery.emit('serviceFound', hanging);
    await wait(() => !network.connecting.has(hanging.serviceName), 'stuck resolver times out');
    network.tick(); await wait(() => network.channelFor(hanging.serviceName), 'resolution retries after timeout');
    native.resolveHook = undefined;
    let finishListen;
    native.nextListen = new Promise(resolve => { finishListen = resolve; });
    const serverCount = native.servers.length;
    const resuming = network.resume();
    await wait(() => native.servers.length > serverCount, 'pending foreground startup');
    const stopping = network.stop(); finishListen();
    await Promise.all([resuming, stopping]);
    assert(!network.active); assert.equal(network.channels.length, 0); assert.equal(native.registrations.size, 0);
    const stoppedCount = native.servers.length; network.tick(); await delay(0);
    assert.equal(native.servers.length, stoppedCount, 'stop cancels pending startup and automatic retries');
    await network.start(); assert(network.resourcesReady, 'explicit start after stop can recover again');
    console.log('PASS network recovery: concurrent start serialization, foreground listener/advertisement/browser recreation, zero discovery error code, live-session probe, silent socket reconnect, stale callbacks/resolves, listener/browser failures, unregister/add failures, bounded discovery/resolve waits, stop/start cancellation');
  } finally { await network.stop(); }
  // Run the actual Ability callbacks against a lifecycle recorder.
  kits['@kit.AbilityKit'] = { UIAbility: class {} };
  kits['@kit.NotificationKit'] = { notificationManager: {} };
  kits['@kit.PerformanceAnalysisKit'].hilog.info = () => {};
  const { default: EntryAbility } = load(`${source}/entryability/EntryAbility.ets`);
  const lifecycleCalls = [];
  const originalShared = ChatStore.shared;
  ChatStore.shared = () => ({ setForeground: value => lifecycleCalls.push(value ? 'foreground' : 'background'),
    start: () => lifecycleCalls.push('start'), resumeNetwork: () => lifecycleCalls.push('resume'), refresh: () => lifecycleCalls.push('refresh') });
  try {
    const ability = new EntryAbility();
    ability.onForeground(); ability.onBackground(); ability.onForeground(); ability.onForeground();
    assert.deepEqual(lifecycleCalls, ['foreground', 'start', 'background', 'foreground', 'resume', 'foreground', 'start']);
    console.log('PASS Ability lifecycle: first foreground starts once; returning from background resumes network; no start/refresh race');
  } finally { ChatStore.shared = originalShared; }
}

async function interop() {
  const macRoot=process.env.LANCHAT_MAC_SOURCE || '/Users/sunshine/SwiftProjects/local-chat';
  if (!fs.existsSync(path.join(macRoot,'Sources/LanChat/ChatStore.swift'))) throw new Error('Set LANCHAT_MAC_SOURCE to Mac project for interoperability test');
  const harness=path.join(root,'scripts/MacInterop.swift'); const binary=path.join(temporary,'MacInterop');
  const swiftSources=['Wire.swift','ChatStore.swift','AssistantArchive.swift','ChatHistory.swift','BonjourFallback.swift'].map(f=>path.join(macRoot,'Sources/LanChat',f));
  execFileSync('swiftc',['-parse-as-library',...swiftSources,harness,'-o',binary],{stdio:'pipe'});
  const mac = spawn(binary,[path.join(temporary,'mac')],{stdio:['ignore','pipe','pipe']});
  let log='';let macError='';let exited=false;let macCode;
  mac.stdout.on('data',b=>log+=b);mac.stderr.on('data',b=>macError+=b);
  mac.on('exit',code=>{exited=true;macCode=code;});
  try {
    await wait(()=>log.includes('PORT:'),'Mac listener',15000);
    const port=Number(log.match(/PORT:(\d+)/)[1]);
    const store=createStore('interop'); const channel=new Channel();
    const connection=net.createConnection({host:'127.0.0.1',port});
    channel.client={ send:({data})=>new Promise((resolve,reject)=>connection.write(Buffer.from(data),error=>error?reject(error):resolve())),close:async()=>connection.destroy() };
    store.network.channels.push(channel);
    let inbound=Promise.resolve();let error;
    connection.on('data',buffer=>{
      const array=Uint8Array.from(buffer);
      inbound=inbound.then(async()=>{ for(const packet of channel.framer.append(array.buffer)) await store.process(packet,channel); }).catch(e=>{error=e;});
    });
    await new Promise((resolve,reject)=>{connection.once('connect',resolve);connection.once('error',reject);});
    await channel.send(store.hello());
    await wait(()=>channel.peer,'Mac hello');assert.equal(store.peers[0].deviceType,'PC');
    await store.submit(channel.peer,'来自鸿蒙的中文消息 👋');
    await wait(()=>store.messages.some(m=>m.text==='来自 Mac 的回复 👋'),'Mac reply');
    await wait(()=>store.messages.some(m=>m.name==='mac-fixture.bin'&&m.status==='已保存'),'Mac file');
    const fromMac=store.messages.find(m=>m.name==='mac-fixture.bin');
    const expected=Buffer.from(Array.from({length:180000},(_,i)=>i%251));
    assert.deepEqual(fs.readFileSync(fromMac.path),expected);
    await wait(()=>store.messages.some(m=>m.name==='mac-folder 中文'&&m.status==='已保存'),'Mac folder');
    await wait(()=>store.messages.some(m=>m.name==='mac-empty'&&m.status==='已保存'),'Mac empty folder');
    const macFolder=store.messages.find(m=>m.name==='mac-folder 中文'); assert(macFolder.isDirectory);
    assert.deepEqual(fs.readFileSync(path.join(macFolder.path,'子目录','data.bin')),expected);
    assert(fs.statSync(path.join(macFolder.path,'子目录','空目录')).isDirectory());
    assert.equal(fs.statSync(path.join(macFolder.path,'zero')).size,0);
    const phoneFolder=path.join(temporary,'phone-folder 中文');
    fs.mkdirSync(path.join(phoneFolder,'子目录','空目录'),{recursive:true});
    fs.writeFileSync(path.join(phoneFolder,'子目录','data.bin'),expected);fs.writeFileSync(path.join(phoneFolder,'zero'),'');
    const phoneEmpty=path.join(temporary,'phone-empty');fs.mkdirSync(phoneEmpty);
    await store.stageUri(channel.peer,phoneFolder); await store.stageUri(channel.peer,phoneEmpty); await store.submit(channel.peer,'');
    const upload=path.join(temporary,'phone-fixture.bin');fs.writeFileSync(upload,expected);
    await store.stageUri(channel.peer,upload);await store.submit(channel.peer,'');
    await wait(()=>store.messages.some(m=>m.name==='phone-fixture.bin'&&m.status==='对方已接收'),'Phone file delivery');
    await wait(()=>log.includes('MAC_PASS'),'Mac verification');
    assert(!error,error?.message);connection.destroy();
    console.log('PASS real TCP interoperability: original Swift ChatStore ↔ ArkTS store (Node platform adapter), PC/Phone, Chinese messages, bidirectional 180 KB files, native folders, Unicode paths, nested/empty directories, zero-byte files and receipt confirmation');
  } finally { mac.kill(); }
}
(async()=>{
  try { await core(); await attachmentOnly(); await incomingShare(); await offlineDelivery(); await folders(); await scrollNavigation(); await networkRecovery(); await interop(); }
  finally { for(const store of stores) await store.stop(); fs.rmSync(temporary,{recursive:true,force:true}); }
})().catch(error=>{console.error(error);process.exitCode=1;});
