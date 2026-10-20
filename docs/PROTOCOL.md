# Mac / HarmonyOS 邻聊互通协议

## 发现与帧

Bonjour/mDNS 服务类型 `_lanternchat._tcp`，服务名为本机持久 UUID。发布真实监听端口，发现后解析主机地址并建立 TCP 连接。Mac 客户端源代码是兼容依据：`Sources/LanChat/Wire.swift`、`ChatStore.swift`。

每帧为 4 字节无符号大端 JSON UTF-8 字节数，随后是 JSON；帧体范围 1…131072 字节。必须处理 TCP 拆包和粘包；文件数据以 Base64 字符串置于 JSON `data` 字段，对应 Swift Codable 的 `Data` 默认编码。

所有包有 `kind` 和 `id`（不超过 64 字符），控制包 id 也用 UUID。`hello` 必须先于业务包；同一会话不能切换 sender。

| kind | 字段 / 行为 |
| --- | --- |
| hello | sender: 持久 UUID，name: 设备名，deviceType: PC/Phone，onlineFor: 本次运行秒数，runID: 本次运行 UUID，supportsHeartbeat / supportsProgress: true |
| text | id: 消息 UUID，text: 不超过 32 KB UTF-8；接收端按对端+id去重 |
| ack | 沿用 text id，确认收到文字 |
| ping / pong | 沿用 ping id 回应 pong；持续无包超过45秒关闭支持心跳的会话 |
| offer | id: 文件 UUID，name: 文件名，size: 总字节数 |
| accept / reject | 沿用文件 id，reject.text 可为失败原因 |
| chunk | 沿用文件 id，data: Base64；发送端每块最多48 KB原始字节 |
| progress | 沿用文件 id，size: 已接收字节；只在对端声明支持时发送 |
| end | 数据传完后发送；接收端核对累计字节并完成原子发布 |
| complete | 接收端成功保存后返回；发送方才显示“对方已接收” |

新字段保持可选，旧 Mac 客户端忽略未知字段。未声明心跳能力的旧会话不因未回复心跳被踢下线。设备类型不是身份证明。

## 文件与历史

接收时生成随机本地目录，先写 `.receiving.part`，总长匹配且收到 end 后才重命名为清洗过的文件名。对方传来的路径不能指定本地目录，同名接收不会覆盖已有文件。按 peer+id 关联传输，其他连接不能取消不属于自己的传输。断线、字节越界或120秒无进展会清理临时接收文件并标记失败。

文件成功接收存入应用私有 filesDir；由系统 DocumentViewPicker 另存到用户选定目录。每次选择的发送附件先复制为本地稳定副本，避免选择器临时 URI 失效。

历史采用本地 JSON 临时文件加重命名保存；重启把进行中的传输标为中断，设备改为离线。索引损坏时保留原文件并停止覆盖，向用户显示错误。
