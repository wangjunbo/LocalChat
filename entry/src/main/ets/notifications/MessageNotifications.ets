import { notificationManager } from '@kit.NotificationKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { ChatStore } from '../store/ChatStore';
import { Message, Peer } from '../model/Models';

export class MessageNotifications {
  private store: ChatStore;
  private context: common.UIAbilityContext;
  private queue: Promise<void> = Promise.resolve();
  private nextId: number = Date.now() % 2000000000;
  constructor(context: common.UIAbilityContext, store: ChatStore) {
    this.context = context; this.store = store;
    store.onIncoming = (message: Message) => {
      this.queue = this.queue.then(() => this.publish(message)).catch(() => {
        console.warn('LocalChat: message notification could not be delivered');
      });
    };
    store.onUnreadChange = () => this.updateBadge();
    this.updateBadge();
  }
  async enable(): Promise<void> {
    try {
      await notificationManager.requestEnableNotification(this.context);
      await notificationManager.addSlot(notificationManager.SlotType.SOCIAL_COMMUNICATION);
      this.updateBadge();
    } catch (_) {
      this.store.notice = '消息通知未开启，可在系统设置中允许邻聊通知';
      this.store.onChange();
    }
  }
  private updateBadge(): void {
    this.queue = this.queue.then(async () => {
      await notificationManager.setBadgeNumber(this.store.unreadCount());
    }).catch(() => { console.warn('LocalChat: badge update unavailable'); });
  }
  private async publish(message: Message): Promise<void> {
    if (!await notificationManager.isNotificationEnabled()) { return; }
    const id = ++this.nextId;
    const agent = await wantAgent.getWantAgent({
      wants: [{ bundleName: 'com.hohode.localchat', abilityName: 'EntryAbility', parameters: { chatPeer: message.peer } }],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: id,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
    await notificationManager.publish({
      id: id,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: this.store.peers.find((peer: Peer) => peer.id === message.peer)?.name || '邻聊新消息',
          text: (message.name ? `[文件] ${message.name}` : message.text).slice(0, 240)
        }
      },
      wantAgent: agent,
      autoDeletedTime: Date.now() + 24 * 60 * 60 * 1000
    });
    await notificationManager.setBadgeNumber(this.store.unreadCount());
  }
}
