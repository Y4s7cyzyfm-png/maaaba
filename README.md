# Maaaba

基于 [Rein](https://github.com/Y4s7cyzyfm-png/Rein) 架构的跨进程游戏功能工具（DarkSword 内核读写 + SpringBoard RemoteCall），针对 Smoba（王者荣耀）重构，**新写工程、非 Rein 改包**。

## 功能

单 Tab 界面，四个按钮：

| # | 按钮 | 作用 |
|---|------|------|
| ① | 初始化 DarkSword 内核 | 网络预热 + kernelcache 下载解析 + `ds_run()` 内核读写就绪 |
| ② | 初始化 RemoteCall | 经内核 attach SpringBoard，建立远程调用会话 |
| ③ | 读取游戏进程 | 内核 proc 链查找 Smoba 客户端进程（缓存 pid） |
| ④ | 开启功能 / 停止功能 | 一键应用两个子功能；再按一次全部回滚 |

### 子功能（按钮④内）

- **全图内透**：Smoba dump（RVA `0x25122A4` = `FogOfWar.set_enable(bool)`）入口写 ARM64 `RET`，迷雾系统初始化即空操作，小地图/主画面迷雾不再生成。运行期监控补丁位，被覆盖自动重打。
- **自定义视距**：移植 Smoba 原码 JRMemoryEngine 流程到内核跨进程——游戏映像窗口扫 `float 1.2` → 邻近 `±0x100` 找 `uint32 257` 标记过滤 → 二次复核 → 全部改写为倍率值（默认 2.0，`NSUserDefaults` 键 `maaaba.zoom.multiplier`）。改写地址带原值备份，停止时回滚。

## 跨进程读写

- **数据段**：`vmmapremotepage`（vm_object 共享映射，本地映射 `VM_PROT_READ|VM_PROT_WRITE` 与游戏物理页直通），512 项页缓存 + 256 项负缓存。
- **代码段**：同一共享页机制写穿；失败自动回退 RemoteCall 重试。
- **退出安全**：补丁全量回滚（内透恢复原始指令、视距恢复原值）后才收尾；退后台按保活状态决定保持或拆除会话（防 SpringBoard 崩溃），逻辑与 Rein 一致。

## 构建

Codemagic（`codemagic.yaml`，借鉴 Rein）：`mac_mini_m2` + Xcode latest，`arm64e` 单架构 unsigned 构建，`ldid` 伪签主二进制与嵌入 dylib（libxpf / libgrabkernel2），产出 `Maaaba.tipa` / `Maaaba.ipa`。

推送任意分支即触发。

## 结构

```
Maaaba/
├── Maaaba.xcodeproj/
├── codemagic.yaml
├── sources/            # UI（单页 RootViewController + MD3 组件）
├── darksword/          # MaaabaBridge（内核/RemoteCall）、SmobaFeatures（跨进程功能）
├── Resources/          # Info.plist、Assets（AppIcon 沿用 Rein）
├── supports/           # entitlements-maaaba.plist
└── Vendor/             # DarkSword 内核利用 + TaskRop + dylib（自 Rein 移植，未改动）
```

## 免责声明

仅供学习研究 ARM64 / XNU 内存管理与 iOS 内核安全机制。勿用于任何联网对局或他人设备。
