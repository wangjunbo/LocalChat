import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { Packet, CHUNK_SIZE } from '../network/Wire';
import { Channel, LanNetwork } from '../network/LanNetwork';
import { Peer, Message, Archive, Attachment, ASSISTANT_ID } from '../model/Models';

class Transfer {
  peer: string = '';
  id: string = '';
  path: string = '';
  total: number = 0;
  count: number = 0;
  acknowledged: number = 0;
  started: boolean = false;
  lastProgress: number = Date.now();
  file?: fs.File;
  channel?: Channel;
}

export class ChatStore {
  private static instance?: ChatStore;
  static shared(context: common.UIAbilityContext): ChatStore {
    if (!ChatStore.instance) { ChatStore.instance = new ChatStore(context); }
    return ChatStore.instance;
  }
  peers: Peer[] = [];
  messages: Message[] = [];
  name: string = '鸿蒙手机';
  deviceId: string = '';
  ready: boolean = false;
  networkStatus: string = '正在连接局域网…';
  notice: string = '';
  error: string = '';
  onChange: () => void = () => {};
  private prefs: preferences.Preferences;
  private network: LanNetwork;
  private root: string;
  private startedAt: number = Date.now();
  private runId: string = util.generateRandomUUID();
  private runs: Map<string, string> = new Map();
  private queued: Map<string, Attachment[]> = new Map();
  private incoming: Map<string, Transfer> = new Map();
  private outgoing: Map<string, Transfer> = new Map();
  private archiveWritable: boolean = true;
  private persistTimer: number = -1;
  private timeoutTimer: number = -1;
  private noticeTimer: number = -1;
  private updateTimer: number = -1;

  private context: common.UIAbilityContext;
  private constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.root = `${context.filesDir}/LanChat`;
    if (!fs.accessSync(this.root)) { fs.mkdirSync(this.root, true); }
    if (!fs.accessSync(`${this.root}/files`)) { fs.mkdirSync(`${this.root}/files`, true); }
    this.prefs = preferences.getPreferencesSync(context, { name: 'LanChat' });
    this.deviceId = this.prefs.getSync('deviceId', '') as string;
    if (!this.deviceId) {
      this.deviceId = util.generateRandomUUID();
      this.prefs.putSync('deviceId', this.deviceId);
      this.prefs.flush().catch(() => {});
    }
    this.name = this.prefs.getSync('name', `${deviceInfo.brand || 'HarmonyOS'} 手机`) as string;
    this.load();
    this.network = new LanNetwork(context, this.deviceId, () => this.hello());
    this.network.onPacket = async (packet: Packet, channel: Channel) => this.process(packet, channel);
    this.network.onClose = (channel: Channel) => this.disconnected(channel);
    this.network.onState = (ready: boolean, detail: string) => {
      this.ready = ready; this.networkStatus = detail; this.changed(false);
    };
  }
  start(): void {
    this.network.start();
    if (this.timeoutTimer === -1) { this.timeoutTimer = setInterval(() => this.checkTransfers(), 5000); }
  }
  async stop(): Promise<void> {
    if (this.timeoutTimer !== -1) { clearInterval(this.timeoutTimer); this.timeoutTimer = -1; }
    if (this.noticeTimer !== -1) { clearTimeout(this.noticeTimer); this.noticeTimer = -1; }
    await this.network.stop();
    this.persist();
    if (this.updateTimer !== -1) { clearTimeout(this.updateTimer); this.updateTimer = -1; }
  }
  refresh(): void { this.network.refresh(); }
  changeName(name: string): void {
    this.name = name.trim().slice(0, 40) || '鸿蒙手机';
    this.prefs.putSync('name', this.name);
    this.prefs.flush().catch((error: Error) => this.report(error.message));
    this.network.broadcastHello();
    this.changed(false);
  }
  report(message: string): void { this.error = message; this.changed(false); }
  clearError(): void { this.error = ''; this.changed(false); }
  list(peer: string, query: string = ''): Message[] {
    const search = query.trim().toLowerCase();
    return this.messages.filter((message: Message) => message.peer === peer &&
      (!search || `${message.text} ${message.name}`.toLowerCase().includes(search)));
  }
  attachments(peer: string): Attachment[] { return this.queued.get(peer) || []; }
  removeAttachment(peer: string, id: string): void {
    const removed = this.attachments(peer).find((file: Attachment) => file.id === id);
    this.queued.set(peer, this.attachments(peer).filter((file: Attachment) => file.id !== id));
    if (removed && !this.messages.some((message: Message) => message.path === removed.path)) {
      try { fs.unlinkSync(removed.path); } catch (_) {}
    }
    this.changed(false);
  }
  removeMessage(message: Message): void {
    this.fail(`${message.peer}:${message.id}`, '已取消传输');
    this.messages = this.messages.filter((item: Message) => item.id !== message.id || item.peer !== message.peer);
    this.changed();
  }
  removePeer(peer: Peer): void {
    if (peer.online) { return; }
    this.peers = this.peers.filter((item: Peer) => item.id !== peer.id);
    this.changed();
  }
  async chooseFiles(peer: string): Promise<void> {
    try {
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const uris = await documentPicker.select({ maxSelectNumber: 9 });
      for (const uri of uris) { await this.stageUri(peer, uri); }
    } catch (error) { this.report(`无法选择文件：${(error as Error).message}`); }
  }
  async chooseImages(peer: string): Promise<void> {
    try {
      const photoPicker = new photoAccessHelper.PhotoViewPicker();
      const result = await photoPicker.select({ MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE, maxSelectNumber: 9 });
      for (const uri of result.photoUris) { await this.stageUri(peer, uri); }
    } catch (error) { this.report(`无法选择图片：${(error as Error).message}`); }
  }
  async pasteImage(peer: string): Promise<string> {
    try {
      const data = await pasteboard.getSystemPasteboard().getData();
      if (!data.hasType(pasteboard.MIMETYPE_PIXELMAP)) { return data.getPrimaryText() || ''; }
      const pixels = data.getPrimaryPixelMap();
      const packer = image.createImagePacker();
      try {
        const bytes = await packer.packing(pixels, { format: 'image/png', quality: 100 });
        const attachment = new Attachment(); attachment.id = util.generateRandomUUID();
        attachment.name = `图片-${Date.now()}.png`; attachment.size = bytes.byteLength;
        const directory = `${this.root}/files/${attachment.id}`; fs.mkdirSync(directory);
        attachment.path = `${directory}/${attachment.name}`;
        const file = fs.openSync(attachment.path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
        try { fs.writeSync(file.fd, bytes); } finally { fs.closeSync(file); }
        this.queued.set(peer, this.attachments(peer).concat([attachment])); this.changed(false);
      } finally { await packer.release(); }
    } catch (error) { this.report(`粘贴失败：${(error as Error).message}`); }
    return '';
  }
  private async stageUri(peer: string, uri: string): Promise<void> {
    const source = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const stat = fs.statSync(source.fd);
      if (!stat.isFile()) { throw new Error('暂不支持文件夹'); }
      const file = new Attachment();
      file.id = util.generateRandomUUID();
      file.name = this.safeName(new fileUri.FileUri(uri).name || '文件');
      const directory = `${this.root}/files/${file.id}`;
      fs.mkdirSync(directory);
      file.path = `${directory}/${file.name}`;
      file.size = stat.size;
      await fs.copyFile(source.fd, file.path);
      this.queued.set(peer, this.attachments(peer).concat([file]));
      this.changed(false);
    } finally { fs.closeSync(source); }
  }
  async exportFile(message: Message): Promise<void> {
    if (!message.path) { return; }
    try {
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const targets = await documentPicker.save({ newFileNames: [message.name] });
      if (!targets.length) { return; }
      const file = fs.openSync(targets[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      try { await fs.copyFile(message.path, file.fd); }
      finally { fs.closeSync(file); }
      this.notice = '已另存到所选位置'; this.changed(false);
    } catch (error) { this.report(`另存失败：${(error as Error).message}`); }
  }
  async submit(peer: string, text: string): Promise<boolean> {
    const channel = this.network.channelFor(peer);
    if (peer !== ASSISTANT_ID && !channel) { this.report('对方已离线'); return false; }
    const content = text.trim();
    if (new util.TextEncoder().encodeInto(content).length > 32 * 1024) { this.report('文字过长，请分段发送'); return false; }
    if (content) {
      const message = new Message();
      message.id = util.generateRandomUUID(); message.peer = peer; message.text = content; message.mine = true;
      message.status = peer === ASSISTANT_ID ? '已保存到本机' : '发送中';
      this.messages.push(message); this.changed();
      if (channel) {
        const packet = new Packet('text', message.id); packet.text = content;
        try { await channel.send(packet); }
        catch (_) { message.status = '发送失败'; this.changed(); return false; }
      }
    }
    const files = this.attachments(peer).slice();
    for (const file of files) {
      const message = new Message();
      message.id = util.generateRandomUUID(); message.peer = peer; message.mine = true;
      message.name = file.name; message.path = file.path; message.bytes = file.size;
      message.status = peer === ASSISTANT_ID ? '已保存到本机' : '等待对方接收';
      this.messages.push(message);
      if (channel) {
        const transfer = new Transfer();
        transfer.peer = peer; transfer.id = message.id; transfer.path = file.path;
        transfer.total = file.size; transfer.channel = channel;
        this.outgoing.set(`${peer}:${message.id}`, transfer);
        const offer = new Packet('offer', message.id); offer.name = file.name; offer.size = file.size;
        try { await channel.send(offer); } catch (_) { this.fail(`${peer}:${message.id}`, '发送失败'); }
      }
      this.removeAttachment(peer, file.id);
    }
    this.changed(); return true;
  }
  private hello(): Packet {
    const packet = new Packet('hello');
    packet.sender = this.deviceId; packet.name = this.name; packet.deviceType = 'Phone';
    packet.onlineFor = Math.max(0, (Date.now() - this.startedAt) / 1000);
    packet.runID = this.runId; packet.supportsHeartbeat = true; packet.supportsProgress = true;
    return packet;
  }
  private async process(packet: Packet, channel: Channel): Promise<void> {
    if (packet.kind === 'hello') {
      const id = packet.sender;
      if (typeof id !== 'string' || !/^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/i.test(id) || id === this.deviceId || (channel.peer && channel.peer !== id)) {
        this.network.drop(channel); return;
      }
      channel.peer = id; channel.heartbeat = packet.supportsHeartbeat === true; channel.progress = packet.supportsProgress === true;
      let peer = this.peers.find((item: Peer) => item.id === id);
      const wasOnline = peer?.online === true;
      const known = this.runs.has(id);
      if (!peer) { peer = new Peer(); peer.id = id; this.peers.push(peer); }
      peer.name = typeof packet.name === 'string' ? packet.name.slice(0, 40) : '附近的设备';
      peer.online = true;
      peer.deviceType = packet.deviceType === 'PC' || packet.deviceType === 'Phone' ? packet.deviceType : '';
      const sameRun = packet.runID !== undefined && this.runs.get(id) === packet.runID;
      this.runs.set(id, packet.runID || '');
      const newer = typeof packet.onlineFor === 'number' && packet.onlineFor >= 0 && packet.onlineFor < (Date.now() - this.startedAt) / 1000;
      if (!wasOnline && !sameRun && (known || newer)) {
        this.notice = `${peer.name} 已上线`;
        if (this.noticeTimer !== -1) { clearTimeout(this.noticeTimer); }
        this.noticeTimer = setTimeout(() => { this.notice = ''; this.changed(false); }, 8000);
      }
      this.changed(); return;
    }
    if (!channel.peer) { throw new Error('未握手'); }
    const peer = channel.peer;
    const key = `${peer}:${packet.id}`;
    const message = this.messages.find((item: Message) => item.peer === peer && item.id === packet.id);
    switch (packet.kind) {
      case 'ping': await channel.send(new Packet('pong', packet.id)); break;
      case 'pong': break;
      case 'text': {
        if (typeof packet.text !== 'string' || new util.TextEncoder().encodeInto(packet.text).length > 32 * 1024) { throw new Error('无效文字'); }
        if (!message) {
          const received = new Message(); received.id = packet.id; received.peer = peer; received.text = packet.text;
          this.messages.push(received); this.changed();
        }
        await channel.send(new Packet('ack', packet.id)); break;
      }
      case 'ack': if (message?.mine && !message.name) { message.status = '已送达'; this.changed(); } break;
      case 'offer': {
        if (message || this.incoming.has(key)) { break; }
        if (typeof packet.size !== 'number' || !Number.isSafeInteger(packet.size) || packet.size < 0 || this.incoming.size >= 20) {
          const reject = new Packet('reject', packet.id); reject.text = '文件大小无效或并发文件过多'; await channel.send(reject); break;
        }
        const received = new Message(); received.id = packet.id; received.peer = peer;
        received.name = this.safeName(typeof packet.name === 'string' ? packet.name : '文件');
        received.bytes = packet.size; received.status = '接收中'; this.messages.push(received);
        const transfer = new Transfer(); transfer.peer = peer; transfer.id = packet.id; transfer.total = packet.size;
        transfer.channel = channel;
        const directory = `${this.root}/files/${util.generateRandomUUID()}`;
        try {
          fs.mkdirSync(directory);
          transfer.path = `${directory}/.receiving.part`;
          transfer.file = fs.openSync(transfer.path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
          this.incoming.set(key, transfer);
          await channel.send(new Packet('accept', packet.id));
        } catch (_) {
          this.fail(key, '无法保存接收文件');
          received.status = '接收失败';
          const reject = new Packet('reject', packet.id); reject.text = '无法保存接收文件'; await channel.send(reject);
        }
        this.changed(); break;
      }
      case 'accept': {
        const transfer = this.outgoing.get(key);
        if (transfer && !transfer.started) {
          transfer.started = true; transfer.channel = channel; transfer.lastProgress = Date.now();
          this.pump(key, transfer);
        }
        break;
      }
      case 'chunk': {
        const transfer = this.incoming.get(key);
        if (!transfer || !message || !transfer.file) { break; }
        if (typeof packet.data !== 'string') { this.fail(key, '无效文件数据'); break; }
        try {
          const bytes = new util.Base64Helper().decodeSync(packet.data);
          if (bytes.length > transfer.total - transfer.count) { throw new Error('文件长度不匹配'); }
          const written = fs.writeSync(transfer.file.fd, bytes.buffer, { length: bytes.length });
          if (written !== bytes.length) { throw new Error('文件写入不完整'); }
          transfer.count += written;
          if (written > 0) { transfer.lastProgress = Date.now(); }
          message.transferred = transfer.count;
          message.status = transfer.count === transfer.total ? '等待传输结束' : '接收中';
          if (channel.progress) { const progress = new Packet('progress', packet.id); progress.size = transfer.count; await channel.send(progress); }
          this.changed(false);
        } catch (_) { this.fail(key, '文件接收失败'); }
        break;
      }
      case 'end': {
        const transfer = this.incoming.get(key);
        if (!transfer || !message || !transfer.file) { break; }
        if (transfer.count !== transfer.total) { this.fail(key, '文件不完整'); break; }
        try {
          fs.closeSync(transfer.file); transfer.file = undefined;
          const target = `${transfer.path.substring(0, transfer.path.lastIndexOf('/'))}/${message.name}`;
          fs.renameSync(transfer.path, target);
          this.incoming.delete(key); message.path = target; message.status = '已保存'; message.transferred = message.bytes;
          this.changed(); await channel.send(new Packet('complete', packet.id));
        } catch (_) { this.fail(key, '保存文件失败'); }
        break;
      }
      case 'progress': {
        const transfer = this.outgoing.get(key);
        if (transfer && message && typeof packet.size === 'number' && packet.size >= transfer.acknowledged && packet.size <= transfer.total) {
          if (packet.size > transfer.acknowledged) { transfer.lastProgress = Date.now(); }
          transfer.acknowledged = packet.size; message.transferred = packet.size; this.changed(false);
        }
        break;
      }
      case 'complete': {
        const transfer = this.outgoing.get(key);
        if (transfer && transfer.count === transfer.total && transfer.started && message) {
          this.outgoing.delete(key); message.status = '对方已接收'; message.transferred = message.bytes; this.changed();
        }
        break;
      }
      case 'reject': this.fail(key, typeof packet.text === 'string' ? packet.text.slice(0, 160) : '对方取消传输', false); break;
    }
  }
  private async pump(key: string, transfer: Transfer): Promise<void> {
    const message = this.messages.find((item: Message) => item.id === transfer.id && item.peer === transfer.peer);
    const channel = transfer.channel;
    if (!channel || !message) { return; }
    try {
      transfer.file = fs.openSync(transfer.path, fs.OpenMode.READ_ONLY);
      message.status = '发送中'; this.changed();
      while (transfer.count < transfer.total && this.outgoing.get(key) === transfer) {
        const buffer = new ArrayBuffer(Math.min(CHUNK_SIZE, transfer.total - transfer.count));
        const read = fs.readSync(transfer.file.fd, buffer, { length: buffer.byteLength });
        if (read <= 0) { throw new Error('源文件已改变'); }
        const packet = new Packet('chunk', transfer.id);
        packet.data = new util.Base64Helper().encodeToStringSync(new Uint8Array(buffer.slice(0, read)));
        await channel.send(packet);
        transfer.count += read; transfer.lastProgress = Date.now();
        if (!channel.progress) { message.transferred = transfer.count; this.changed(false); }
      }
      if (this.outgoing.get(key) !== transfer) { return; }
      fs.closeSync(transfer.file); transfer.file = undefined;
      message.status = '等待接收确认'; this.changed();
      await channel.send(new Packet('end', transfer.id));
    } catch (_) { this.fail(key, '文件发送失败'); }
  }
  private fail(key: string, reason: string, notify: boolean = true): void {
    const incoming = this.incoming.get(key);
    const transfer = incoming || this.outgoing.get(key);
    if (!transfer) { return; }
    try { if (transfer.file) { fs.closeSync(transfer.file); transfer.file = undefined; } } catch (_) {}
    if (incoming) { try { fs.unlinkSync(transfer.path); } catch (_) {} }
    this.incoming.delete(key); this.outgoing.delete(key);
    const message = this.messages.find((item: Message) => item.peer === transfer.peer && item.id === transfer.id);
    if (message) { message.status = reason; }
    if (notify && transfer.channel && !transfer.channel.closed) {
      const packet = new Packet('reject', transfer.id); packet.text = reason;
      transfer.channel.send(packet).catch(() => {});
    }
    this.changed();
  }
  private disconnected(channel: Channel): void {
    this.incoming.forEach((transfer: Transfer, key: string) => { if (transfer.channel === channel) { this.fail(key, '连接断开，请重试', false); } });
    this.outgoing.forEach((transfer: Transfer, key: string) => { if (transfer.channel === channel) { this.fail(key, '连接断开，请重试', false); } });
    if (channel.peer && !this.network.channelFor(channel.peer)) {
      const peer = this.peers.find((item: Peer) => item.id === channel.peer);
      if (peer) { peer.online = false; }
      this.messages.forEach((item: Message) => { if (item.peer === channel.peer && item.status === '发送中' && !item.name) { item.status = '送达状态未知'; } });
    }
    this.changed();
  }
  private checkTransfers(): void {
    const now = Date.now();
    this.incoming.forEach((transfer: Transfer, key: string) => { if (now - transfer.lastProgress > 120000) { this.fail(key, '传输超时，请重试'); } });
    this.outgoing.forEach((transfer: Transfer, key: string) => { if (now - transfer.lastProgress > 120000) { this.fail(key, '传输超时，请重试'); } });
  }
  private safeName(raw: string): string {
    const name = raw.replace(/\\/g, '/').split('/').pop() || '文件';
    const clean = name.replace(/[\u0000-\u001f\u007f]/g, '').slice(0, 80);
    return !clean || clean.startsWith('.') ? `文件${clean.replace(/^\.+/, '')}` : clean;
  }
  private changed(persist: boolean = true): void {
    if (persist) { this.onChange(); }
    else if (this.updateTimer === -1) {
      this.updateTimer = setTimeout(() => { this.updateTimer = -1; this.onChange(); }, 80);
    }
    if (persist && this.persistTimer === -1) { this.persistTimer = setTimeout(() => this.persist(), 300); }
  }
  private load(): void {
    const path = `${this.root}/history.json`;
    if (!fs.accessSync(path)) { return; }
    try {
      const archive = JSON.parse(fs.readTextSync(path)) as Archive;
      if (!Array.isArray(archive.peers) || !Array.isArray(archive.messages)) { throw new Error('记录格式错误'); }
      this.peers = archive.peers; this.messages = archive.messages;
      this.peers.forEach((peer: Peer) => { peer.online = false; });
      const pending = ['发送中', '接收中', '等待对方接收', '等待传输结束', '等待接收确认'];
      this.messages.forEach((message: Message) => {
        if (pending.includes(message.status)) { message.status = message.name ? '传输已中断，请重试' : '送达状态未知'; }
      });
    } catch (_) { this.archiveWritable = false; this.error = '历史记录读取失败，已保留原文件，本次记录暂不覆盖保存。'; }
  }
  private persist(): void {
    if (this.persistTimer !== -1) { clearTimeout(this.persistTimer); this.persistTimer = -1; }
    if (!this.archiveWritable) { return; }
    try {
      const archive = new Archive(); archive.peers = this.peers; archive.messages = this.messages;
      const temporary = `${this.root}/history.tmp`;
      const file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try { fs.writeSync(file.fd, JSON.stringify(archive)); } finally { fs.closeSync(file); }
      fs.renameSync(temporary, `${this.root}/history.json`);
    } catch (_) { this.error = '聊天记录保存失败，请检查存储空间'; this.onChange(); }
  }
}
