## 关于 AnySend

AnySend 基于开源项目 [LocalSend](https://localsend.org) 二次开发（Apache-2.0）。
本页只记录 AnySend 自身的改动；LocalSend 上游的更新历史请见上游仓库。

## 目前新增

- 应用名与界面文案统一为 AnySend，关于页保留 LocalSend 上游署名
- 内置开源 Tailscale 后台服务（tailscaled），macOS 以真实节点加入 tailnet，任意端口 / ICMP / UDP 全局可达
- Tailscale 节点名自动跟随「设备名称」，中文设备名自动转为拼音
- 继续兼容 LocalSend 官方局域网传输协议
