[English](README.md) | [한국어](README-ko.md) | [简体中文](README-zh.md) | [日本語](README-ja.md)

# Element X × Tuwunel × Tailscale — 完全本地化聊天方案

**不用 matrix.org、不开公网端口、不用云端聊天账号。** 在手机与自家服务器之间完整
运行的 Matrix 聊天，再叠加一个由本地 LLM 驱动的 AI 机器人。以下全部内容来自
在 Mac mini + iPhone + Element X 上日常使用的真实配置，并经实测验证。

```
iPhone (Element X) ──HTTPS──▶ tailscale serve (443)
                                 ├── /_matrix     ─▶ 127.0.0.1:8008   Tuwunel (Docker)
                                 └── /.well-known ─▶ 127.0.0.1:9111   静态 JSON
服务器内部:
  家服务器 ── RocksDB (./db/)
  机器人 (Hermes Agent gateway) ── 127.0.0.1:8008 ── OpenAI 兼容端点(本地 LLM)
```

能得到什么：

- iPhone 与自家服务器之间的私密聊天（直接使用 Element X）
- AI 机器人（任何 OpenAI 兼容端点均可；推荐本地 LLM）
- 手机的推送通知（工作原理与注意点见"通知与隐私"）
- 外部依赖只有两个：Tailscale（免费档）和 Element X 应用。消息正文与媒体
  全部留在你自己的磁盘上

前提：

- 一台 Mac（推荐 Mac mini，已在 Apple Silicon 上验证）或 Linux 主机
- Docker（Mac 上推荐 colima）
- Tailscale（启用 MagicDNS）+ iPhone 上安装 Tailscale 应用和 Element X
- 耗时：30–60 分钟（不含机器人约 20 分钟）

**"完全本地"的范围是?** 消息正文、媒体、账号，以及（大脑用本地 LLM 时）
机器人的推理都不会离开你的网络。但仍有三条路径接触外部：① Tailscale 的控制
平面（连接元数据；想消除可用自托管的 Headscale）② iOS 推送通知（Element 的
Sygnal → Apple APNs；明文房间的推送载荷里带正文——见§8；Android 的
UnifiedPush 可以消除这条路径）③ Element X 应用本身（App Store 分发、应用内
遥测设置）。

---

## 0. 先做决定（以后改不了）

**`server_name` 是永久的。** 它写进每个用户 ID（`@you:server_name`），事后
更改会使所有账号、房间和历史全部失效。使用 Tailscale 时，最简单的做法是
从第一天起就用服务器的 tailnet 主机名（例如 `matrix.example.ts.net`）作为
server_name。

> 实战备注：我们自己的服务器出于历史原因，server_name 与客户端连接的主机名
> 不同（federation 关闭时名字只是一个标签，照样能用）。但对全新部署来说，
> **从一开始就保持一致**才是正确做法。

federation 关闭（`allow_federation = false`）。代价是与外部 Matrix 服务器
断开，收益是攻击面几乎为零。

---

## 1. 家服务器：用 Docker 跑 Tuwunel

[Tuwunel](https://github.com/matrix-construct/tuwunel) 是 Conduit 系中仍在
积极维护的实现（轻量 Matrix 家服务器·Rust·单一二进制·所有数据都在一个
RocksDB 目录）。本方案默认使用它：它实现了 Element X 用于已读状态的 sliding
sync 回执扩展，所以上游 Conduit 自带的未读角标 bug（gotcha #15）在这里根本
不存在。本方案的参考服务器正以 Tuwunel v1.9.4 运行。

```bash
git clone https://github.com/<you>/elementx-local-recipe.git
cd elementx-local-recipe/scripts
cp tuwunel.toml.example tuwunel.toml
# 编辑 tuwunel.toml：
#   server_name         ← 永久使用的名字（先读上面的注意事项）
#   registration_token  ← 长随机字符串（例如 openssl rand -hex 16）
#   注意：令牌在数据库首次创建时读取。之后改配置对已有数据库无效。
./run-matrix.sh
curl -s http://127.0.0.1:8008/_matrix/client/versions   # 返回 JSON 即成功
```

在 Mac 上建议用 colima 跑 Docker。**要配置容器的外发 DNS**（通知用的 push
gateway 需要外发连接；默认配置坏了的话，"只有通知静默失效"）：

```bash
brew install colima docker
colima start --vm-type vz --cpu 2 --memory 2 --disk 20 --mount-type virtiofs \
  --dns 1.1.1.1 --dns 8.8.8.8
```

家服务器只监听 `127.0.0.1:8008`。TLS 由前面的 tailscale serve 终结，服务器
自身不需要证书。

> 想用官方 Conduit 也可以（`conduit.toml.example`）——但请用 **0.10.14 或
> 更新版本**（CVE-2025-68667 / CVE-2026-24471 已在 0.10.11 修复，认证绕过类
> 在 0.10.13/0.10.14 修复；发布节奏慢，CVE 信息要自己跟进），并注意
> **gotcha #15**：官方版的 simplified sliding sync 永远返回空的回执扩展，
> Element X 的未读角标会卡住。永久解法是迁移到 Tuwunel——
> [`docs/migrate-conduit-to-tuwunel.md`](docs/migrate-conduit-to-tuwunel.md)。

---

## 2. Discovery：`/.well-known/matrix/client`

Element X 会向**你在登录界面输入的主机名**请求
`GET /.well-known/matrix/client`，并使用其中的 `base_url`。把这个文件提供好，
就是 discovery 的正本。

```bash
# 静态文件（serve-wellknown.py 也能自动生成）
mkdir -p wellknown-root/matrix
echo '{"m.homeserver":{"base_url":"https://matrix.example.ts.net"}}' \
  > wellknown-root/matrix/client

# 用 127.0.0.1:9111 提供服务（--homeserver-url 填你的主机名）
python3 scripts/serve-wellknown.py --root wellknown-root --port 9111 \
  --homeserver-url https://matrix.example.ts.net
```

常驻的话注册到 launchd（Mac）或 systemd（Linux）。内容只是静态 JSON，用
`python3 -m http.server 9111 --directory wellknown-root --bind 127.0.0.1`
也一样。

> 实测＋源码确认备注：Conduit 官方版（v0.10.15）的 well-known 配置正确写法
> 是 `[global.well_known]` **子表**。conduwuit / continuwuity 系配置里看到的
> 扁平键 `well_known_client` 是**分支专属键名**——官方 Conduit 会静默忽略它
> （未定义键落入 catchall，不警告也不报错）。被忽略时，Conduit 自己的
> `8008/.well-known` 会返回由 `server_name` 推导的默认 URL。登录响应里也没有
> `well_known` 字段，所以 **discovery 的正本只有一处：你输入的主机名的
> `/.well-known`**。这里配对了，Conduit 自身的 well-known 错了也不影响。
> 规范明确允许由另一台 Web 服务器提供 well-known（CORS 头是 SHOULD——
> `python3 -m http.server` 不返回 CORS 头，严格要求就用 `serve-wellknown.py`）。

---

## 3. 用 tailscale serve 对外发布（无需端口转发）

TLS 终结与对外发布都交给 tailscale serve。路由器不用开端口，服务器只在
tailnet 内可见。

```bash
tailscale serve --bg --https=443 --set-path=/_matrix http://127.0.0.1:8008/_matrix
sleep 2
tailscale serve --bg --https=443 --set-path=/.well-known http://127.0.0.1:9111/.well-known
sleep 2
tailscale serve status   # 务必确认两行都在
```

或运行 `scripts/serve-paths.sh`（自带校验）。

**ACL 注意**：tailnet 策略要允许手机到这台服务器的 `tcp:443`（Tailscale
默认拒绝）。没允许之前只有手机超时——服务器自己能看到自己，所以很容易漏掉。
在服务器上自测 curl 也可能有假阴性，最好从另一台 tailnet 设备验证。

---

## 4. 创建账号

**Element X 只能登录，不能注册**（应用内的注册流程面向带托管认证服务的
服务器）。用注册令牌走 API 创建：

```bash
export REGISTRATION_TOKEN='你在 conduit.toml 里设置的令牌'
./scripts/create-account.sh https://matrix.example.ts.net you
# 会要求输入密码 → 在 Element X 用同样的组合登录
```

它做的只是单个请求：

```
POST /_matrix/client/v3/register
{"username": "you", "password": "...", "inhibit_login": true,
 "auth": {"type": "m.login.registration_token", "token": "..."}}
```

---

## 5. 在 iPhone 上登录 Element X

1. iPhone 安装 Tailscale 应用（保持连接）和 Element X
2. 在 Element X 登录界面选择 "Sign in manually → Change account provider →
   Other"，输入 `https://matrix.example.ts.net`
   （二维码登录以 Matrix Authentication Service 为前提，Conduit/Tuwunel 上不可用。
   用用户名＋密码登录。Element X 先探测 OIDC 认证元数据，没有就回退到密码
   登录，所以没有 MAS 也能顺利通过）
3. 用步骤 4 创建的账号登录
4. 建房间 → 邀请机器人（步骤 6 之后）
5. 登录后会提示恢复密钥和设备验证——不用加密房间的话全部跳过即可

**手机端注意（iPhone）**：打开 Tailscale 的 MagicDNS。iCloud 私人中继 /
Wi-Fi 的"限制 IP 地址跟踪"会间歇性破坏 `*.ts.net` 连接（已知问题），在该
Wi-Fi 下请关闭。常驻 VPN 和隐私类浏览器扩展也可能挡住 `*.ts.net`，请关闭
或排除。

**不要加密这些房间**（本方案的机器人不支持 E2EE——原因见"坑"）。Element X
用明文房间完全正常。

---

## 6. 加上 AI 机器人（Hermes Agent）

住在聊天房间里的机器人用
[Hermes Agent](https://hermes-agent.nousresearch.com)（Nous Research）的
gateway 功能实现。机器人的大脑可以是任何 OpenAI 兼容端点——指向本地 LLM
服务器（比如经 LiteLLM）即可完全离线运行。

```bash
# 1) 创建机器人账号
REGISTRATION_TOKEN=... ./scripts/create-account.sh https://matrix.example.ts.net bot

# 2) 准备机器人的 HOME 和环境变量文件
mkdir -p ~/matrix-bot-home
cp scripts/matrix.env.example ~/matrix-bot-home/.env
chmod 600 ~/matrix-bot-home/.env
#   MATRIX_HOMESERVER=http://127.0.0.1:8008
#   MATRIX_USER_ID=@bot:matrix.example.ts.net
#   MATRIX_PASSWORD=...
#   MATRIX_DEVICE_ID=botdev01          ← 保持固定（避免幽灵设备）
#   MATRIX_ALLOWED_USERS=@you:matrix.example.ts.net
#   MATRIX_HOME_ROOM=!…:…              ← 机器人的主房间
#   MATRIX_E2EE_MODE=optional
#   OPENAI_BASE_URL / OPENAI_API_KEY   ← 大脑（任何 OpenAI 兼容端点）

# 3) 注册到 launchd（把 plist 模板改成你的路径）
cp scripts/com.example.matrix-bot.plist.example \
   ~/Library/LaunchAgents/com.example.matrix-bot.plist
#   （填入 hermes CLI 路径、WorkingDirectory、HERMES_HOME）
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.matrix-bot.plist
```

登录凭据从 `$HERMES_HOME/.env` 读取（不要把机密写进 plist）。验证方式就是
在 Element X 里给机器人发一条私信——按大脑速度大约 15 秒内回复。

---

## 7. 运维

### 看护（watchdog）

每 5 分钟运行 `scripts/matrix-watchdog.sh`，它只修复断掉的那一环：

```
tailscaled → colima/Docker → 容器 → 127.0.0.1:8008 → tailscale serve → 机器人进程
```

- 同一环节最多 10 分钟修一次。连续 3 次修复失败就停止尝试、只发警报
  （把通知脚本传给 `ALERT_HOOK`）。
- 停止：`touch .watchdog-stop` / 试运行：`WD_DRY=1 ./matrix-watchdog.sh`

### 备份

`scripts/standby-backup.sh` — 每天一次把 DB 同步到另一台机器。

- **热备方式（macOS）**：从 APFS 本地快照 rsync ＝ 服务器不停机。RocksDB
  能从快照得到时点一致的副本。
- **冷备方式（回退）**：`docker stop → rsync → docker start`（约 30 秒停机；
  trap 保证恢复）。Linux 用冷备或 rocksdb checkpoint。

### 常见故障

| 症状 | 检查位置 |
|---|---|
| 只有手机连不上 | tailnet ACL 的 `tcp:443` 许可 |
| 机器人沉默（进程还在） | gateway.log 的 `stopping sync` / `No adapter` 标记 → 重启 |
| 只有通知不来 | 容器的外发 DNS（`colima --dns`）与 push gateway 可达性 |
| `/_matrix` 返回 502 | serve status 里路径是否丢失 → 重跑 `serve-paths.sh` |

---

## 8. 通知与隐私（实测）

- **iOS 的 Element X 通知**经 Element 运营的 push gateway（Sygnal，位于
  `matrix.org`）→ Apple APNs 到达。自建 Sygnal 需要自编译应用加 APNs 密钥，
  **App Store 版 Element X 做不到**。所以要 iOS 通知，就得接受通知元数据
  走 Apple/Element 的路径（即使正文加密，"有东西到了"这一事实也会经过）。
- **明文房间的推送载荷里带正文。** E2EE 房间的推送载荷只有 room_id 和
  event_id（解密前无正文），而明文房间的房间名、发送者、正文会原样流向
  APNs。**敏感房间要么开 E2EE，要么关通知。** 本方案的机器人以明文为前提，
  请注意通知里流出去的内容。
- Android 的 Element X 可选 UnifiedPush（自建 ntfy 等），以 Android 为主的
  话连通知都能完全自托管（iOS 受上述限制）。
- **实测通知是否可达**：Element X → 设置 → 通知 → Troubleshooting 里执行
  **Test Push Gateway** / **Test Push Loop Back**，再看 **Push History**。
  不通时按此顺序排查：① 容器外发 DNS/HTTPS（`colima --dns 1.1.1.1`）
  ② 通知设置里"Enable notifications on this device"先关再开（绕过"登出再
  登录后 pusher 不重新注册"的已知 bug）③ 手机 MagicDNS ④ 私人中继/VPN。
- **通知是两段式**（push gateway 响铃 → Element X 从家服务器取正文）。第二段
  走 Tailscale，所以 Tailscale 挂了会出现只响铃没正文或延迟。

---

## 9. 坑（实测总结）

1. **server_name 永久**。改了所有 ID、房间、历史全部失效。
2. **E2EE 会弄死机器人**——仅指 macOS 中枢。在 Linux 主机上，机器人侧的加密
   库（mautrix 的 Olm/Megolm）可以原生运行，加密房间的机器人在那里是可行的
   （有社区案例·见 Credits）。房间一旦有 `m.room.encryption`，macOS 的机器人
   什么都读不到。用明文房间。
3. **同一 server_name 的服务器绝不能两台同时跑**（split brain＝同一账号写进
   两个数据库，历史永远对不上）。有备用机时，一定先停一台再开另一台。
4. **Conduit v0.10.15 忽略 `well_known_client`。** discovery 的正本是你输入
   的主机名的 `/.well-known`（步骤 2）。Conduit 自己的 `8008/.well-known`
   即使返回旧名字也没人看。
5. **登录响应里没有 `well_known`。** 客户端继续用你输入的 URL，所以 URL 打错
   会在登录时立刻暴露。
6. **tailnet ACL。** 新 serve 的端口在策略放行手机的 `tcp:443` 之前会超时。
   服务器上的 curl 有假阴性，请从别的设备确认。
7. **tailscale serve 条目可能因竞态消失。** 每次改动后用 `serve status` 确认，
   丢了就补（watchdog 会做这件事）。
8. **容器 DNS。** colima 默认配置可能让外发解析坏掉，结果是只有通知静默失效
   （连不上 push gateway）。推荐 `--dns 1.1.1.1`。
9. **不能在 Element X 里创建账号。** 用 API＋注册令牌（步骤 4）。
10. **M_UNRECOGNIZED** 多为客户端 API 版本（`v3`）与服务端实现的差异。
    Conduit v0.10.15 支持 v3 端点。
11. **二维码登录和通话都不可用。** 二维码登录（MSC4108）需要 MAS；通话
    （Element Call）需要另行搭建 LiveKit SFU。加 coturn（TURN）也修不好
    Element X 的通话。
12. **收藏（标签）和全文搜索在 Conduit 上会被静默丢弃/不支持。** 也有新房间
    邀请不显示（sliding sync 系）和 Element X 同步要几分钟才追上的报告。
    实用上先打开一次房间就会出来。
13. **媒体无法清理**（也不支持 S3）＝DB 与媒体只增不减。请做磁盘监控。
    提高 `max_request_size`（默认 20MB）后，客户端要重启才生效。
14. **注册令牌是单个静态值**（只是 config 里的一项）。需要多个带期限的令牌
    就考虑分支版本（比如 Continuwuity 的 admin room 令牌）。
15. **"明明读了，未读角标却不清零"是上游 Conduit 的已知未修 bug。**
    Element X 通过 sliding sync 的已读回执扩展（MSC3960）学习已读状态，但
    Conduit v0.10.15 对该扩展永远返回空（源码确认：`sync.rs` 里
    `receipts.rooms` / `typing.rooms` 被硬编码为空）。已读请求本身在服务器
    端正常保存，数据没有丢。应急办法是清 Element X 缓存（设置 → 连点版本号
    7 次 → 开发者菜单 → Clear cache）。**但清缓存只是权宜之计**——在参考
    服务器上几小时后就复发：一条新消息出现 99+ 角标，清完还剩 30 条。
    **永久解法是把服务器迁移到 Tuwunel**（它实现了已读回执扩展；Conduit DB
    的就地迁移保留账号、房间、历史和登录态；停机约 2 分钟）。经过验证的
    步骤见
    [`docs/migrate-conduit-to-tuwunel.md`](docs/migrate-conduit-to-tuwunel.md)。

---

## 10. 备用机（可选）

每天把 DB 同步到另一台机器，服务器挂掉后几分钟就能恢复聊天（步骤与回迁
步骤：`docs/failover.md`）。备用机平时关机，故障时换上 DB 启动即可。

## 11. 长期视角：Conduit 的开发停滞与分支

Conduit 的开发实际上已放慢为单人项目（无媒体清理、无 S3、功能更新慢）。
社区正在向分支迁移：

- **Tuwunel** — 官方支持从 Conduit 迁移（有实测案例：账号与内容完整保留）
- **Continuwuity** — conduwuit 系的社区分支（有 Conduit 缺少的功能，例如从
  admin room 签发的带期限注册令牌）

现在的配置用着没意见，留在 Conduit 也没问题。真要迁移时，**server_name 和
DB 备份都能直接沿用**（公开的迁移案例全部内容无损），本方案的 tailscale
serve / well-known / 机器人侧应该都不用改。

> 实测备注：我们把 Tuwunel（ghcr.io/matrix-construct/tuwunel）起在同一主机
> 的另一个端口上实测其已读回执扩展——sliding sync 的 `extensions.receipts`
> 正确返回已读数据（Conduit v0.10.15 永远返回空 map）。这次验证之后，我们
> 实际完成了从 Conduit 到 Tuwunel 的迁移——未读角标问题消失，连清缓存的
> 应急手段都不再需要。完整步骤见
> [`docs/migrate-conduit-to-tuwunel.md`](docs/migrate-conduit-to-tuwunel.md)。

---

## Credits

- [Conduit](https://conduit.rs) — Matrix 家服务器（Apache-2.0）。配置规范经
  [官方文档](https://docs.conduit.rs/)与
  [v0.10.15 源码](https://gitlab.com/famedly/conduit)确认
- [Element X](https://element.io) — 客户端应用。参见
  [需求 issue（element-meta#1915）](https://github.com/element-hq/element-meta/issues/1915)与
  [原生 sliding sync 迁移公告](https://matrix.org/blog/2024/11/14/moving-to-native-sliding-sync/)
- [Tailscale](https://tailscale.com) — 网络（serve / ACL）
- [Hermes Agent](https://hermes-agent.nousresearch.com) — 机器人 gateway（Nous Research）
- 社区经验：r/selfhosted 与 Hacker News 的自托管案例、
  [Tailscale × iCloud 私人中继的已知问题](https://github.com/tailscale/tailscale/issues/21677)、
  [Element X iOS 的 pusher 重注册 bug](https://github.com/element-hq/element-x-ios/issues/2602)、
  以及[把 Hermes 机器人从 Signal 迁到 Matrix 的同类案例（Linux 上启用 E2EE）](https://www.reddit.com/r/hermesagent/comments/1towdi5/i_moved_my_hermes_agent_from_signal_to_matrix/)

### Contributors（贡献者）

- **tenhkspark** — 设计、运维、实机验证
- **本地 LLM 群** — 文档审查与翻译审查：
  GLM-5.3-Flash、Qwen3.8-Flash-Next、Nemotron 3.5 Lightning（全部运行在
  自家服务器上）

## License

MIT — 详见 [LICENSE](LICENSE)
