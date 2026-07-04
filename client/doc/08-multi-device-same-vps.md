# 模块 8：同一 VPS 多设备/多客户端隔离验证与文档

不是新代码，是给已经存在的能力补一次真实端到端验证 + 文档。这条路径（"一台 VPS 给多台设备当备份目标"）在 VPS 一键脚本里从一开始就是默认分支（`setup-backup-server-hardened.sh` 检测到已有安装时，菜单第一项、也是默认项就是"仅新增一个备份凭据"），但此前从没被专门测试或写文档确认过。

## 背景：为什么这条路径"顺便"就有了

两个已经各自独立实现的能力叠加起来，就是这里说的"M×N 矩阵"：

- **一台设备 → 多台 VPS**（模块 3 起就有）：`config/targets/<name>.env` 每个目标一个文件，`backupctl run` 遍历所有启用的 target，各自独立地把同一份数据全量备份过去（copy 模式，无 RAID/纠删码，纯独立副本）
- **一台 VPS → 多台设备**（VPS 脚本"仅新增凭据"分支）：`rest-server --private-repos` 按 URL 路径的用户名分隔仓库，脚本检测到服务已安装时默认走这条分支——不重装、不换证书、只是往 `.htpasswd` 里加一个新用户然后 `systemctl restart`

两者结合起来是一个"扇形"（fan）结构：每个 设备-VPS 连接彼此独立，VPS 之间不通信、不同步，不存在"矩阵"字面意义上的网状协调。真要做"多后端分布式协调"（比如某个 VPS 挂了自动切换、或者跨 VPS 去重）是完全不同量级的工程，本模块不做，仅确认现有扇形结构本身是可靠、隔离的。

## 验证目标

1. 往一台已经在服务中的 rest-server 实例新增第二个用户（模拟"给第二台设备开通"），确认这个操作（含随之而来的 `systemctl restart`）不会影响第一个用户已有的仓库
2. 确认两个用户的仓库数据、认证是完全隔离的——跨用户的密码/路径访问应该被服务器拒绝
3. 明确这种隔离的性质：是 rest-server 应用层的鉴权+路由保证，不是操作系统层面的文件权限隔离

## 测试过程与结果（2026-07-04，真实测试 VPS）

用真实 VPS 上一个临时的 rest-server 实例（端口 9196，测试完毕已完全清理）模拟两台设备 `deviceA`、`deviceB` 共用同一台 VPS：

1. **首次安装**：跑一遍 `setup-backup-server-hardened.sh`，全新安装，用户名 `deviceA`
2. **`deviceA` 端到端跑通**：`backupctl target add` 粘贴凭据 → `restic init` 成功 → 新建测试目录 `/tmp/backup-devA-dir` → `backupctl run --target deviceA --force` 两次，均成功产生快照并完成 `forget --prune`
3. **新增第二个用户**：在同一台 VPS 上重新运行一键脚本，脚本自动检测到已有安装，默认选中"仅新增一个备份凭据"——脚本输出确认：
   - 复用了已有端口（9196，没有重新询问）
   - 没有出现证书生成的交互菜单（复用了已有 TLS 证书）
   - 只是往 `.htpasswd` 追加了 `deviceB` 这一行，然后 `systemctl restart` 重启服务应用新凭据
4. **验证重启没有破坏已有仓库**：新增 `deviceB` 凭据触发的 `systemctl restart` 结束后，立刻针对已经存在的 `deviceA` 目标重新跑一次 `backupctl run --target deviceA --force`——正常完成（备份成功 + `forget --prune` 完成），说明"加一个新用户"这个操作对已有设备的仓库是无损的
5. **`deviceB` 端到端跑通**：`backupctl target add` 粘贴 `deviceB` 的凭据 blob → `restic init` 成功创建独立仓库 → 新建独立测试目录 `/tmp/backup-devB-dir`（内容与 `deviceA` 的测试文件完全不同）→ `backupctl run --target deviceB --force` 成功产生快照
6. **VPS 侧目录结构确认**（SSH 直接查看 `/opt/restic-rest-server/data/`）：
   ```
   drwx------ 7 restic-rest-server restic-rest-server  87 deviceA
   -rw-r----- 1 restic-rest-server restic-rest-server 138 .htpasswd   (内含 deviceA、deviceB 两行)
   ```
   `deviceB` 此时在 `.htpasswd` 里已经注册，但还没有独立的仓库子目录——这是符合预期的：`--private-repos` 模式不会在新增用户时预先建目录，仓库目录是在该用户第一次真正发起仓库操作（`restic init`）时才懒创建的。做完第 5 步之后再看，`deviceB` 子目录才出现
7. **核心：跨认证隔离测试**（用 `curl` 直接打 rest-server 的 HTTP 接口，绕开 restic 客户端，直接验证服务端鉴权逻辑本身）：

   | 请求 | 预期 | 实测结果 |
   |---|---|---|
   | `deviceA` 凭据访问 `/deviceA/config` | 成功 | `HTTP 200` |
   | `deviceA` 凭据访问 `/deviceB/config` | 拒绝 | `HTTP 401` |
   | `deviceB` 凭据访问 `/deviceA/config` | 拒绝 | `HTTP 401` |
   | `deviceB` 凭据访问 `/deviceB/config` | 成功 | `HTTP 200` |
   | 不带任何凭据访问 `/deviceA/config` | 拒绝 | `HTTP 401` |

   五组结果和预期完全一致：`rest-server --private-repos` 确实会校验"认证用户名"和"URL 路径里的用户名段"必须一致，跨用户访问在鉴权这一层就被拒绝，不会走到文件系统层面
8. **`restic snapshots` 按 target 分别查看**：确认 `deviceA`、`deviceB` 各自的仓库只包含各自的仓库密码能解开的快照——两个仓库是完全独立的 restic repo，互相看不到对方的快照列表（这一点其实是 restic repo 本身的性质，只是借这次机会一并确认）

## 隔离的性质：应用层，不是操作系统层

需要明确写清楚的一点：这里验证到的"隔离"是 **rest-server 应用层的鉴权+路由逻辑** 提供的保证，**不是** Unix 文件权限意义上的隔离。VPS 上 `deviceA`、`deviceB` 两个用户的仓库数据，在操作系统层面其实都归属同一个系统账户 `restic-rest-server`（这是脚本在模块 2 里就设计好的单一低权限服务账户，不是每个客户端各自一个系统用户）。也就是说：

- 如果攻击者拿到的是"某个客户端的 restic 凭据"（用户名+密码），rest-server 的鉴权会正确拒绝他访问其他客户端的仓库路径——这一层验证过了，是可靠的
- 但如果攻击者拿到的是 VPS 本身的 root 权限（或者是 `restic-rest-server` 这个系统账户的权限），那么所有客户端的数据对他来说都是同一个身份能直接读到的普通文件，没有额外的操作系统级别隔离
- 这个权衡是合理的：`rest-server --private-repos` 设计的初衷就是"用一个服务进程、一个系统账户，靠应用层路由服务多个客户端"，如果要更强的隔离（比如给每个客户端单独开一个系统用户、单独一个 rest-server 实例、单独端口），可以做，但复杂度和这套单机个人备份场景不成比例——真正需要防的是"笔记本这一端的凭据泄露"，而不是"VPS root 被攻破"，后者不管怎么设计隔离都不构成有效防线

## 已知代价：跨设备无法共享去重

restic 的内容去重只发生在**同一个仓库内部**。`deviceA` 和 `deviceB` 是两个完全独立的仓库（各自独立的仓库密码、独立的 `restic init`），哪怕两台设备背份了完全相同的文件内容，也不会有任何跨仓库的存储去重——这是"多租户按用户名分仓库"这个方案本身固有的代价，换取的是应用层的鉴权隔离。如果两台设备之间的数据重合度很高又特别在意存储空间，那是另一个量级的设计（共享单一仓库、靠路径前缀区分），不在本模块讨论范围内。

## 一个测试环境本身的注意点（非产品问题）

本次为了在同一台物理机（本机）上模拟"两台不同设备"，`deviceA`、`deviceB` 两个 target 用的是同一份本机 `config/paths.conf`——所以 `backupctl run --target deviceA`（不带 `--path`）实际会把 `paths.conf` 里当时登记的全部目录（当时误包含了 `/tmp/backup-devB-dir`）都备份进 `deviceA` 的仓库。这纯粹是"用一台机器模拟两台设备"这个测试方法本身带来的假象，不是 rest-server 隔离出了问题——真实场景里，`deviceA`、`deviceB` 会是两台完全独立的物理机器，各自运行独立的 `backupctl` 安装、各自独立的 `paths.conf`，不会有这种共享配置导致的数据混入。

## 追加验证（2026-07-04，用户追问"A 用户有可能渗透进入 B 的空间吗？"后做的对抗性测试）

前面第 7 步的跨认证测试只证明了"用错密码访问对方路径会 401"，这不足以回答"A 能不能通过某种手段绕过鉴权直接拿到 B 的数据"。`rest-server` 的 `--private-repos` 机制历史上确实出过两次真实的目录穿越漏洞：

- **CVE 修复于 0.10.0**：把 URL 里的 `/` 编码成 `%2F`，rest-server 用的 HTTP 路由框架会先解码再处理，导致 `foo%2F..%2Fbar` 变成实际路径 `foo/../bar`，可以越权访问其他用户的仓库文件
- **CVE 修复于 0.11.0**：注册一个包含 `/` 的用户名（比如 `foo/config`），可以直接访问/删除 `foo` 用户的 `config` 文件

先查证了我们的 VPS 一键脚本装的是什么版本——脚本永远从 GitHub 拉 `releases/latest`（不是钉死某个旧版本号），当前拉到的是 `v0.14.0`（2025-05-31 发布），确认已经远远晚于上面两个漏洞的修复版本。但"看 changelog 说修了"不等于"在我们的部署上真的验证过"，所以又专门起了一个临时测试实例（port 9195，两个真实用户 `deviceA`、`deviceC`，`deviceC` 有真实备份内容 `TOP SECRET device C content`），拿 `deviceA` 的合法凭据尝试了以下每一种手段访问/破坏 `deviceC` 的真实数据：

| 尝试方式 | 结果 | 说明 |
|---|---|---|
| 未编码 `deviceA/../deviceC/config` | `401` | curl 自己先把路径规整化了，等于直接请求 `/deviceC/config`，鉴权直接拒绝 |
| `%2F` 编码穿越（对应 0.10.0 那个 CVE 的手法） | `404`，不是 `deviceC` 的真实内容 | 关键判定点：因为 `deviceC/config` 真实存在（控制组用 `deviceC` 自己的凭据读取同一路径拿到了 200 + 真实密文），如果穿越真的生效，这里应该也拿到同样的 200+密文，而不是 404。证明穿越没有生效 |
| `%252F` 双重编码 | `401` | 同样被当作鉴权失败处理，没有触发任何解码穿越 |
| `curl --path-as-is` 发送真正带字面 `..` 的路径 | 服务端先返回 `301` 重定向到 `/deviceC/config`（Go 标准库 `net/http` 对带 `..` 的路径做规整化重定向），但 `-L` 跟随重定向后最终仍是 `401` | 重定向本身不代表越权成功——客户端跟着重定向重新发起请求时，服务端会用重定向后的真实路径重新做一遍完整鉴权，`deviceA` 的凭据在 `/deviceC/config` 这个路径上依然通不过 |
| 用 `deviceA` 凭据对 `deviceC/config` 直接发 `DELETE`（对应 0.11.0 那个 CVE 想干的"删除别人仓库文件"） | `401` | 破坏性操作同样先过鉴权这一关，未授权直接被拒绝，`deviceC` 的数据全程完好 |
| 手动往 `.htpasswd` 里塞一个真实包含 `/` 的用户名 `deviceA/config`（模拟 0.11.0 那个 CVE 的构造手法），用它的凭据访问/删除 `deviceA/config` | `401`（GET 和 DELETE 均是） | 当前版本正确拒绝了这种畸形用户名的鉴权，即使这个用户名已经被写进了 `.htpasswd` 文件里 |

全部对抗性测试完成后，重新用 `deviceC` 自己的真实凭据确认它的 `config` 依旧能正常读到（`200`），内容没有被前面这些尝试污染或删除。

**结论**：在当前部署版本（v0.14.0）上，跨用户越权读取或破坏对方数据的两条历史已知路径都已被修复，本次额外用真实数据做了对抗性验证，没有找到绕过方法。这个结论只对"当前版本、当前部署方式"成立——一键脚本每次都会去拉最新版本，所以只要脚本本身不被改成钉死某个旧版本号，这个防护会随上游版本更新持续有效；但如果将来脚本改成离线安装某个缓存的旧二进制，就需要重新确认版本号是否还在安全范围内。

另外一个更根本的边界（在前面"隔离的性质"一节已经写过，这里再强调一次）：以上验证的是**应用层鉴权**能不能被绕过，不能替代"VPS root/系统账户层面的隔离"——如果攻击者拿到的是 VPS root 权限或者 `restic-rest-server` 系统账户本身的权限，这些鉴权检查完全不适用，因为攻击者已经不需要通过 HTTP 接口访问文件了。这次测试回答的问题是"一个只知道自己那份 restic 凭据的客户端 A，能不能够到客户端 B 的数据"，答案是"在当前版本上不能"；不是"VPS 本身被攻破后数据还安不安全"这个更大的问题。

## 清理

测试完毕后已完全清理：
- 本机：`backupctl target remove deviceA/deviceB/deviceC-sec`（删除本地凭据/证书/仓库密码配置）、`backupctl path remove` 各测试目录、`rm -rf` 测试目录本身
- VPS：两轮临时实例（端口 9196、9195）均已 `systemctl stop/disable restic-rest-server`、删除 systemd unit 文件并 `daemon-reload`、`rm -rf /opt/restic-rest-server`、`userdel restic-rest-server`、清理 `/root/` 下临时脚本副本，确认端口已释放、服务和用户均已不存在
