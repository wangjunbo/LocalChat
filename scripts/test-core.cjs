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
const kits = {
  '@kit.ShareKit': { systemShare: { getSharedData: async want => {
    if (want.parseError) throw new Error('Invalid share data');
    return { getRecords: () => want.records || [] };
  } } },
  '@kit.ArkTS': { util }, '@kit.NetworkKit': { socket: {}, mdns: {} },
  '@kit.ArkData': { preferences: { getPreferencesSync: context => {
    if (!prefCache.has(context.filesDir)) prefCache.set(context.filesDir, new Map());
    const values = prefCache.get(context.filesDir);
    return { getSync: (key, fallback) => values.get(key) ?? fallback, putSync: (key, value) => values.set(key, value), flush: async () => {} };
  } } },
  '@kit.CoreFileKit': { fileIo: fsAdapter, picker: {}, fileUri: { FileUri: class { constructor(uri) { this.name = path.basename(uri); } } } },
  '@kit.MediaLibraryKit': { photoAccessHelper: {} }, '@kit.ImageKit': { image: {} },
  '@kit.BasicServicesKit': { deviceInfo: { brand: 'Test' }, pasteboard: {} }
};
const cache = new Map();
function load(file) {
  file = path.resolve(file);
  if (cache.has(file)) return cache.get(file).exports;
  const source = fs.readFileSync(file, 'utf8');
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
  const store = new ChatStore({ filesDir }); stores.push(store); return store;
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
    store.receiveShare({ records: [{ utd: 'general.file', uri: `file://${original}` }] }),
    store.receiveShare({ records: [{ utd: 'general.file', uri: `file://${original}` }, { utd: 'general.file', uri: `file://${original}` }] })
  ]);
  assert.equal(store.incomingShares.length, 2);
  assert.equal(store.incomingShares[1].files.length, 1);
  assert.notEqual(store.incomingShares[0].files[0].path, store.incomingShares[1].files[0].path);
  assert.equal(sent.filter(p => p.kind === 'offer').length, 0);
  const first = store.incomingShares[0];
  const canceledPath = store.incomingShares[1].files[0].path;
  store.cancelShare(store.incomingShares[1].id);
  assert(!fs.existsSync(canceledPath)); assert(fs.existsSync(original));
  const originalPersist = store.persist;
  store.persist = () => false;
  assert.equal(await store.sendShare(first.id, peer), false);
  assert.equal(store.incomingShares.length, 1); assert.equal(store.messages.length, 0);
  assert(fs.existsSync(first.files[0].path));
  store.persist = originalPersist;
  const results = await Promise.all([store.sendShare(first.id, peer), store.sendShare(first.id, peer)]);
  assert.deepEqual(results, [true, false]);
  assert.equal(store.incomingShares.length, 0);
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
  // Queue remains usable after parse and size failures.
  await store.receiveShare({ records: [{ utd: 'general.file', uri: `file://${original}` }] });
  store.cancelShare(store.incomingShares[0].id);
  assert.equal(store.incomingShares.length, 0);
  console.log('PASS incoming share: serialized imports, dedup, explicit confirmation, cancellation cleanup, save failure retry, draft isolation, exact-byte transfer, rollback, limits, text/link assistant');
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
    const upload=path.join(temporary,'phone-fixture.bin');fs.writeFileSync(upload,expected);
    await store.stageUri(channel.peer,upload);await store.submit(channel.peer,'');
    await wait(()=>store.messages.some(m=>m.name==='phone-fixture.bin'&&m.status==='对方已接收'),'Phone file delivery');
    await wait(()=>log.includes('MAC_PASS'),'Mac verification');
    assert(!error,error?.message);connection.destroy();
    console.log('PASS real TCP interoperability: original Swift ChatStore ↔ ArkTS store (Node platform adapter), PC/Phone, Chinese messages, bidirectional 180 KB files and receipt confirmation');
  } finally { mac.kill(); }
}
(async()=>{
  try { await core(); await attachmentOnly(); await incomingShare(); await offlineDelivery(); await interop(); }
  finally { for(const store of stores) await store.stop(); fs.rmSync(temporary,{recursive:true,force:true}); }
})().catch(error=>{console.error(error);process.exitCode=1;});
