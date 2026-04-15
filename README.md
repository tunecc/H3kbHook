# H3kbHook

`H3kbHook` 是一个 iOS tweak 工程，用于在主 App 与键盘扩展中稳定覆盖 Pro 购买状态。

当前正式发布包会输出为：

- `rootless/com.tune.h3kbhook_1.1.0_iphoneos-arm64.deb`
- `roothide/com.tune.h3kbhook_1.1.0_iphoneos-arm64e.deb`

---

## 项目目标

这个项目的目标不是单纯隐藏 UI 锁态，而是直接命中当前版本的购买状态链，使依赖本地购买状态的 Pro 功能在主 App 与键盘扩展中都能正确工作。

当前实现覆盖了以下关键状态点：

- `com.ihsiao.apps.Hamster3.purchase.state`
- `InAppPurchaseStore.purchasedState`
- `InAppPurchaseStore.ownedConsumables`
- `ReduxInAppPurchaseUserInteractions.purchasedState`

---

## 当前状态

- 开发与测试基线：`h3kb 1.6.12`
- 覆盖对象：
  - 主 App：`h3kb`
  - 键盘扩展：`h3kb_plugin`
- 当前发布版本：`1.1.0`
- 包标识：`com.tune.h3kbhook`
- 支持打包方案：
  - `rootless`
  - `roothide`

当前版本已经完成：

- 启动稳定
- 主 App 与扩展双链覆盖
- Pro 状态解锁
- 去除额外日志开销
- hook 安装前签名校验
- runtime ivar offset 动态解析
- Swift 符号优先定位 getter / ownedConsumables / 交互 getter
- setter 的 getter 邻域局部签名扫描
- 失配时 fail-safe 跳过

---

## 实现概览

这个工程最终采用的是“状态源优先”的方案，而不是继续沿旧版页面链硬迁移。

核心思路：

1. 先强制持久化购买状态
2. 再覆盖运行时 store 层的 `purchasedState`
3. 对 `ownedConsumables` 直接返回真实的 `purchaseIDs` bridge object
4. 同时覆盖主 App 与键盘扩展，避免出现“设置页已解锁但实际功能仍锁住”的情况

当前版本没有继续伪造 Swift `Set<String>` 底层对象，而是优先复用运行时里已经存在的真实 bridge object，以降低 Swift ABI 风险。

---

## 构建

### 环境

- Theos
- rootless / roothide 打包环境
- iOS SDK 16.0

### 构建命令

```bash
make package
```

```bash
make clean package THEOS_PACKAGE_SCHEME=rootless
make clean package THEOS_PACKAGE_SCHEME=roothide
```

### 主要文件

- `Tweak.xm`：核心实现
- `Makefile`：Theos 构建配置
- `control`：Debian 包元数据
- `H3kbHook.plist`：注入配置

---

## 输出产物

构建完成后，发布包输出在：

```bash
rootless/com.tune.h3kbhook_1.1.0_iphoneos-arm64.deb
roothide/com.tune.h3kbhook_1.1.0_iphoneos-arm64e.deb
```

目录中也可能保留若干历史调试包，当前推荐使用正式版 `1.1.0`。

---

## 已知边界

当前实现是基于现有状态链分析得到的定向适配结果，并已在 `h3kb 1.6.12` 上完成开发与静态验证。

如果后续版本发生以下变化，需要重新逆向确认：

- `purchase.state` 持久化链变化
- `purchasedState` 偏移变化
- `purchaseIDs` / `ownedConsumables` 消费链变化
- 主 App / 扩展任一侧的符号布局变化
- setter 的局部邻域结构变化

但从 `1.6.12` 开始，当前实现已经升级为：

- 运行时 ivar offset 动态解析
- 符号优先，版本地址兜底
- setter 邻域锚定扫描

因此后续小版本如果只是函数整体漂移，不一定需要整套重逆。

因此，这个项目不承诺跨版本直接通用。

---

## 免责声明

本项目仅供学习、研究与技术交流使用。

- 本项目与原软件作者、原开发团队及相关品牌无任何隶属、合作或官方认可关系。
- 本仓库不提供原应用二进制、账号、订阅服务、付费资源或任何官方素材授权。
- 使用者应自行确认其使用行为符合所在地法律法规，以及目标软件的许可协议与服务条款。
- 如权利人认为本仓库内容存在侵权或不当之处，请联系处理；仓库维护者会在核实后及时调整或移除相关内容。

上述说明旨在明确项目用途与边界，减少误解；但其本身不构成授权，也不当然免除任何法律责任。

---

## 致谢

感谢 `HamsterHook` 提供的旧版样例与逆向思路参考。  
本项目在方法论上受到启发，但当前实现已重新分析并独立完成。
