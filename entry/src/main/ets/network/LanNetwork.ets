import { common } from '@kit.AbilityKit';
import { socket, mdns } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { Packet, Framer, SERVICE_TYPE, encodePacket } from './Wire';

export class Channel {
  id: string = util.generateRandomUUID();
  peer: string = '';
  heartbeat: boolean = false;
  progress: boolean = false;
  lastSeen: number = Date.now();
  created: number = Date.now();
  closed: boolean = false;
  endpoint: string = '';
  framer: Framer = new Framer();
  queue: Promise<void> = Promise.resolve();
  sendQueue: Promise<void> = Promise.resolve();
  pendingBytes: number = 0;
  client?: socket.TCPSocket;
  accepted?: socket.TCPSocketConnection;
  async send(packet: Packet): Promise<void> {
    const data = encodePacket(packet);
    const task = this.sendQueue.then(async () => {
      if (this.closed) { throw new Error('设备连接已断开'); }
      if (this.client) { await this.client.send({ data: data }); }
      else if (this.accepted) { await this.accepted.send({ data: data }); }
    });
    this.sendQueue = task.catch(() => {});
    return task;
  }
  close(): void {
    if (this.closed) { return; }
    this.closed = true;
    if (this.client) { this.client.close().catch(() => {}); }
    if (this.accepted) { this.accepted.close().catch(() => {}); }
  }
}
export class LanNetwork {
  channels: Channel[] = [];
  onPacket: (packet: Packet, channel: Channel) => Promise<void> = async () => {};
  onClose: (channel: Channel) => void = () => {};
  onState: (ready: boolean, detail: string) => void = () => {};
  private server?: socket.TCPSocketServer;
  private discovery?: mdns.DiscoveryService;
  private registered?: mdns.LocalServiceInfo;
  private found: Map<string, mdns.LocalServiceInfo> = new Map();
  private connecting: Set<string> = new Set();
  private timer: number = -1;
  private active: boolean = false;
  private starting: boolean = false;
  private context: common.UIAbilityContext;
  private deviceId: string;
  private hello: () => Packet;
  constructor(context: common.UIAbilityContext, deviceId: string, hello: () => Packet) {
    this.context = context; this.deviceId = deviceId; this.hello = hello;
  }

  async start(): Promise<void> {
    if (this.active || this.starting) { return; }
    this.starting = true;
    this.active = true;
    try {
      const server = socket.constructTCPSocketServerInstance();
      this.server = server;
      server.on('connect', (connection: socket.TCPSocketConnection) => {
        if (!this.active || this.channels.length >= 64) { connection.close().catch(() => {}); return; }
        const channel = new Channel();
        channel.accepted = connection;
        this.attach(channel);
        this.sayHello(channel);
      });
      server.on('error', () => { this.onState(false, '监听连接失败，请刷新重试'); });
      await server.listen({ address: '0.0.0.0', port: 0, family: 1 });
      const address = await server.getLocalAddress();
      this.registered = await mdns.addLocalService(this.context, {
        serviceType: SERVICE_TYPE, serviceName: this.deviceId, port: address.port
      });
      this.discovery = mdns.createDiscoveryService(this.context, SERVICE_TYPE);
      this.discovery.on('serviceFound', (service: mdns.LocalServiceInfo) => {
        if (service.serviceName === this.deviceId || service.serviceName === this.registered?.serviceName) { return; }
        this.found.set(service.serviceName, service);
        this.connect(service);
      });
      this.discovery.on('serviceLost', (service: mdns.LocalServiceInfo) => { this.found.delete(service.serviceName); });
      this.discovery.on('discoveryStart', (event: mdns.DiscoveryEventInfo) => {
        this.onState(event.errorCode === undefined, event.errorCode === undefined ? '局域网已就绪' : '设备发现失败，请刷新');
      });
      this.discovery.startSearchingMDNS();
      this.timer = setInterval(() => this.tick(), 5000);
      this.onState(true, '局域网已就绪');
    } catch (error) {
      await this.stop();
      this.onState(false, `无法启动局域网：${(error as Error).message}`);
    } finally { this.starting = false; }
  }
  async stop(): Promise<void> {
    this.active = false;
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
    try { this.discovery?.stopSearchingMDNS(); } catch (_) {}
    this.discovery = undefined;
    if (this.registered) {
      try { await mdns.removeLocalService(this.context, this.registered); } catch (_) {}
      this.registered = undefined;
    }
    if (this.server) { try { await this.server.close(); } catch (_) {} this.server = undefined; }
    this.channels.slice().forEach((channel: Channel) => this.drop(channel));
    this.found.clear();
  }
  async refresh(): Promise<void> {
    if (!this.active) { await this.start(); return; }
    try {
      this.discovery?.stopSearchingMDNS();
      this.discovery?.startSearchingMDNS();
      this.found.forEach((info: mdns.LocalServiceInfo) => this.connect(info));
    } catch (_) { await this.stop(); await this.start(); }
  }
  channelFor(peer: string): Channel | undefined {
    return this.channels.find((channel: Channel) => channel.peer === peer && !channel.closed);
  }
  broadcastHello(): void { this.channels.forEach((channel: Channel) => this.sayHello(channel)); }
  private sayHello(channel: Channel): void { channel.send(this.hello()).catch(() => this.drop(channel)); }
  drop(channel: Channel): void {
    if (!this.channels.includes(channel)) { channel.close(); return; }
    channel.close();
    this.channels = this.channels.filter((item: Channel) => item !== channel);
    this.onClose(channel);
  }
  private attach(channel: Channel): void {
    this.channels.push(channel);
    const onMessage = (info: socket.SocketMessageInfo): void => {
      channel.pendingBytes += info.message.byteLength;
      if (channel.pendingBytes > 8 * 1024 * 1024) { this.drop(channel); return; }
      channel.queue = channel.queue.then(async () => {
        try {
          if (channel.closed) { return; }
          const packets = channel.framer.append(info.message);
          for (const packet of packets) {
            channel.lastSeen = Date.now();
            await this.onPacket(packet, channel);
          }
        } finally { channel.pendingBytes -= info.message.byteLength; }
      }).catch(() => this.drop(channel));
    };
    if (channel.client) {
      channel.client.on('message', onMessage);
      channel.client.on('close', () => this.drop(channel));
      channel.client.on('error', () => this.drop(channel));
    } else if (channel.accepted) {
      channel.accepted.on('message', onMessage);
      channel.accepted.on('close', () => this.drop(channel));
      channel.accepted.on('error', () => this.drop(channel));
    }
  }
  private async connect(service: mdns.LocalServiceInfo): Promise<void> {
    if (!this.active || this.connecting.has(service.serviceName) || this.channelFor(service.serviceName) ||
      this.channels.some((c: Channel) => c.endpoint === service.serviceName && !c.closed)) { return; }
    this.connecting.add(service.serviceName);
    let channel: Channel | undefined;
    try {
      const resolved = await mdns.resolveLocalService(this.context, service);
      if (!this.active || !resolved.host || !resolved.port || this.channelFor(service.serviceName)) { return; }
      channel = new Channel();
      channel.endpoint = service.serviceName;
      const client = socket.constructTCPSocketInstance();
      channel.client = client;
      this.attach(channel);
      const family = resolved.host.address.includes(':') ? 2 : 1;
      await client.bind({ address: family === 2 ? '::' : '0.0.0.0', port: 0, family: family });
      await client.connect({ address: { address: resolved.host.address, port: resolved.port, family: family }, timeout: 8000 });
      this.sayHello(channel);
    } catch (_) { if (channel) { this.drop(channel); } }
    finally { this.connecting.delete(service.serviceName); }
  }
  private tick(): void {
    const now = Date.now();
    this.channels.slice().forEach((channel: Channel) => {
      if ((!channel.peer && now - channel.created > 15000) || (channel.heartbeat && now - channel.lastSeen > 45000)) {
        this.drop(channel);
      } else if (channel.heartbeat) { channel.send(new Packet('ping')).catch(() => this.drop(channel)); }
    });
    this.found.forEach((service: mdns.LocalServiceInfo) => this.connect(service));
  }
}
