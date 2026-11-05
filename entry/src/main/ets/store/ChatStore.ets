import { restoreDeviceIdentity } from './DeviceIdentity';
import { FolderPlan, validFolderPath, removeTree } from './FolderTransfer';
import { ShareContacts } from './ShareContacts';
import { systemShare } from '@kit.ShareKit';
import { common, Want } from '@kit.AbilityKit';
import { preferences, uniformTypeDescriptor } from '@kit.ArkData';
import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { util, uri } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { deviceInfo, BusinessError } from '@kit.BasicServicesKit';
import { Packet, CHUNK_SIZE, messageDate } from '../network/Wire';
import { Channel, LanNetwork } from '../network/LanNetwork';
import { Peer, Message, Archive, Attachment, IncomingShare, HistoryScrollPosition, ASSISTANT_ID } from '../model/Models';

class Transfer {
  isDirectory: boolean = false;
  plan?: FolderPlan;
  expectedEntries: number = 0;
  entryCount: number = 0;
  remaining: number = 0;
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
  onIncoming: (message: Message) => void = () => {};
  onUnreadChange: (count: number) => void = () => {};
  activePeer: string = '';
  foreground: boolean = false;
  requestedPeer: string = '';
  incomingShares: IncomingShare[] = [];
  importingShares: number = 0;
  private shareTasks: Promise<void> = Promise.resolve();
  private sendingShare: boolean = false;
  unreadCount(peer: string = ''): number {
    return this.messages.filter((item: Message) => !item.mine && item.unread === true && (!peer || item.peer === peer)).length;
  }
  scrollPosition(peer: string): HistoryScrollPosition | undefined {
    try {
      const positions = JSON.parse(this.prefs.getSync('conversationScrollPositions.v1', '{}') as string) as Record<string, HistoryScrollPosition>;
      const position = positions[peer];
      if (position && Number.isFinite(position.offset) && position.offset >= 0 && typeof position.atBottom === 'boolean') { return position; }
    } catch (_) {}
    return undefined;
  }
  saveScrollPosition(peer: string, position: HistoryScrollPosition): void {
    if (!peer || !Number.isFinite(position.offset) || position.offset < 0) { return; }
    try {
      const positions = JSON.parse(this.prefs.getSync('conversationScrollPositions.v1', '{}') as string) as Record<string, HistoryScrollPosition>;
      positions[peer] = position;
      this.prefs.putSync('conversationScrollPositions.v1', JSON.stringify(positions));
      this.prefs.flush().catch(() => {});
    } catch (_) {}
  }
  markRead(peer: string): void {
    if (!peer || this.unreadCount(peer) === 0) { return; }
    this.messages.forEach((item: Message) => { if (item.peer === peer) { item.unread = false; } });
    this.changed();
  }
  setForeground(value: boolean): void {
    this.foreground = value;
    if (value) { this.markRead(this.activePeer); }
  }
  openFromNotification(peer: string): void {
    if (!this.peers.some((item: Peer) => item.id === peer)) { return; }
    this.requestedPeer = peer;
    this.onChange();
  }
  private prefs: preferences.Preferences;
  private network: LanNetwork;
  private root: string;
  private startedAt: number = Date.now();
  private identityReady: boolean = false;
  private runId: string = util.generateRandomUUID();
  private runs: Map<string, string> = new Map();
  private queued: Map<string, Attachment[]> = new Map();
  private lastTextAttempt: Map<string, number> = new Map();
  private incoming: Map<string, Transfer> = new Map();
  private outgoing: Map<string, Transfer> = new Map();
  private exportingFiles: Set<string> = new Set();
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
    try {
      this.deviceId = restoreDeviceIdentity(this.prefs.getSync('deviceId', '') as string);
      this.identityReady = true;
      this.prefs.putSync('deviceId', this.deviceId);
      this.prefs.flush().catch(() => {});
    } catch (error) {
      this.networkStatus = '设备身份暂不可用，请重新打开邻聊';
      this.error = '无法读取或保存设备身份，已暂停联网，请重新打开邻聊后重试';
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
    if (!this.identityReady) { this.changed(false); return; }
    this.network.start();
    if (this.timeoutTimer === -1) { this.timeoutTimer = setInterval(() => this.checkTransfers(), 5000); }
  }
  resumeNetwork(): void {
    if (!this.identityReady) { this.changed(false); return; }
    this.network.resume();
    if (this.timeoutTimer === -1) { this.timeoutTimer = setInterval(() => this.checkTransfers(), 5000); }
  }
  async stop(): Promise<void> {
    if (this.timeoutTimer !== -1) { clearInterval(this.timeoutTimer); this.timeoutTimer = -1; }
    if (this.noticeTimer !== -1) { clearTimeout(this.noticeTimer); this.noticeTimer = -1; }
    await this.network.stop();
    this.persist();
    if (this.updateTimer !== -1) { clearTimeout(this.updateTimer); this.updateTimer = -1; }
  }
  refresh(): void { if (this.identityReady) { this.network.refresh(); } }
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
      try { removeTree(removed.path); } catch (_) {}
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
    ShareContacts.remove(this.context, peer.id);
    this.changed();
  }
  async chooseFiles(peer: string): Promise<void> {
    try {
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const uris = await documentPicker.select({ maxSelectNumber: 9 });
      for (const uri of uris) { await this.stageUri(peer, uri); }
    } catch (error) { this.report(`无法选择文件：${(error as Error).message}`); }
  }
  async chooseFolder(peer: string): Promise<void> {
    try {
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const uris = await documentPicker.select({ maxSelectNumber: 1, selectMode: picker.DocumentSelectMode.FOLDER });
      for (const uri of uris) { await this.stageUri(peer, uri); }
    } catch (error) { this.report(`无法选择文件夹：${(error as Error).message}`); }
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
        attachment.path = this.availableFilePath(attachment.name);
        attachment.name = attachment.path.substring(attachment.path.lastIndexOf('/') + 1);
        const file = fs.openSync(attachment.path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
        try { fs.writeSync(file.fd, bytes); } finally { fs.closeSync(file); }
        this.queued.set(peer, this.attachments(peer).concat([attachment])); this.changed(false);
      } finally { await packer.release(); }
    } catch (error) { this.report(`粘贴失败：${(error as Error).message}`); }
    return '';
  }
  private async stageUri(peer: string, uri: string): Promise<void> {
    const file = await this.copyUri(uri);
    this.queued.set(peer, this.attachments(peer).concat([file]));
    this.changed(false);
  }
  private async copyUri(uri: string): Promise<Attachment> {
    const source = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const file = new Attachment();
    try {
      const stat = fs.statSync(source.fd);
      if (!stat.isFile() && !stat.isDirectory()) { throw new Error('请选择普通文件或文件夹'); }
      file.id = util.generateRandomUUID();
      file.name = this.safeName(new fileUri.FileUri(uri).name || '文件');
      file.isDirectory = stat.isDirectory();
      if (file.isDirectory) {
        await this.importFolder(uri, file);
      } else {
        file.path = this.availableFilePath(file.name);
        file.name = file.path.substring(file.path.lastIndexOf('/') + 1);
        file.size = stat.size;
        await fs.copyFile(source.fd, file.path);
      }
      return file;
    } catch (error) {
      if (file.path) { try { removeTree(file.path); } catch (_) {} }
      throw new Error((error as Error).message);
    } finally { fs.closeSync(source); }
  }
  private async importFolder(uri: string, file: Attachment): Promise<void> {
    const sourceUri = uri.startsWith('file://') ? uri : fileUri.getUriFromPath(uri);
    const sourceName = new fileUri.FileUri(sourceUri).name;
    if (!sourceName || sourceName === '.' || sourceName === '..' || sourceName.includes('/')) { throw new Error('无效的文件夹名称'); }
    const staging = `${this.root}/files/.import-${util.generateRandomUUID()}`;
    fs.mkdirSync(staging);
    try {
      // Native copy requires an existing parent and creates parent/sourceName.
      await fs.copy(sourceUri, fileUri.getUriFromPath(staging));
      const imported = `${staging}/${sourceName}`;
      const plan = new FolderPlan(imported);
      const target = this.availableFilePath(file.name);
      fs.renameSync(imported, target);
      file.path = target; file.name = target.substring(target.lastIndexOf('/') + 1); file.size = plan.bytes;
    } finally { try { removeTree(staging); } catch (_) {} }
  }
  receiveShare(want: Want): Promise<void> {
    this.importingShares++;
    this.changed(false);
    // Serialize imports so repeated shares cannot overwrite each other or reuse a destination path.
    this.shareTasks = this.shareTasks.then(async (): Promise<void> => {
      const incoming = new IncomingShare();
      incoming.id = util.generateRandomUUID();
      try {
        // Ordinary app shares have no contact. Never infer a recipient from the last share.
        try {
          const contact = await systemShare.getContactInfo(want);
          if (contact.contactId && (contact.contactId === ASSISTANT_ID ||
            this.peers.some((peer: Peer) => peer.id === contact.contactId))) {
            incoming.peer = contact.contactId;
          }
        } catch (_) {}
        let records: systemShare.SharedRecord[];
        try {
          records = (await systemShare.getSharedData(want)).getRecords();
        } catch (error) {
          // Older file providers pass a single authorized URI directly in Want.
          if (!want.uri?.startsWith('file://')) { throw new Error((error as Error).message); }
          records = [{ utd: 'general.file', uri: want.uri }];
        }
        if (!records.length || records.length > 9) { throw new Error('每次请分享 1 至 9 项内容'); }
        const uris: string[] = [];
        for (const record of records) {
          if (record.uri) {
            if (!record.uri.startsWith('file://')) { throw new Error('暂不支持此分享地址，请分享本地文件'); }
            if (!uris.includes(record.uri)) {
              uris.push(record.uri);
              incoming.files.push(await this.copyUri(record.uri));
            }
          } else if (record.content && ['general.text', 'general.plain-text', 'general.hyperlink'].includes(record.utd)) {
            incoming.text += (incoming.text ? '\n' : '') + record.content;
          } else { throw new Error('暂不支持此分享内容，请分享文件、文字或链接'); }
        }
        if (incoming.text && new util.TextEncoder().encodeInto(incoming.text).length > 32 * 1024) {
          throw new Error('分享文字过长，请分段分享');
        }
        this.incomingShares.push(incoming);
      } catch (error) {
        for (const file of incoming.files) { try { removeTree(file.path); } catch (_) {} }
        this.report(`接收分享失败：${(error as Error).message}`);
      } finally { this.importingShares--; this.changed(false); }
    });
    return this.shareTasks;
  }
  cancelShare(id: string): void {
    if (this.sendingShare) { return; }
    const incoming = this.incomingShares.find((item: IncomingShare) => item.id === id);
    if (!incoming) { return; }
    for (const file of incoming.files) { try { removeTree(file.path); } catch (_) {} }
    this.incomingShares = this.incomingShares.filter((item: IncomingShare) => item.id !== id);
    this.changed(false);
  }
  async sendShare(id: string, peer: string): Promise<boolean> {
    if (this.sendingShare) { return false; }
    const incoming = this.incomingShares.find((item: IncomingShare) => item.id === id);
    if (!incoming) { return false; }
    if (peer !== ASSISTANT_ID && !this.peers.some((item: Peer) => item.id === peer)) {
      this.report('所选设备已移除，请重新选择'); return false;
    }
    this.sendingShare = true;
    try {
      const sent = await this.submit(peer, incoming.text, incoming.files);
      if (sent) {
        this.incomingShares = this.incomingShares.filter((item: IncomingShare) => item.id !== id);
        this.changed(false);
        const recipient = this.peers.find((item: Peer) => item.id === peer);
        if (peer === ASSISTANT_ID || recipient) {
          ShareContacts.record(this.context, peer, peer === ASSISTANT_ID ? '文件传输助手' : recipient!.name);
        }
      }
      return sent;
    } finally { this.sendingShare = false; }
  }
  async exportFile(selected: Message): Promise<void> {
    const message = this.messages.find((item: Message) => item.id === selected.id && item.peer === selected.peer);
    if (!message) { return; }
    if (!message.path) { return; }
    const key = `${message.peer}:${message.id}`;
    if (this.exportingFiles.has(key)) { return; }
    this.exportingFiles.add(key);
    try {
      if (message.isDirectory) { await this.exportFolder(message); return; }
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const targets = await documentPicker.save({ newFileNames: [message.name] });
      if (!targets.length) { return; }
      const file = fs.openSync(targets[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      try { await fs.copyFile(message.path, file.fd); }
      finally { fs.closeSync(file); }
      // Cross-provider moves require completing the copy before removing the sandbox source.
      fs.unlinkSync(message.path);
      message.savedUri = targets[0];
      message.path = '';
      message.status = '已移至所选目录';
      this.notice = '已移动到所选位置';
      if (!this.persist()) { this.report('文件已移动，但聊天记录保存失败'); return; }
      this.changed();
    } catch (error) {
      const code = (error as BusinessError).code;
      this.report(`移动失败：${(error as Error).message}${code ? `（错误码 ${code}）` : ''}`);
    } finally { this.exportingFiles.delete(key); }
  }
  private async exportFolder(message: Message): Promise<void> {
    const documentPicker = new picker.DocumentViewPicker(this.context);
    const targets = await documentPicker.select({ maxSelectNumber: 1, selectMode: picker.DocumentSelectMode.FOLDER });
    if (!targets.length) { return; }
    const sourcePath = message.path;
    const sourceUri = fileUri.getUriFromPath(sourcePath);
    const sourceName = new fileUri.FileUri(sourceUri).name;
    // FileUri's native runtime object does not provide the URI methods declared
    // by its SDK base type. Use the actual ArkTS URI class for path operations.
    const destination = new uri.URI(targets[0]);
    const target = destination.addSegment(sourceName);
    // Check the decoded filesystem path: probing a fabricated, missing document
    // URI can fail during URI resolution instead of reporting ENOENT.
    const targetPath = '/' + target.getSegment().join('/');
    try { fs.lstatSync(targetPath); throw new Error('目标文件夹已存在，请选择其他位置或先重命名'); }
    catch (error) { if ((error as BusinessError).code !== 13900002) { throw new Error((error as Error).message); } }
    // Pass the picker-granted, existing PARENT URI unchanged. Native copy adds
    // the source basename itself; a nonexistent child URI returns EINVAL.
    await fs.copy(sourceUri, targets[0]);
    removeTree(sourcePath);
    message.savedUri = target.toString(); message.name = sourceName; message.path = ''; message.status = '已移至所选目录';
    this.notice = '文件夹已移动到所选位置'; this.changed();
    if (!this.persist()) { this.report('文件夹已移动，但聊天记录保存失败'); }
  }
  async saveToDownload(message: Message): Promise<void> {
    await this.exportFile(message);
  }
  async openSavedDirectory(message: Message): Promise<void> {
    if (!message.savedUri) { this.report('未记录保存位置，请在文件管理器中查找'); return; }
    try {
      const directory = message.savedUri.substring(0, message.savedUri.lastIndexOf('/'));
      const documentPicker = new picker.DocumentViewPicker(this.context);
      await documentPicker.select({ defaultFilePathUri: directory,
        selectMode: picker.DocumentSelectMode.FOLDER });
    } catch (error) { this.report(`打开目录失败：${(error as Error).message}`); }
  }
  async shareFile(message: Message): Promise<void> {
    if (!message.path) { return; }
    try {
      const uri = fileUri.getUriFromPath(message.path);
      const extension = message.name.substring(message.name.lastIndexOf('.'));
      const utd = message.isDirectory ? 'general.folder' : (uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(extension) || 'general.file');
      const data = new systemShare.SharedData({ utd: utd, uri: uri });
      const controller = new systemShare.ShareController(data);
      await controller.show(this.context, { previewMode: systemShare.SharePreviewMode.DEFAULT });
    } catch (error) { this.report(`分享失败：${(error as Error).message}`); }
  }
  async renameFile(selected: Message, newName: string): Promise<void> {
    const message = this.messages.find((item: Message) => item.id === selected.id && item.peer === selected.peer);
    if (!message) { this.report('消息已不存在'); return; }
    newName = newName.trim();
    if (!message.path || !newName) { return; }
    try {
      if (newName === message.name) { return; }
      if (newName === '.' || newName === '..' || /[\\/\x00-\x1f]/.test(newName)) {
        this.report('文件名不能包含路径分隔符或控制字符'); return;
      }
      const directory = message.path.substring(0, message.path.lastIndexOf('/'));
      const newPath = `${directory}/${newName}`;
      if (fs.accessSync(newPath)) { this.report('文件名已存在'); return; }
      fs.renameSync(message.path, newPath);
      message.path = newPath;
      message.name = newName;
      if (!this.persist()) { this.report('无法保存重命名记录'); return; }
      this.notice = '重命名成功'; this.changed();
    } catch (error) { this.report(`重命名失败：${(error as Error).message}`); }
  }
  deleteMessage(message: Message): void {
    const index = this.messages.findIndex((item: Message) => item.id === message.id && item.peer === message.peer);
    if (index < 0) { return; }
    const stored = this.messages[index];
    if (stored.path) {
      try {
        if (fs.accessSync(stored.path)) { removeTree(stored.path); }
      } catch (error) {
        this.report(`删除文件失败：${(error as Error).message}`); return;
      }
    }
    this.messages.splice(index, 1);
    if (!this.persist()) { this.report('无法保存删除记录'); return; }
    this.notice = '已删除'; this.changed();
  }
  async submit(peer: string, text: string, sharedFiles?: Attachment[]): Promise<boolean> {
    if (!this.archiveWritable) { this.report('聊天记录不可写，无法保存待发消息'); return false; }
    const content = text.trim();
    const files = sharedFiles === undefined ? this.attachments(peer).slice() : sharedFiles;
    if (!content && files.length === 0) { return false; }
    if (content && new util.TextEncoder().encodeInto(content).length > 32 * 1024) { this.report('文字过长，请分段发送'); return false; }
    const added: Message[] = [];
    if (content) {
      const message = new Message();
      message.id = util.generateRandomUUID(); message.peer = peer; message.text = content; message.mine = true;
      message.pendingDelivery = peer !== ASSISTANT_ID;
      message.status = peer === ASSISTANT_ID ? '已保存到本机' : '等待对方上线';
      added.push(message);
    }
    for (const file of files) {
      const message = new Message();
      message.id = util.generateRandomUUID(); message.peer = peer; message.mine = true;
      message.name = file.name; message.path = file.path; message.bytes = file.size; message.isDirectory = file.isDirectory;
      message.pendingDelivery = peer !== ASSISTANT_ID;
      message.status = peer === ASSISTANT_ID ? '已保存到本机' : '等待对方上线';
      added.push(message);
    }
    this.messages = this.messages.concat(added);
    if (!this.persist()) {
      this.messages = this.messages.filter((item: Message) => !added.includes(item));
      this.onChange(); return false;
    }
    if (sharedFiles === undefined) {
      for (const file of files) { this.removeAttachment(peer, file.id); }
    }
    this.changed();
    try { await this.flushOutbox(peer); }
    catch (error) { this.report(`消息已保存，将稍后重试发送：${(error as Error).message}`); }
    return true;
  }
  private async flushOutbox(peer: string): Promise<void> {
    const channel = this.network.channelFor(peer);
    if (!channel) { return; }
    for (const message of this.messages.filter((item: Message) => item.peer === peer && item.mine && item.pendingDelivery === true)) {
      if (channel.closed) { return; }
      if (!this.messages.includes(message) || !message.pendingDelivery) { continue; }
      const key = `${peer}:${message.id}`;
      if (!message.name) {
        if (Date.now() - (this.lastTextAttempt.get(key) || 0) < 10000) { continue; }
        this.lastTextAttempt.set(key, Date.now());
        message.status = '发送中'; this.changed();
        const packet = new Packet('text', message.id); packet.text = message.text; packet.sentAt = message.date;
        try { await channel.send(packet); }
        catch (_) { if (message.pendingDelivery) { message.status = '等待对方上线'; this.changed(); } }
      } else {
        if (Array.from(this.outgoing.values()).some((item: Transfer) => item.peer === peer)) { continue; }
        if (!message.path || !fs.accessSync(message.path)) {
          message.pendingDelivery = false; message.status = '待发文件不存在，请重新添加'; this.changed(); continue;
        }
        if (message.isDirectory && !channel.folders) {
          message.status = '对方需更新邻聊以接收文件夹'; this.changed(); continue;
        }
        const transfer = new Transfer();
        transfer.isDirectory = message.isDirectory === true;
        if (transfer.isDirectory) {
          try {
            transfer.plan = new FolderPlan(message.path);
            if (transfer.plan.bytes !== message.bytes) { throw new Error('文件夹内容已改变'); }
          } catch (_) { message.pendingDelivery = false; message.status = '待发文件夹已改变，请重新添加'; this.changed(); continue; }
        }
        transfer.peer = peer; transfer.id = message.id; transfer.path = message.path;
        transfer.total = message.bytes; transfer.channel = channel;
        this.outgoing.set(key, transfer);
        message.status = '等待对方接收'; message.transferred = 0; this.changed();
        const offer = new Packet('offer', message.id); offer.name = message.name; offer.size = message.bytes; offer.sentAt = message.date;
        offer.isDirectory = transfer.isDirectory; offer.entryCount = transfer.plan?.entries.length;
        try { await channel.send(offer); }
        catch (_) { this.outgoing.delete(key); if (message.pendingDelivery) { message.status = '等待对方上线'; this.changed(); } }
      }
    }
  }
  private hello(): Packet {
    const packet = new Packet('hello');
    packet.sender = this.deviceId; packet.name = this.name; packet.deviceType = 'Phone';
    packet.onlineFor = Math.max(0, (Date.now() - this.startedAt) / 1000);
    packet.runID = this.runId; packet.supportsHeartbeat = true; packet.supportsProgress = true; packet.supportsFolders = true;
    return packet;
  }
  private async process(packet: Packet, channel: Channel): Promise<void> {
    if (packet.kind === 'hello') {
      const id = packet.sender;
      if (typeof id !== 'string' || !/^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/i.test(id) || id === this.deviceId || (channel.peer && channel.peer !== id)) {
        this.network.drop(channel); return;
      }
      channel.peer = id; channel.heartbeat = packet.supportsHeartbeat === true; channel.progress = packet.supportsProgress === true; channel.folders = packet.supportsFolders === true;
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
      this.changed(); await this.flushOutbox(id); return;
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
          const received = new Message(); received.id = packet.id; received.peer = peer; received.text = packet.text; received.date = messageDate(packet);
          received.unread = !(this.foreground && this.activePeer === peer);
          this.messages.push(received); this.changed(); this.onIncoming(received);
        }
        if (!this.persist()) { throw new Error('无法保存收到的消息'); }
        await channel.send(new Packet('ack', packet.id)); break;
      }
      case 'ack': if (message?.mine && !message.name) { message.status = '已送达'; message.pendingDelivery = false; this.changed(); } break;
      case 'offer': {
        if (this.incoming.has(key)) { break; }
        if (message) {
          if (message.mine) { break; }
          if (message.status === '已保存') {
            if (!this.persist()) { throw new Error('无法保存接收记录'); }
            await channel.send(new Packet('complete', packet.id)); break;
          }
          if (message.bytes !== packet.size) { break; }
          this.messages = this.messages.filter((item: Message) => item !== message);
        }
        if (typeof packet.size !== 'number' || !Number.isSafeInteger(packet.size) || packet.size < 0 || this.incoming.size >= 20) {
          const reject = new Packet('reject', packet.id); reject.text = '文件大小无效或并发文件过多'; await channel.send(reject); break;
        }
        if (packet.isDirectory === true && (typeof packet.entryCount !== 'number' || !Number.isSafeInteger(packet.entryCount) || packet.entryCount < 0 || packet.entryCount > 100000)) {
          const reject = new Packet('reject', packet.id); reject.text = '无效文件夹条目数'; await channel.send(reject); break;
        }
        const received = new Message(); received.isDirectory = packet.isDirectory === true; received.id = packet.id; received.peer = peer;
        received.name = this.safeName(typeof packet.name === 'string' ? packet.name : '文件');
        received.bytes = packet.size; received.status = '接收中'; received.date = message?.date ?? messageDate(packet);
        received.unread = !(this.foreground && this.activePeer === peer);
        this.messages.push(received); this.onIncoming(received);
        const transfer = new Transfer(); transfer.peer = peer; transfer.id = packet.id; transfer.total = packet.size;
        transfer.channel = channel; transfer.isDirectory = received.isDirectory; transfer.expectedEntries = packet.entryCount || 0;
        try {
          transfer.path = `${this.root}/files/.${util.generateRandomUUID()}.receiving.part`;
          this.incoming.set(key, transfer);
          if (transfer.isDirectory) { fs.mkdirSync(transfer.path); }
          else { transfer.file = fs.openSync(transfer.path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE); }
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
      case 'entry': {
        const transfer = this.incoming.get(key);
        if (!transfer || !transfer.isDirectory) { break; }
        try {
          if (transfer.remaining !== 0 || transfer.entryCount >= transfer.expectedEntries || typeof packet.name !== 'string' ||
            !validFolderPath(packet.name) || typeof packet.isDirectory !== 'boolean' || typeof packet.size !== 'number' ||
            !Number.isSafeInteger(packet.size) || packet.size < 0 || packet.size > transfer.total - transfer.count ||
            (packet.isDirectory && packet.size !== 0)) { throw new Error('目录信息无效'); }
          if (transfer.file) { fs.closeSync(transfer.file); transfer.file = undefined; }
          const path = `${transfer.path}/${packet.name}`;
          const parent = path.substring(0, path.lastIndexOf('/'));
          if (!fs.statSync(parent).isDirectory() || fs.accessSync(path)) { throw new Error('目录冲突或父目录缺失'); }
          if (packet.isDirectory) { fs.mkdirSync(path); }
          else { transfer.file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE); }
          transfer.remaining = packet.size; transfer.entryCount++; transfer.lastProgress = Date.now();
        } catch (_) { this.fail(key, '文件夹目录信息无效'); }
        break;
      }
      case 'chunk': {
        const transfer = this.incoming.get(key);
        if (!transfer || !message) { break; }
        if (!transfer.file) { this.fail(key, '文件数据缺少目录记录'); break; }
        if (typeof packet.data !== 'string') { this.fail(key, '无效文件数据'); break; }
        try {
          const bytes = new util.Base64Helper().decodeSync(packet.data);
          if (bytes.length > transfer.total - transfer.count || (transfer.isDirectory && bytes.length > transfer.remaining)) { throw new Error('文件长度不匹配'); }
          const written = fs.writeSync(transfer.file.fd, bytes.buffer, { length: bytes.length });
          if (written !== bytes.length) { throw new Error('文件写入不完整'); }
          transfer.count += written;
          if (transfer.isDirectory) { transfer.remaining -= written; }
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
        if (!transfer || !message || (!transfer.isDirectory && !transfer.file)) { break; }
        if (transfer.count !== transfer.total || (transfer.isDirectory && (transfer.remaining !== 0 || transfer.entryCount !== transfer.expectedEntries))) { this.fail(key, '文件不完整'); break; }
        try {
          if (transfer.file) { fs.closeSync(transfer.file); transfer.file = undefined; }
          const target = this.availableFilePath(message.name);
          message.name = target.substring(target.lastIndexOf('/') + 1);
          fs.renameSync(transfer.path, target);
          this.incoming.delete(key); message.path = target; message.status = '已保存'; message.transferred = message.bytes;
          this.changed();
          if (!this.persist()) { throw new Error('无法保存接收记录'); }
          await channel.send(new Packet('complete', packet.id));
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
        if (transfer && message && (message.pendingDelivery || (transfer.count === transfer.total && transfer.started))) {
          this.outgoing.delete(key); message.pendingDelivery = false; message.status = '对方已接收'; message.transferred = message.bytes; this.changed();
          await this.flushOutbox(peer);
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
      if (transfer.plan) { await this.pumpFolder(key, transfer, message, channel); return; }
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
  private async pumpFolder(key: string, transfer: Transfer, message: Message, channel: Channel): Promise<void> {
    const plan = transfer.plan;
    if (!plan) { return; }
    message.status = '发送中'; this.changed();
    for (const entry of plan.entries) {
      if (this.outgoing.get(key) !== transfer) { return; }
      const path = `${transfer.path}/${entry.path}`;
      const stat = fs.lstatSync(path);
      if (stat.isSymbolicLink() || stat.isDirectory() !== entry.directory || (!entry.directory && (!stat.isFile() || stat.size !== entry.size))) {
        throw new Error('源文件夹已改变');
      }
      const record = new Packet('entry', transfer.id); record.name = entry.path;
      record.size = entry.size; record.isDirectory = entry.directory;
      await channel.send(record); transfer.lastProgress = Date.now();
      if (entry.directory) { continue; }
      if (this.outgoing.get(key) !== transfer) { return; }
      transfer.file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      let remaining = entry.size;
      while (remaining > 0) {
        if (this.outgoing.get(key) !== transfer) { return; }
        const buffer = new ArrayBuffer(Math.min(CHUNK_SIZE, remaining));
        const read = fs.readSync(transfer.file.fd, buffer, { length: buffer.byteLength });
        if (read <= 0) { throw new Error('源文件已改变'); }
        const packet = new Packet('chunk', transfer.id);
        packet.data = new util.Base64Helper().encodeToStringSync(new Uint8Array(buffer.slice(0, read)));
        await channel.send(packet);
        remaining -= read; transfer.count += read; transfer.lastProgress = Date.now();
        if (!channel.progress) { message.transferred = transfer.count; this.changed(false); }
      }
      if (this.outgoing.get(key) !== transfer) { return; }
      fs.closeSync(transfer.file); transfer.file = undefined;
    }
    if (this.outgoing.get(key) !== transfer) { return; }
    message.status = '等待接收确认'; this.changed();
    await channel.send(new Packet('end', transfer.id));
  }
  private fail(key: string, reason: string, notify: boolean = true): void {
    const incoming = this.incoming.get(key);
    const transfer = incoming || this.outgoing.get(key);
    if (!transfer) { return; }
    try { if (transfer.file) { fs.closeSync(transfer.file); transfer.file = undefined; } } catch (_) {}
    if (incoming) { try { removeTree(transfer.path); } catch (_) {} }
    this.incoming.delete(key); this.outgoing.delete(key);
    const message = this.messages.find((item: Message) => item.peer === transfer.peer && item.id === transfer.id);
    if (message) {
      const retry = message.mine && message.pendingDelivery === true && reason === '连接断开，请重试';
      message.pendingDelivery = retry; message.status = retry ? '等待对方上线' : reason;
    }
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
      this.lastTextAttempt.clear();
      this.messages.forEach((item: Message) => { if (item.peer === channel.peer && item.mine && item.pendingDelivery) { item.status = '等待对方上线'; } });
    }
    this.changed();
  }
  private checkTransfers(): void {
    const now = Date.now();
    this.peers.forEach((peer: Peer) => { if (peer.online) { this.flushOutbox(peer.id).catch(() => {}); } });
    this.incoming.forEach((transfer: Transfer, key: string) => { if (now - transfer.lastProgress > 120000) { this.fail(key, '传输超时，请重试'); } });
    this.outgoing.forEach((transfer: Transfer, key: string) => { if (now - transfer.lastProgress > 120000) { this.fail(key, '传输超时，请重试'); } });
  }
  private availableFilePath(name: string): string {
    const clean = this.safeName(name);
    const dot = clean.lastIndexOf('.');
    const base = dot > 0 ? clean.substring(0, dot) : clean;
    const extension = dot > 0 ? clean.substring(dot) : '';
    let target = `${this.root}/files/${clean}`;
    let suffix = 1;
    while (fs.accessSync(target)) { target = `${this.root}/files/${base}(${suffix++})${extension}`; }
    return target;
  }
  private migrateFileDirectories(): void {
    const prefix = `${this.root}/files/`;
    this.messages.forEach((message: Message) => {
      if (!message.path || !message.path.startsWith(prefix) || !message.path.substring(prefix.length).includes('/')) { return; }
      const oldPath = message.path;
      const oldName = message.name;
      try {
        if (!fs.accessSync(oldPath)) { return; }
        const target = this.availableFilePath(message.name);
        fs.renameSync(oldPath, target);
        message.path = target;
        message.name = target.substring(target.lastIndexOf('/') + 1);
        if (!this.persist()) {
          fs.renameSync(target, oldPath); message.path = oldPath; message.name = oldName; return;
        }
        try { fs.rmdirSync(oldPath.substring(0, oldPath.lastIndexOf('/'))); } catch (_) {}
      } catch (_) { this.error = '部分旧文件迁移失败，已保留原位置'; }
    });
  }
  private safeName(raw: string): string {
    const name = raw.replace(/\\/g, '/').split('/').pop() || '文件';
    const clean = name.replace(/[\u0000-\u001f\u007f]/g, '').slice(0, 80);
    return !clean || clean.startsWith('.') ? `文件${clean.replace(/^\.+/, '')}` : clean;
  }
  private changed(persist: boolean = true): void {
    if (persist) { this.onUnreadChange(this.unreadCount()); this.onChange(); }
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
      this.migrateFileDirectories();
      this.peers.forEach((peer: Peer) => { peer.online = false; });
      const pending = ['发送中', '接收中', '等待对方接收', '等待传输结束', '等待接收确认'];
      this.messages.forEach((message: Message) => {
        if (message.mine && message.pendingDelivery === true) { message.status = '等待对方上线'; }
        else if (pending.includes(message.status)) { message.status = message.name ? '传输已中断，请重试' : '送达状态未知'; }
      });
    } catch (_) { this.archiveWritable = false; this.error = '历史记录读取失败，已保留原文件，本次记录暂不覆盖保存。'; }
  }
  checkpoint(): void { this.persist(); }

  private persist(): boolean {
    if (this.persistTimer !== -1) { clearTimeout(this.persistTimer); this.persistTimer = -1; }
    if (!this.archiveWritable) { return false; }
    try {
      const archive = new Archive(); archive.peers = this.peers; archive.messages = this.messages;
      const temporary = `${this.root}/history.tmp`;
      const file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try { fs.writeSync(file.fd, JSON.stringify(archive)); } finally { fs.closeSync(file); }
      fs.renameSync(temporary, `${this.root}/history.json`);
      return true;
    } catch (_) { this.error = '聊天记录保存失败，请检查存储空间'; this.onChange(); return false; }
  }
}
