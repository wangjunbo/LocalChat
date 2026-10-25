import { FrameCallback, KeyboardAvoidMode, window, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileUri } from '@kit.CoreFileKit';
import { ChatStore } from '../store/ChatStore';
import { Peer, Message, Attachment, IncomingShare, APP_VERSION, ASSISTANT_ID, isImage, sizeLabel, formatMessageDate } from '../model/Models';

// onIdle runs after this frame's layout/draw, so the new message has its final height.
class AfterChatLayout extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  onFrame(_frameTimeInNano: number): void {}
  onIdle(_timeLeftInNano: number): void { this.action(); }
}

interface DialogChoice { index: number; }
class ViewState {
  shares: IncomingShare[] = [];
  importingShares: number = 0;
  peers: Peer[] = [];
  messages: Message[] = [];
  attachments: Attachment[] = [];
  name: string = '鸿蒙手机';
  ready: boolean = false;
  networkStatus: string = '正在启动…';
  notice: string = '';
  error: string = '';
}
const BLUE: string = '#2964A6';
const INK: string = '#293B4D';
const MUTED: string = '#697D90';

@Entry
@Component
struct Index {
  @StorageLink('systemTopPx') private systemTopPx: number = 0;
  @StorageLink('systemBottomPx') private systemBottomPx: number = 0;
  @StorageLink('systemLeftPx') private systemLeftPx: number = 0;
  @StorageLink('systemRightPx') private systemRightPx: number = 0;
  @State private state: ViewState = new ViewState();
  @State private selected: string = '';
  @State private sharePeer: string = '';
  @State private shareSending: boolean = false;
  @State private returning: boolean = false;
  @State private entering: boolean = false;
  @State private isWide: boolean = false;
  private opening: boolean = false;
  private backAfterOpening: boolean = false;
  @State private query: string = '';
  @State private historyQuery: string = '';
  @State private draft: string = '';
  @State private settings: boolean = false;
  @State private editingName: string = '';
  @State @Watch('updateSystemBarContent') private previewPath: string = '';
  @State private submitting: boolean = false;
  private composerFocused: boolean = false;
  private followLatest: boolean = true;
  private pageActive: boolean = false;
  private scrollGeneration: number = 0;
  private store?: ChatStore;
  private scroller: Scroller = new Scroller();
  @State private fileMenuMessage?: Message = undefined;
  @State private showRenameDialog: boolean = false;
  @State private newFileName: string = '';

  aboutToAppear(): void {
    this.pageActive = true;
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.store = ChatStore.shared(context);
    this.store.onChange = () => this.updateState();
    this.updateState();
    this.store.start();
  }
  aboutToDisappear(): void { this.pageActive = false; this.scrollGeneration++; if (this.store) { this.store.onChange = () => {}; } }
  onBackPress(): boolean {
    if (this.state.shares.length || this.state.importingShares > 0) {
      if (!this.shareSending && this.state.shares.length) { this.store?.cancelShare(this.state.shares[0].id); }
      return true;
    }
    if (this.showRenameDialog) { this.showRenameDialog = false; return true; }
    if (this.previewPath) { this.previewPath = ''; return true; }
    if (this.settings) { this.settings = false; return true; }
    if (this.selected) { this.goBack(); return true; }
    return false;
  }
  private updateSystemBarContent(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    window.getLastWindow(context).then((mainWindow: window.Window) => {
      const color = this.previewPath ? '#FFFFFF' : INK;
      return mainWindow.setWindowSystemBarProperties({
        statusBarContentColor: color, navigationBarContentColor: color
      });
    }).catch(() => {});
  }
  private updateState(): void {
    if (!this.store) { return; }
    if (this.store.requestedPeer) {
      this.selected = this.store.requestedPeer;
      this.store.requestedPeer = '';
      this.store.activePeer = this.selected;
      this.draft = ''; this.historyQuery = '';
      this.store.markRead(this.selected);
      this.scrollToLatest();
    }
    const previousCount = this.state.messages.filter((item: Message) => item.peer === this.selected).length;
    const state = new ViewState();
    state.shares = this.store.incomingShares.slice();
    state.importingShares = this.store.importingShares;
    if (!this.state.shares.length && !this.state.importingShares && (state.shares.length || state.importingShares)) {
      this.getUIContext().getFocusController().clearFocus();
      this.previewPath = '';
      this.showRenameDialog = false;
      this.settings = false;
    }
    if (state.shares[0]?.id !== this.state.shares[0]?.id) { this.sharePeer = ''; }
    state.peers = JSON.parse(JSON.stringify(this.store.peers)) as Peer[];
    state.messages = JSON.parse(JSON.stringify(this.store.messages)) as Message[];
    state.attachments = this.store.attachments(this.selected).slice();
    state.name = this.store.name; state.ready = this.store.ready;
    state.networkStatus = this.store.networkStatus; state.notice = this.store.notice; state.error = this.store.error;
    this.state = state;
    if (this.selected && !this.historyQuery && state.messages.filter((item: Message) => item.peer === this.selected).length > previousCount) {
      if (this.followLatest || this.composerFocused) { this.scrollToLatest(); }
    }
  }
  private scrollToLatest(): void {
    if (!this.pageActive || !this.selected || this.historyQuery) { return; }
    const peer = this.selected;
    const generation = ++this.scrollGeneration;
    this.getUIContext().postFrameCallback(new AfterChatLayout((): void => {
      if (!this.pageActive || generation !== this.scrollGeneration || this.selected !== peer || this.historyQuery) { return; }
      this.scroller.scrollEdge(Edge.Bottom);
      this.followLatest = true;
    }));
  }
  private visibleMessages(): Message[] {
    return this.state.messages.filter((message: Message) => message.peer === this.selected &&
      (!this.historyQuery || `${message.text} ${message.name}`.toLowerCase().includes(this.historyQuery.toLowerCase())));
  }
  private goBack(): void {
    if (this.opening) { this.backAfterOpening = true; return; }
    if (this.returning || !this.selected) { return; }
    this.scrollGeneration++;
    if (this.store) { this.store.activePeer = ''; }
    this.composerFocused = false;
    this.getUIContext().getFocusController().clearFocus();
    if (this.isWide) {
      this.selected = '';
      this.draft = '';
      this.historyQuery = '';
      this.returning = false;
      return;
    }
    this.getUIContext().animateTo({
      duration: 260,
      curve: Curve.EaseOut,
      onFinish: () => {
        this.selected = '';
        this.draft = '';
        this.historyQuery = '';
        this.returning = false;
      }
    }, () => { this.returning = true; });
  }
  private selectPeer(id: string): void {
    if (this.opening || this.returning) { return; }
    if (this.selected && !this.isWide) { return; }
    this.scrollGeneration++;
    this.followLatest = true;
    if (this.isWide) {
      this.entering = false;
      this.selected = id;
      if (this.store) { this.store.activePeer = id; this.store.markRead(id); }
      this.draft = '';
      this.historyQuery = '';
      this.updateState();
      this.scrollToLatest();
      return;
    }
    this.entering = true;
    this.opening = true;
    this.backAfterOpening = false;
    this.selected = id;
    if (this.store) { this.store.activePeer = id; this.store.markRead(id); }
    this.draft = '';
    this.historyQuery = '';
    this.updateState();
    // Mount and lay out the chat off-screen before animating both pages together.
    this.getUIContext().postFrameCallback(new AfterChatLayout((): void => {
      if (!this.pageActive || this.selected !== id) { this.opening = false; return; }
      this.getUIContext().animateTo({
        duration: 260,
        curve: Curve.EaseOut,
        onFinish: () => {
          this.opening = false;
          if (this.backAfterOpening) {
            this.backAfterOpening = false;
            this.goBack();
          }
        }
      }, () => { this.entering = false; });
    }));
  }
  private title(): string {
    return this.selected === ASSISTANT_ID ? '文件传输助手' : (this.state.peers.find((peer: Peer) => peer.id === this.selected)?.name || '邻聊');
  }
  private online(): boolean {
    return this.selected === ASSISTANT_ID || this.state.peers.find((peer: Peer) => peer.id === this.selected)?.online === true;
  }
  private deviceType(): string { return this.state.peers.find((peer: Peer) => peer.id === this.selected)?.deviceType || ''; }
  private preview(peer: string): string {
    const list = this.state.messages.filter((message: Message) => message.peer === peer);
    const last = list[list.length - 1];
    return last ? (last.name ? `[${isImage(last.name) ? '图片' : '文件'}] ${last.name}` : last.text) : '点击开始聊天';
  }
  private send(): void {
    if (!this.store || this.submitting) { return; }
    const peer = this.selected;
    const text = this.draft;
    if (!text.trim() && this.store.attachments(peer).length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '请先输入文字或添加图片、文件' });
      return;
    }
    this.submitting = true;
    this.store.submit(peer, text).then((sent: boolean) => {
      if (sent && this.selected === peer && this.draft === text) { this.draft = ''; }
      if (sent && this.selected === peer) { this.followLatest = true; this.scrollToLatest(); }
    }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '发送失败，请重试' });
    }).finally(() => { this.submitting = false; });
  }
  private copy(message: Message): void {
    pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, message.text || message.name));
    this.getUIContext().getPromptAction().showToast({ message: '已复制' });
  }
  private confirmDelete(message: Message): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '删除这条记录？', message: '只删除本机记录，已保存文件会保留。',
      buttons: [{ text: '取消', color: MUTED }, { text: '删除', color: '#BE4141' }]
    }).then((result: DialogChoice) => { if (result.index === 1) { this.store?.removeMessage(message); } });
  }
  private showFileMenu(message: Message): void {
    if (!message.path) {
      const buttons: [promptAction.Button, promptAction.Button?] = message.savedUri ? [
        { text: '打开所在目录', color: BLUE }, { text: '删除记录', color: '#BE4141' }
      ] : [{ text: '删除记录', color: '#BE4141' }];
      this.getUIContext().getPromptAction().showActionMenu({ title: message.name, buttons: buttons })
        .then((result: DialogChoice) => {
          if (message.savedUri && result.index === 0) { this.store?.openSavedDirectory(message); }
          else { this.confirmDelete(message); }
        }).catch(() => {});
      return;
    }
    this.fileMenuMessage = message;
    this.getUIContext().getPromptAction().showActionMenu({
      title: message.name,
      buttons: [
        { text: '永久保存', color: BLUE },
        { text: '分享', color: BLUE },
        { text: '重命名', color: BLUE },
        { text: '删除', color: '#BE4141' }
      ]
    }).then((result: DialogChoice) => {
      switch (result.index) {
        case 0: this.store?.saveToDownload(message); break;
        case 1: this.store?.shareFile(message); break;
        case 2: this.showRenameInput(message); return;
        case 3: this.confirmDeleteFile(message); break;
      }
      this.fileMenuMessage = undefined;
    }).catch(() => { this.fileMenuMessage = undefined; });
  }
  private showRenameInput(message: Message): void {
    this.newFileName = message.name || '';
    this.showRenameDialog = true;
  }
  private confirmRename(): void {
    if (this.fileMenuMessage && this.newFileName.trim()) {
      this.store?.renameFile(this.fileMenuMessage, this.newFileName.trim());
    }
    this.showRenameDialog = false;
    this.fileMenuMessage = undefined;
  }
  private confirmDeleteFile(message: Message): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '删除文件？', message: '将删除此消息及对应文件。',
      buttons: [{ text: '取消', color: MUTED }, { text: '删除', color: '#BE4141' }]
    }).then((result: DialogChoice) => { if (result.index === 1) { this.store?.deleteMessage(message); } });
  }

  build() {
    Column({ space: 0 }) {
      // Paint the system regions explicitly; only the middle Stack contains controls.
      Row().width('100%').height(this.getUIContext().px2vp(this.systemTopPx))
        .backgroundColor(this.previewPath ? '#14202B' : '#DAEBF9')
      Stack() {
      if (this.isWide) {
        Row({ space: 0 }) {
          this.homePane()
          if (this.selected) {
            Column({ space: 0 }) {
              this.chatHeader()
              this.conversation()
            }.layoutWeight(1).height('100%').backgroundColor('#F4F7FA')
          } else {
            this.emptyChatPane()
          }
        }.width('100%').height('100%')
      } else {
        Column({ space: 0 }) {
          this.homeHeader()
          this.statusBanners()
          this.devices()
        }.width('100%').height('100%').backgroundColor('#F4F7FA')
          .translate({ x: this.selected && !this.returning && !this.entering ? '-25%' : '0%' })
          .hitTestBehavior(this.selected ? HitTestMode.None : HitTestMode.Default)
        if (this.selected) {
          Column({ space: 0 }) {
            this.chatHeader()
            this.statusBanners()
            this.conversation()
          }.width('100%').height('100%').backgroundColor('#F4F7FA')
            .translate({ x: this.returning || this.entering ? '100%' : '0%' })
            .hitTestBehavior(this.returning ? HitTestMode.Block : HitTestMode.Default)
        }
      }

      if (this.settings) { this.settingsPanel(); }
      if (this.previewPath) {
        Column() {
          Row() {
            Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(22).fontColor([Color.White]) }
              .type(ButtonType.Normal).backgroundColor(Color.Transparent).onClick(() => { this.previewPath = ''; })
            Blank()
            Text('图片预览').fontColor(Color.White).fontSize(16)
            Blank()
          }.width('100%').padding(16)
          Image(fileUri.getUriFromPath(this.previewPath)).objectFit(ImageFit.Contain).width('100%').layoutWeight(1)
        }.width('100%').height('100%').backgroundColor('#14202B')
      }
      if (this.state.shares.length || this.state.importingShares > 0) { this.incomingSharePanel(); }
      }.width('100%').layoutWeight(1).clip(true)
        .padding({ left: this.getUIContext().px2vp(this.systemLeftPx),
          right: this.getUIContext().px2vp(this.systemRightPx) })
      Row().width('100%').height(this.getUIContext().px2vp(this.systemBottomPx))
        .backgroundColor(this.previewPath ? '#14202B' : (this.selected && !this.isWide ? '#FFFFFF' : '#F4F7FA'))
    }.width('100%').height('100%').backgroundColor(this.previewPath ? '#14202B' : '#F4F7FA')
    .onAreaChange((_oldArea: Area, area: Area) => {
      const next: boolean = Number(area.width) >= 840;
      if (next !== this.isWide) { this.isWide = next; }
    })
    .bindSheet($$this.showRenameDialog, this.renameDialogBuilder(), {
      preferType: SheetType.CENTER, height: 220, showClose: false, dragBar: false,
      backgroundColor: Color.White
    })
  }
  private async confirmShare(): Promise<void> {
    if (!this.store || !this.sharePeer || !this.state.shares.length || this.shareSending) { return; }
    const incoming = this.state.shares[0];
    const peer = this.sharePeer;
    const name = peer === ASSISTANT_ID ? '文件传输助手' : this.state.peers.find((item: Peer) => item.id === peer)?.name || '所选设备';
    this.shareSending = true;
    try {
      if (await this.store.sendShare(incoming.id, peer)) {
        this.getUIContext().getPromptAction().showToast({ message: peer === ASSISTANT_ID ? '已保存到文件传输助手' : `已加入与 ${name} 的发送队列` });
      }
    } finally { this.shareSending = false; }
  }
  @Builder
  private shareRecipient(id: string, name: string, status: string) {
    Row({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.person')).fontSize(22).fontColor([BLUE])
      Column({ space: 4 }) {
        Text(name).fontSize(15).fontColor(INK).maxLines(1)
        Text(status).fontSize(11).fontColor(MUTED)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (this.sharePeer === id) { SymbolGlyph($r('sys.symbol.checkmark')).fontSize(18).fontColor([BLUE]) }
    }.width('100%').padding(12).borderRadius(5)
      .backgroundColor(this.sharePeer === id ? '#DAEBF9' : Color.White)
      .onClick(() => { if (!this.shareSending) { this.sharePeer = id; } })
  }
  @Builder
  private incomingSharePanel() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(21).fontColor([BLUE]) }
          .type(ButtonType.Normal).backgroundColor(Color.Transparent).enabled(!this.shareSending && this.state.shares.length > 0)
          .onClick(() => this.store?.cancelShare(this.state.shares[0].id)).accessibilityText('取消本次分享')
        Text('分享至邻聊').fontSize(20).fontWeight(FontWeight.Medium).fontColor(INK)
        Blank()
        if (this.state.shares.length > 1) { Text(`还有 ${this.state.shares.length - 1} 份分享`).fontSize(11).fontColor(MUTED) }
      }.width('100%')
      this.statusBanners()
      if (this.state.shares.length) {
        Text(`选择接收设备 · ${this.state.shares[0].files.length} 个文件`).fontSize(13).fontColor(MUTED).width('100%')
        Scroll() {
          Column({ space: 6 }) {
            ForEach(this.state.shares[0].files, (file: Attachment) => {
              Text(`${file.name} · ${sizeLabel(file.size)}`).fontSize(13).fontColor(INK).width('100%').maxLines(2)
            }, (file: Attachment) => file.id)
            if (this.state.shares[0].text) { Text(this.state.shares[0].text).fontSize(13).fontColor(INK).width('100%').maxLines(5) }
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.width('100%').constraintSize({ maxHeight: 150 })
        List({ space: 6 }) {
          ListItem() { this.shareRecipient(ASSISTANT_ID, '文件传输助手', '仅保存在本机') }
          ForEach(this.state.peers, (peer: Peer) => {
            ListItem() { this.shareRecipient(peer.id, peer.name, peer.online ? '在线 · 局域网直传' : '离线 · 上线后自动发送') }
          }, (peer: Peer) => `${peer.id}-${peer.name}-${peer.online}`)
          if (!this.state.peers.length) {
            ListItem() {
              Text('暂无附近设备。请让对方连接同一 Wi-Fi 并打开邻聊，也可先保存到本机。')
                .fontSize(13).fontColor(MUTED).lineHeight(22).padding(12)
            }
          }
        }.layoutWeight(1).width('100%')
        Button('刷新附近设备').type(ButtonType.Normal).borderRadius(5).fontColor(BLUE).backgroundColor('#EAF4FD')
          .onClick(() => this.store?.refresh())
        Row({ space: 12 }) {
          Button('取消').type(ButtonType.Normal).borderRadius(5).layoutWeight(1).enabled(!this.shareSending)
            .onClick(() => this.store?.cancelShare(this.state.shares[0].id))
          Button(this.shareSending ? '正在处理…' : (this.sharePeer === ASSISTANT_ID ? '确认保存' : '确认发送'))
            .type(ButtonType.Normal).borderRadius(5).backgroundColor(BLUE).fontColor(Color.White).layoutWeight(1)
            .enabled(!!this.sharePeer && !this.shareSending).onClick(() => this.confirmShare())
        }.width('100%')
      } else {
        Blank()
        LoadingProgress().width(36).height(36)
        Text('正在接收分享内容…').fontSize(14).fontColor(MUTED)
        Blank()
      }
    }.padding(18).width('100%').height('100%').backgroundColor('#F4F7FA')
  }
  @Builder
  private renameDialogBuilder() {
    Column({ space: 20 }) {
      Column({ space: 16 }) {
        Text('重命名文件').fontSize(18).fontWeight(FontWeight.Medium).fontColor(INK)
        TextInput({ text: this.newFileName })
          .fontSize(15).height(44).borderRadius(6)
          .onChange((value: string) => { this.newFileName = value; })
          .width('100%')
      }.padding(20).backgroundColor(Color.White).borderRadius(12)
      Row({ space: 12 }) {
        Button('取消').type(ButtonType.Normal).borderRadius(6).height(40)
          .fontSize(16)
          .fontColor(MUTED)
          .backgroundColor(Color.White)
          .layoutWeight(1)
          .onClick(() => {
            this.showRenameDialog = false;
            this.fileMenuMessage = undefined;
          })
        Button('确定').type(ButtonType.Normal).borderRadius(6).height(40)
          .fontSize(16)
          .fontColor(Color.White)
          .backgroundColor(BLUE)
          .layoutWeight(1)
          .onClick(() => { this.confirmRename(); })
      }.width('100%')
    }.width(300).padding(20).backgroundColor(Color.White).borderRadius(8)
  }
  @Builder
  private statusBanners() {
        if (this.state.notice) {
          Text(this.state.notice || '').fontSize(12).fontColor(BLUE)
            .padding(10).width('100%').backgroundColor('#EAF4FD')
        }
        if (this.state.error) {
          Row({ space: 8 }) {
            Text(this.state.error || '').fontSize(12).fontColor('#A53A32').layoutWeight(1)
            Button('关闭').fontSize(11).type(ButtonType.Normal).borderRadius(4)
              .onClick(() => this.store?.clearError())
          }.padding(10).backgroundColor('#FFF0EB')
        }
  }
  @Builder
  private homeHeader() {
    Column({ space: 16 }) {
      Row({ space: 10 }) {
        Image($r('app.media.app_icon')).width(42).height(42).borderRadius(8)
        Column({ space: 2 }) {
          Text('邻聊').fontSize(25).fontWeight(FontWeight.Bold).fontColor(INK)
          Text('同一网络，即刻连接').fontSize(11).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start)
        Blank()
        Button() { SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(21).fontColor([BLUE]) }
          .type(ButtonType.Normal).backgroundColor(Color.Transparent).onClick(() => this.store?.refresh())
          .accessibilityText('刷新附近设备')
      }.width('100%')
      TextInput({ text: this.query, placeholder: '搜索附近设备' }).height(38).fontSize(14)
        .backgroundColor('#FFFFFF').borderRadius(5).onChange((value: string) => { this.query = value; })
    }.padding({ left: 20, right: 20, top: 18, bottom: 16 }).backgroundColor('#DAEBF9')
  }
  @Builder
  private devices() {
    Column({ space: 0 }) {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.folder')).fontSize(25).fontColor(['#4E873F'])
        Column({ space: 5 }) {
          Text('文件传输助手').fontSize(16).fontWeight(FontWeight.Medium).fontColor(INK)
          Text(this.preview(ASSISTANT_ID)).fontSize(12).fontColor(MUTED).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text('仅本机').fontSize(10).fontColor(MUTED)
      }.width('100%').padding(16).backgroundColor(Color.White).borderRadius(6)
        .onClick(() => this.selectPeer(ASSISTANT_ID))
      Row() {
        Text('附近的设备').fontSize(12).fontColor(MUTED)
        Blank()
        Text(`${this.state.peers.filter((peer: Peer) => peer.online).length || 0} 在线`).fontSize(12).fontColor(MUTED)
      }.width('100%').padding({ top: 22, bottom: 10 })
      List({ space: 8 }) {
        ForEach((this.state.peers || []).filter((peer: Peer) => !this.query || peer.name.toLowerCase().includes(this.query.toLowerCase())), (peer: Peer) => {
          ListItem() {
            Row({ space: 12 }) {
              Text(peer.name.slice(0, 1)).fontSize(20).fontWeight(FontWeight.Medium).fontColor(BLUE)
                .width(42).height(42).textAlign(TextAlign.Center).backgroundColor('#E4EFF8').borderRadius(6)
              Column({ space: 5 }) {
                Row({ space: 6 }) {
                  Text(peer.name).fontSize(15).fontColor(INK).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                  if (peer.deviceType) { Text(peer.deviceType).fontSize(10).fontColor(BLUE) }
                }.width('100%')
                Text(this.preview(peer.id)).fontSize(12).fontColor(MUTED).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              if (this.state.messages.filter((item: Message) => item.peer === peer.id && item.unread === true && !item.mine).length > 0) {
                Text(`${this.state.messages.filter((item: Message) => item.peer === peer.id && item.unread === true && !item.mine).length}`)
                  .fontSize(11).fontColor(Color.White).backgroundColor('#D94343').borderRadius(10)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              }
              Circle().width(7).height(7).fill(peer.online ? '#4F9B45' : '#A4ACB4')
            }.padding(14).width('100%').backgroundColor(Color.White).borderRadius(6)
          }.onClick(() => this.selectPeer(peer.id))
            .gesture(LongPressGesture().onAction(() => { if (!peer.online) { this.store?.removePeer(peer); } }))
        }, (peer: Peer) => `${peer.id}-${peer.name}-${peer.online}-${peer.deviceType}-${this.preview(peer.id)}-${this.store?.unreadCount(peer.id)}`)
        if ((this.state.peers.length || 0) === 0) {
          ListItem() {
            Column({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.wifi')).fontSize(34).fontColor(['#A5BDD0'])
              Text('等待附近的设备').fontSize(16).fontColor(INK)
              Text('让 Mac 或手机连接同一 Wi-Fi，\n打开邻聊后会自动出现在这里。').fontSize(13).fontColor(MUTED).textAlign(TextAlign.Center).lineHeight(22)
            }.width('100%').padding({ top: 52, bottom: 30 })
          }
        }
      }.layoutWeight(1).width('100%')
      Row({ space: 6 }) {
        Circle().width(6).height(6).fill(this.state.ready ? '#4F9B45' : '#D29242')
        Text(this.state.networkStatus || '正在启动…').fontSize(11).fontColor(MUTED).layoutWeight(1)
      }.width('100%').padding({ top: 12, bottom: 12 })
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.phone')).fontSize(20).fontColor([MUTED])
        Column({ space: 3 }) {
          Text(this.state.name || '鸿蒙手机').fontSize(13).fontColor(INK).maxLines(1)
          Text('本机 · Phone').fontSize(10).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(`v${APP_VERSION}`).fontSize(10).fontColor(MUTED)
        SymbolGlyph($r('sys.symbol.gearshape')).fontSize(20).fontColor([MUTED])
      }.width('100%').padding({ top: 14, bottom: 18 }).border({ width: { top: 0.5 }, color: '#D8E2EA' })
        .onClick(() => { this.editingName = this.state.name || ''; this.settings = true; })
    }.padding({ left: 18, right: 18 }).layoutWeight(1).width('100%')
  }
  @Builder
  private homePane() {
    Column({ space: 0 }) {
      this.homeHeader()
      this.statusBanners()
      this.devices()
    }.width(340).height('100%').backgroundColor('#F4F7FA')
      .border({ width: { right: 0.5 }, color: '#D8E2EA' })
  }

  @Builder
  private emptyChatPane() {
    Column({ space: 14 }) {
      Image($r('app.media.app_icon')).width(64).height(64).borderRadius(12).opacity(0.6)
      Text('选择左侧设备开始聊天').fontSize(16).fontColor(INK)
      Text('消息和文件只在同一局域网内直传').fontSize(13).fontColor(MUTED)
    }.layoutWeight(1).height('100%').justifyContent(FlexAlign.Center).backgroundColor('#F4F7FA')
  }

  @Builder
  private chatHeader() {
    Row({ space: 9 }) {
      if (!this.isWide) {
        Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(21).fontColor([BLUE]) }
          .width(30).height(36).type(ButtonType.Normal).backgroundColor(Color.Transparent)
          .onClick(() => this.goBack()).accessibilityText('返回设备列表')
      }
      Column({ space: 2 }) {
        Row({ space: 7 }) {
          Text(this.title()).fontSize(16).fontWeight(FontWeight.Medium).fontColor(INK).maxLines(1)
          if (this.deviceType()) { Text(this.deviceType()).fontSize(10).fontColor(BLUE) }
        }
        Text(this.selected === ASSISTANT_ID ? '仅保存在本机' : (this.online() ? '在线 · 局域网直连' : '离线 · 留言将在上线后发送'))
          .fontSize(10).fontColor(MUTED)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }.width('100%').padding({ left: this.isWide ? 16 : 10, right: 16, top: 8, bottom: 8 }).backgroundColor('#DAEBF9')
  }
  @Builder
  private conversation() {
    Column({ space: 0 }) {
      TextInput({ text: this.historyQuery, placeholder: '查找当前对话的文字或文件名' }).fontSize(12).height(36)
        .backgroundColor(Color.White).borderRadius(4).margin({ top: 8, left: 12, right: 12, bottom: 6 })
        .onChange((value: string) => { this.historyQuery = value; })
      List({ space: 16, scroller: this.scroller }) {
        ForEach(this.visibleMessages(), (message: Message) => {
          ListItem() { this.messageBubble(message); }
        }, (message: Message) => `${message.id}-${message.status}-${message.transferred}-${message.path}`)
      }.layoutWeight(1).width('100%').padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .onAppear(() => this.scrollToLatest())
        .onAreaChange((oldArea: Area, newArea: Area) => {
          if (oldArea.height !== newArea.height && (this.composerFocused || this.followLatest)) {
            this.scrollToLatest();
          }
        })
        .onScrollIndex((_first: number, last: number) => {
          this.followLatest = last >= this.visibleMessages().length - 1;
        })
      this.composer()
    }.layoutWeight(1).width('100%')
  }
  @Builder
  private messageBubble(message: Message) {
    Row() {
      if (message.mine) { Blank().width('12%') }
      Column({ space: 6 }) {
        if (message.name) {
          Column({ space: 7 }) {
            if (message.path && isImage(message.name)) {
              Image(fileUri.getUriFromPath(message.path)).width(210).height(150).objectFit(ImageFit.Contain).borderRadius(4)
                .onClick(() => { this.previewPath = message.path; })
            } else {
              Row({ space: 9 }) {
                SymbolGlyph($r('sys.symbol.doc')).fontSize(24).fontColor([BLUE])
                Text(message.name).fontSize(13).fontColor(INK).maxLines(2).layoutWeight(1)
              }.width(210)
            }
            Text(`${sizeLabel(message.transferred)} / ${sizeLabel(message.bytes)} · ${message.status}`)
              .fontSize(10).fontColor(MUTED).maxLines(2)
            if (message.savedUri) {
              Button('打开所在目录').fontSize(11).fontColor(BLUE).height(28)
                .type(ButtonType.Normal).borderRadius(4).backgroundColor('#EDF4FA')
                .onClick(() => this.store?.openSavedDirectory(message))
            }
            if (message.path) {
              Row({ space: 8 }) {
                Button('永久保存').fontSize(11).fontColor(BLUE).height(26).type(ButtonType.Normal).borderRadius(4)
                  .backgroundColor('#EDF4FA').onClick(() => this.store?.saveToDownload(message))
                Button('分享').fontSize(11).fontColor(BLUE).height(26).type(ButtonType.Normal).borderRadius(4)
                  .backgroundColor('#EDF4FA').onClick(() => this.store?.shareFile(message))
              }
            }
          }.alignItems(HorizontalAlign.Start).padding(10).backgroundColor(Color.White).borderRadius(6)
          .gesture(
            LongPressGesture({ repeat: false, duration: 500 })
              .onAction(() => {
                this.showFileMenu(message);
              })
          )
        } else {
          Text(message.text).fontSize(15).fontColor(INK).lineHeight(23).copyOption(CopyOptions.LocalDevice)
            .padding(12).backgroundColor(message.mine ? '#CAE4F7' : '#FFFFFF').borderRadius(6)
        }
        Row({ space: 8 }) {
          Text(formatMessageDate(message.date)).fontSize(9).fontColor(MUTED)
          if (!message.name && message.mine) { Text(message.status).fontSize(9).fontColor(MUTED) }
          Text('复制').fontSize(10).fontColor(BLUE).onClick(() => this.copy(message))
          Text('删除').fontSize(10).fontColor(MUTED).onClick(() => this.confirmDelete(message))
        }
      }.alignItems(message.mine ? HorizontalAlign.End : HorizontalAlign.Start).layoutWeight(1)
      if (!message.mine) { Blank().width('12%') }
    }.width('100%')
  }
  @Builder
  private composer() {
    Column({ space: 4 }) {
      Row({ space: 16 }) {
        Button('图片').height(30).fontSize(13).fontColor(BLUE).type(ButtonType.Normal).backgroundColor(Color.Transparent)
          .onClick(() => this.store?.chooseImages(this.selected))
        Button('文件').height(30).fontSize(13).fontColor(BLUE).type(ButtonType.Normal).backgroundColor(Color.Transparent)
          .onClick(() => this.store?.chooseFiles(this.selected))
        PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Normal }).fontSize(12)
          .onClick((_event: ClickEvent, result: PasteButtonOnClickResult) => {
            if (result === PasteButtonOnClickResult.SUCCESS) {
              const peer = this.selected;
              this.store?.pasteImage(peer).then((text: string) => { if (this.selected === peer) { this.draft += text; } });
            }
          })
        Blank()
        Text(this.selected === ASSISTANT_ID ? '仅本机' : '局域网直传').fontSize(10).fontColor(MUTED)
      }.width('100%')
      Row({ space: 8 }) {
        Column({ space: 0 }) {
          if ((this.state.attachments.length || 0) > 0) {
            Scroll() {
              Row({ space: 8 }) {
                ForEach(this.state.attachments || [], (attachment: Attachment) => {
                  Column({ space: 2 }) {
                    if (isImage(attachment.name)) {
                      Image(fileUri.getUriFromPath(attachment.path)).width(80).height(64).objectFit(ImageFit.Contain)
                        .onClick(() => { this.previewPath = attachment.path; })
                    } else { Text(attachment.name).fontSize(10).width(80).height(64).maxLines(3) }
                    Text('移除').fontSize(10).fontColor(BLUE).onClick(() => this.store?.removeAttachment(this.selected, attachment.id))
                  }.padding(4).borderRadius(4).backgroundColor(Color.White)
                }, (attachment: Attachment) => attachment.id)
              }.padding({ left: 8, right: 8 })
            }.scrollable(ScrollDirection.Horizontal).align(Alignment.Start)
              .width('100%').height(98).margin({ top: 8 })
          }
          TextArea({ text: this.draft, placeholder: this.online() ? '写点什么…' : '离线也可留言，上线后自动发送' })
            .minLines(1).maxLines(5).constraintSize({ minHeight: 38, maxHeight: 118 })
            .padding({ left: 10, right: 10, top: 9, bottom: 9 }).fontSize(14).borderRadius(5).backgroundColor(Color.Transparent).width('100%')
            .onChange((value: string) => { this.draft = value; })
            .onFocus(() => { this.composerFocused = true; this.scrollToLatest(); })
            .onBlur(() => { this.composerFocused = false; })
        }.layoutWeight(1).borderRadius(5).backgroundColor('#F2F5F8')
        Button(this.selected === ASSISTANT_ID ? '保存' : '发送').type(ButtonType.Normal).borderRadius(5)
          .fontSize(13).backgroundColor(BLUE).fontColor(Color.White).height(38)
          .enabled(!this.submitting)
          .focusOnTouch(false)
          .onClick(() => this.send())
      }.width('100%').alignItems(VerticalAlign.Bottom)
    }.width('100%').padding({ left: 12, right: 12, top: 4, bottom: 6 }).backgroundColor(Color.White)
  }
  @Builder
  private settingsPanel() {
    Column({ space: 18 }) {
      Row() {
        Text('让附近的人认识你').fontSize(19).fontWeight(FontWeight.Medium).fontColor(INK)
        Blank()
        Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([MUTED]) }
          .type(ButtonType.Normal).backgroundColor(Color.Transparent).onClick(() => { this.settings = false; })
      }.width('100%')
      TextInput({ text: this.editingName, placeholder: '设备名称' }).maxLength(40).borderRadius(5)
        .onChange((value: string) => { this.editingName = value; })
      Text('邻聊仅连接同一局域网。消息和文件不经过公网服务器；请在可信 Wi-Fi 使用。系统可能在后台暂停网络，回到前台会重新发现设备。')
        .fontSize(12).fontColor(MUTED).lineHeight(20)
      Button('保存').width('100%').type(ButtonType.Normal).borderRadius(5).backgroundColor(BLUE)
        .onClick(() => { this.store?.changeName(this.editingName); this.settings = false; })
    }.padding(22).width(this.isWide ? 440 : '90%').backgroundColor(Color.White).borderRadius(8)
      .shadow({ radius: 30, color: '#33000000' })
  }
}
