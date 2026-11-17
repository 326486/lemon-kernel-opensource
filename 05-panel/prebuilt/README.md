# 预编译面板 APP

lemon-panel.apk 为已编译签名的控制面板 WebView 壳 APP（包名 com.lemon.panel）。

## 安装
1. 先部署并启动面板后端（见 docs/完整版教程.md 第6节），确保 http://127.0.0.1:8794 可访问。
2. 将 lemon-panel.apk 复制到 /data/local/tmp/（SELinux 限制，勿直接从 /data/lemonbrain 安装）：
   cp lemon-panel.apk /data/local/tmp/
3. pm install -r /data/local/tmp/lemon-panel.apk
4. 打开「小柠檬内核」APP 即加载面板。

## 签名说明
本 APK 使用发布示例密钥签名，仅供体验/自用。二次分发或上架请用自己的 keystore 重新签名：
  sh ../build_apk.sh   # 脚本内 keytool 生成你自己的 keystore 后重签
切勿将你的 keystore 私钥提交到公开仓库。

## 注意
- APP 仅访问本机 127.0.0.1:8794，不含任何凭据。
- 需后端在跑；后端未起时 APP 显示加载失败/重试。
