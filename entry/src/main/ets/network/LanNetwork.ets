import { common } from '@kit.AbilityKit';
import { socket, mdns } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { Packet, Framer, SERVICE_TYPE, encodePacket } from './Wire';

export class Channel {
  id: string = util.generateRandomUUID();
  peer: string = '';
  heartbeat: boolean = false;
  progress: boolean = false;
  folders: boolean = false;
  lastSeen: number = Date.now();
  created: number = Date.now();
  closed: boolean = false;
  endpoint: string = '';
  framer: Framer = new Framer();
  queue: Promise<void> = Promise.resolve();
  sendQueue: Promise<void> = Promise.resolve();
  pendingBytes: number = 0;
  resumeProbeDeadline: number = 0;
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
  private staleRegistrations: mdns.LocalServiceInfo[] = [];
  private found: Map<string, mdns.LocalServiceInfo> = new Map();
  private connecting: Map<string, number> = new Map();
  private timer: number = -1;
  private active: boolean = false;
  private starting: boolean = false;
  private resourcesReady: boolean = false;
  private generation: number = 0;
  private intent: number = 0;
  private lifecycle: Promise<void> = Promise.resolve();
  private retryAt: number = 0;
  private recoveryQueued: boolean = false;
  private operationTimeout: number = 8000;
  private cleanupTimeout: number = 1500;
  private context: common.UIAbilityContext;
  private deviceId: string;
  private hello: () => Packet;
  constructor(context: common.UIAbilityContext, deviceId: string, hello: () => Packet) {
    this.context = context; this.deviceId = deviceId; this.hello = hello;
  }

  private serial(operation: () => Promise<void>): Promise<void> {
    const task = this.lifecycle.then(operation);
    this.lifecycle = task.catch(() => {});
    return task;
  }
  private bounded<T>(task: Promise<T>, timeout: number = this.operationTimeout): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('网络操作超时')), timeout);
      task.then((value: T) => { clearTimeout(timer); resolve(value); },
        (error: Error) => { clearTimeout(timer); reject(error); });
    });
  }
  private current(generation: number): boolean { return this.active && generation === this.generation; }
  private ensureTimer(): void {
    if (this.timer === -1) { this.timer = setInterval(() => this.tick(), 5000); }
  }
  start(): Promise<void> {
    this.active = true;
    const intent = this.intent;
    return this.serial(async () => {
      if (!this.active || intent !== this.intent || this.resourcesReady) { return; }
      this.ensureTimer();
      await this.rebuild(false);
    });
  }
  // A foreground transition cannot trust native objects retained in background.
  // Recreate listener, advertisement and browser, while probing existing TCP peers.
  resume(): Promise<void> {
    this.active = true;
    const intent = this.intent;
    return this.serial(async () => {
      if (!this.active || intent !== this.intent) { return; }
      this.ensureTimer();
      await this.rebuild(true);
    });
  }
  stop(): Promise<void> {
    this.active = false;
    this.intent++; this.generation++;
    this.resourcesReady = false;
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
    this.channels.slice().forEach((channel: Channel) => this.drop(channel));
    return this.serial(async () => this.releaseResources());
  }
  refresh(): Promise<void> { return this.resume(); }
  private async releaseResources(): Promise<void> {
    const discovery = this.discovery, registered = this.registered, server = this.server;
    this.discovery = undefined; this.registered = undefined; this.server = undefined;
    this.resourcesReady = false;
    this.found.clear(); this.connecting.clear();
    if (discovery) {
      try { discovery.off('serviceFound'); } catch (_) {}
      try { discovery.off('serviceLost'); } catch (_) {}
      try { discovery.off('discoveryStart'); } catch (_) {}
      try { discovery.off('discoveryStop'); } catch (_) {}
      try { discovery.stopSearchingMDNS(); } catch (_) {}
    }
    if (registered) { this.rememberStaleRegistration(registered); }
    for (const service of this.staleRegistrations.slice()) {
      try {
        await this.bounded(mdns.removeLocalService(this.context, service), this.cleanupTimeout);
        this.staleRegistrations = this.staleRegistrations.filter((item: mdns.LocalServiceInfo) => item !== service);
      } catch (_) {} // Retry on the next recovery if mDNS is not yet available.
    }
    if (server) { try { await this.bounded(server.close(), this.cleanupTimeout); } catch (_) {} }
  }
  private rememberStaleRegistration(service: mdns.LocalServiceInfo): void {
    const index = this.staleRegistrations.findIndex((item: mdns.LocalServiceInfo) => item.serviceName === service.serviceName && item.serviceType === service.serviceType);
    if (index >= 0) { this.staleRegistrations[index] = service; }
    else { this.staleRegistrations.push(service); }
  }
  private failed(generation: number, detail: string): void {
    if (!this.current(generation)) { return; }
    this.resourcesReady = false;
    this.retryAt = Date.now() + 5000;
    this.onState(false, detail);
  }
  private probeChannels(): void {
    const deadline = Date.now() + 10000;
    this.channels.slice().forEach((channel: Channel) => {
      if (!channel.peer || !channel.heartbeat) { this.drop(channel); return; }
      channel.resumeProbeDeadline = deadline;
      channel.send(new Packet('ping')).catch(() => this.drop(channel));
    });
  }
  private async rebuild(probe: boolean): Promise<void> {
    this.starting = true;
    const generation = ++this.generation;
    this.resourcesReady = false;
    if (probe) { this.probeChannels(); }
    this.onState(false, '正在恢复局域网连接…');
    try {
      await this.releaseResources();
      if (!this.current(generation)) { return; }
      const server = socket.constructTCPSocketServerInstance();
      this.server = server;
      server.on('connect', (connection: socket.TCPSocketConnection) => {
        if (!this.current(generation) || this.server !== server || this.channels.length >= 64) {
          connection.close().catch(() => {}); return;
        }
        const channel = new Channel(); channel.accepted = connection;
        this.attach(channel); this.sayHello(channel);
      });
      server.on('error', () => this.failed(generation, '监听失效，正在重试局域网连接…'));
      await this.bounded(server.listen({ address: '0.0.0.0', port: 0, family: 1 }));
      if (!this.current(generation)) { return; }
      const address = await this.bounded(server.getLocalAddress());
      if (!this.current(generation)) { return; }
      const registration = mdns.addLocalService(this.context, {
        serviceType: SERVICE_TYPE, serviceName: this.deviceId, port: address.port
      });
      // A late native callback must not resurrect an obsolete advertisement.
      registration.then((service: mdns.LocalServiceInfo) => {
        if (!this.current(generation) && (!this.registered || this.registered.serviceName !== service.serviceName)) {
          this.bounded(mdns.removeLocalService(this.context, service), this.cleanupTimeout)
            .catch(() => this.rememberStaleRegistration(service));
        }
      }, () => {});
      const registered = await this.bounded(registration);
      if (!this.current(generation)) { return; }
      this.registered = registered;
      const discovery = mdns.createDiscoveryService(this.context, SERVICE_TYPE);
      this.discovery = discovery;
      discovery.on('serviceFound', (service: mdns.LocalServiceInfo) => {
        if (!this.current(generation) || this.discovery !== discovery || service.serviceName === this.deviceId ||
          service.serviceName === registered.serviceName) { return; }
        this.found.set(service.serviceName, service); this.connect(service);
      });
      discovery.on('serviceLost', (service: mdns.LocalServiceInfo) => {
        if (this.current(generation) && this.discovery === discovery) { this.found.delete(service.serviceName); }
      });
      const started = new Promise<void>((resolve, reject) => {
        discovery.on('discoveryStart', (event: mdns.DiscoveryEventInfo) => {
          if (!this.current(generation) || this.discovery !== discovery) { return; }
          if (event.errorCode === undefined || event.errorCode === 0) {
            this.resourcesReady = true;
            this.onState(true, '局域网已就绪'); resolve();
          } else {
            this.failed(generation, '设备发现失败，正在重试…'); reject(new Error('设备发现启动失败'));
          }
        });
      });
      discovery.on('discoveryStop', () => this.failed(generation, '设备发现已中断，正在重试…'));
      // Attach the rejection handler before starting an API that may throw.
      const waitForStart = this.bounded(started);
      try { discovery.startSearchingMDNS(); }
      catch (error) {
        waitForStart.catch(() => {});
        throw error as Error;
      }
      await waitForStart;
    } catch (error) {
      if (this.current(generation)) {
        this.generation++;
        await this.releaseResources();
        this.retryAt = Date.now() + 5000;
        this.onState(false, `局域网连接失败，将自动重试：${(error as Error).message}`);
      }
    } finally { this.starting = false; }
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
            channel.resumeProbeDeadline = 0;
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
    const generation = this.generation;
    this.connecting.set(service.serviceName, generation);
    let channel: Channel | undefined;
    try {
      const resolved = await this.bounded(mdns.resolveLocalService(this.context, service));
      if (!this.current(generation) || !resolved.host || !resolved.port || this.channelFor(service.serviceName)) { return; }
      channel = new Channel();
      channel.endpoint = service.serviceName;
      const client = socket.constructTCPSocketInstance();
      channel.client = client;
      this.attach(channel);
      const family = resolved.host.address.includes(':') ? 2 : 1;
      await this.bounded(client.bind({ address: family === 2 ? '::' : '0.0.0.0', port: 0, family: family }));
      if (!this.current(generation) || channel.closed) { this.drop(channel); return; }
      await this.bounded(client.connect({ address: { address: resolved.host.address, port: resolved.port, family: family }, timeout: 8000 }));
      if (!this.current(generation) || channel.closed) { this.drop(channel); return; }
      this.sayHello(channel);
    } catch (_) { if (channel) { this.drop(channel); } }
    finally { if (this.connecting.get(service.serviceName) === generation) { this.connecting.delete(service.serviceName); } }
  }
  private tick(): void {
    if (!this.active) { return; }
    const now = Date.now();
    this.channels.slice().forEach((channel: Channel) => {
      if (channel.resumeProbeDeadline > 0) {
        if (now >= channel.resumeProbeDeadline) { this.drop(channel); }
        return;
      }
      if ((!channel.peer && now - channel.created > 15000) || (channel.heartbeat && now - channel.lastSeen > 45000)) {
        this.drop(channel);
      } else if (channel.heartbeat) { channel.send(new Packet('ping')).catch(() => this.drop(channel)); }
    });
    if (this.resourcesReady) { this.found.forEach((service: mdns.LocalServiceInfo) => this.connect(service)); }
    else if (!this.starting && !this.recoveryQueued && now >= this.retryAt) {
      this.recoveryQueued = true;
      this.resume().finally(() => { this.recoveryQueued = false; });
    }
  }
}
