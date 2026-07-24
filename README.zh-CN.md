# Strike Protocol 激战协议

一个使用 **Godot 4** 引擎开发的 2D 俯视角射击竞技游戏，搭配 Python 编写的服务端。

## 游戏特点

- **多人对战**：支持局域网内多人实时对战
- **训练模式**：无需服务器，离线即可练习
- **跨平台**：支持 Windows、Linux、macOS、Android、iOS
- **双摇杆操作**：支持键盘鼠标和触屏操作
- **TCP协议**：使用原生TCP连接，数据同步稳定

## 快速开始

### 启动服务端

```bash
python -m strike_protocol.server.server --host 0.0.0.0 --port 8765
```

Windows 用户可以直接运行 `run_server.cmd` 或 `run_server.ps1`

### 启动客户端

1. 使用 Godot 4.3 或更高版本打开项目：`client/project.godot`
2. 按 **F5** 运行游戏
3. 输入服务器地址连接（同机测试用 `127.0.0.1:8765`）

### 直接运行（已安装 Godot）

```bash
godot --path client
```

## 操作说明

| 平台 | 移动 | 瞄准/射击 | 其他 |
|------|------|----------|------|
| 电脑 | WASD / 方向键 | 鼠标控制方向，左键射击 | R 换弹，Esc 返回菜单 |
| 手机 | 左摇杆移动 | 右摇杆瞄准，超出死区自动开火 | 屏幕按钮操作 |

## 已打包版本

| 平台 | 文件 | 大小 |
|------|------|------|
| Windows | `builds/StrikeProtocol.exe` | ~104 MB |
| Android | `builds/StrikeProtocol-debug.apk` | ~27 MB |

## 游戏玩法

- 击杀敌人获得分数
- 死亡后自动重生，弹药重置
- 每局游戏时长 10 分钟
- 支持最多 8 人同时在线对战

## 技术架构

```
客户端 (Godot 4)
    │
    ├── TCP 连接 (NDJSON协议)
    │
    └── 服务端 (Python 3.10+)
```

### 项目结构

```
strike_protocol/
├── client/           # Godot 客户端
│   ├── project.godot
│   ├── main.tscn
│   ├── scripts/
│   └── assets/
├── server/           # Python 服务端
│   ├── server.py
│   └── test_server.py
├── protocol.md       # 协议文档
└── README.md         # 说明文档
```

## 开发说明

### 服务端测试

```bash
python -m strike_protocol.server.test_server
```

### 构建导出

详见 [构建与网络文档](docs/BUILD_AND_NETWORK.md)

## 许可证

本项目使用 CC0 协议的占位美术资源，可替换为 Kenney 等免费资源包。

## 相关链接

- [协议文档](protocol.md)
- [构建指南](docs/BUILD_AND_NETWORK.md)
- [资源版权说明](client/assets/ATTRIBUTION.md)
