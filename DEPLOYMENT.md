# EasyControl HarmonyOS版本 部署指南

## 前置准备

### 1. Android设备准备
- 开启ADB调试
- 连接到与HarmonyOS设备同一网络
- 开启无线ADB（可选但推荐）

### 2. 推送服务端到Android设备

```bash
# 进入easycontrol server目录
cd easycontrol/server

# 构建服务端jar
./gradlew assembleRelease

# 推送到Android设备
adb push build/outputs/apk/release/server.jar /data/local/tmp/easycontrol-server.jar

# 设置权限
adb shell chmod 755 /data/local/tmp/easycontrol-server.jar
```

### 3. 开启Android无线ADB（推荐）

```bash
# 通过USB连接后执行
adb tcpip 5555

# 获取Android设备IP（在设备上查看WiFi设置）
# 例如: 192.168.1.100

# 断开USB，通过网络连接
adb connect 192.168.1.100:5555
```

## 使用步骤

### 1. 启动HarmonyOS应用

- 安装并启动应用
- 首次启动会初始化数据库

### 2. 添加设备

- 点击"添加设备"按钮
- 填写设备信息:
  - **设备名称**: 自定义名称
  - **地址**: Android设备IP (如: 192.168.1.100)
  - **ADB端口**: 默认5555
  - **服务端口**: 默认12580
- 配置高级选项（可选）
- 点击"确认"保存

### 3. 连接设备

- 在设备列表中点击"连接"按钮
- 等待连接建立（首次连接可能需要授权ADB）
- 连接成功后自动跳转到控制页面

### 4. 控制操作

#### 触摸控制
- **单指点击**: 模拟触摸点击
- **拖动**: 模拟滑动操作
- **多指触控**: 支持多点触摸

#### 按键操作
- **主页**: 返回主屏幕
- **返回键**: 返回上一页
- **屏幕开/关**: 控制屏幕电源
- **旋转**: 旋转屏幕方向

## 配置说明

### 设备配置项

| 配置项 | 说明 | 默认值 |
|--------|------|--------|
| 启用音频 | 传输设备音频 | 是 |
| 使用H265 | H265视频编码 | 是 |
| 最大分辨率 | 视频最大宽度 | 1920 |
| 最大帧率 | 视频帧率限制 | 60 |
| 最大码率 | 视频码率(Mbps) | 4 |

### 网络要求

- **局域网连接**: 推荐在同一WiFi下使用
- **带宽**: 建议5Mbps以上
- **延迟**: <50ms获得最佳体验

## 故障排除

### 连接失败

1. 检查网络连接
   - 确保两设备在同一网络
   - ping测试连通性

2. 检查ADB状态
   ```bash
   adb devices
   ```

3. 检查服务端jar
   ```bash
   adb shell ls -l /data/local/tmp/easycontrol-server.jar
   ```

### 画面卡顿

- 降低分辨率设置
- 降低帧率
- 关闭H265（某些设备兼容性问题）
- 检查网络带宽

### 音频无声

- 确认Android版本>=12
- 检查设备音频设置
- 重新连接设备

## 开发说明

### 项目结构

```
app/src/main/ets/
├── adb/              # ADB协议实现
│   ├── Adb.ets
│   └── TcpChannel.ets
├── client/           # 客户端核心
│   ├── Client.ets
│   ├── ClientStream.ets
│   ├── VideoDecoder.ets
│   ├── AudioDecoder.ets
│   └── ControlPacket.ets
├── entity/           # 数据实体
│   └── Device.ets
├── helper/           # 工具类
│   └── PreferencesHelper.ets
└── pages/            # 页面
    ├── Index.ets
    ├── DeviceDetail.ets
    └── ControlPage.ets
```

### 核心功能模块

1. **ADB连接**: TCP协议实现ADB通信
2. **视频解码**: H264/H265硬解码
3. **音频解码**: AAC/Opus解码播放
4. **触摸控制**: 多点触摸事件转发
5. **剪贴板**: 双向同步

## 注意事项

⚠️ **重要提示**:
- 服务端jar需从Android版本构建
- 首次连接需授权ADB
- 某些厂商ROM可能限制后台服务
- 建议在开发者选项中关闭"仅充电模式"限制

## 兼容性

- **HarmonyOS**: API 9+
- **Android被控端**: Android 5.0+
- **推荐**: Android 12+ (完整音频支持)
