# TrollStore 安装指南（FM影媒）

## 一、前提

| 项目 | 要求 |
| --- | --- |
| 设备 | 已能安装并运行 TrollStore（巨魔） |
| 系统 | iOS 15.4 – 16.6.1 或 17.0（TrollStore 支持范围 ∩ App 最低系统） |
| 账号 | 不需要 Apple 开发者账号、不需要 App Store |
| 签名 | 不需要 —— 本项目产出的是**未签名 IPA**，TrollStore 安装时自行 ldid 签名 |

> 如果你的系统低于 15.4，App 无法安装。iOS 15.x 上会自动退化为 `NavigationView` 等兼容实现。

## 二、下载

手机浏览器直接打开：

```
https://github.com/Fourth-Master/fm-media/releases/latest/download/FMMedia.ipa
```

这是「最新版本」的固定地址，以后每次发版都会自动指向新 IPA。

也可以从 <https://github.com/Fourth-Master/fm-media/releases> 手动选择某个版本下载，
或者进入 Actions 某次运行页面，在 Artifacts 里下载 `FM-Media-ipa`（需要登录 GitHub）。

## 三、安装

### 方式 A：从「文件」App

1. 下载完成后，打开系统「文件」App →「下载」；
2. 长按 `FMMedia.ipa` → 共享 → 选择 **TrollStore**；
3. TrollStore 自动导入并安装，桌面出现「FM影媒」。

### 方式 B：从 TrollStore

1. 打开 TrollStore，点右上角 `+`；
2. 选择「文件」中的 `FMMedia.ipa`；
3. 等待安装完成（几秒）。

### 方式 C：AirDrop / 局域网传文件

用 AirDrop、Feishu/微信文件传输助手把 IPA 存到「文件」App 后，按方式 A 操作即可。

## 四、升级

下载新 IPA 后重复安装即可覆盖旧版本，**媒体库与设置会保留**
（数据位于 App 沙盒，Bundle ID 不变 `com.fmmedia.fmplayer`）。

## 五、首次使用

1. 打开 App →「文件」→ 右上角 `+` → 选「本机目录」，授权一个按番号命名的文件夹；
2. 保存后会自动扫描，首页/媒体库出现影片；
3. 想连接 Emby / Jellyfin / WebDAV / 云盘，同样在「添加来源」里选择对应类型；
4. 播放时右上角可搜索字幕、调整字幕样式与时间轴。

## 六、常见问题

**Q：安装时提示「无法验证应用」？**
说明没走 TrollStore，而是系统直接安装。请从「文件」App 选择用 TrollStore 打开。

**Q：桌面图标是白图标 / 名字不对？**
确认下载的是 `FMMedia.ipa`（约 1.5 MB）。旧版本缓存可先删除再装。

**Q：本地目录读取失败？**
iOS 沙盒限制：必须通过 App 内的文件夹选择器授权目录，不能用 TrollStore 的「任意路径访问」代替。
如果之前授权的目录被移动/删除，请重新在「设置 → 来源」移除后再添加。

**Q：没有 TrollStore 怎么办？**
本项目同时支持 Xcode 真机调试；也可以自行用 AltStore / Sideloadly 签名安装（需要 Apple ID，7 天续签）。
