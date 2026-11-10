# SysBar

极轻量 macOS 菜单栏系统状态：内存、CPU、网速、磁盘、运行时间、电池。

- **无 Dock**（`LSUIElement`）
- 菜单栏单图标，点击展开面板
- 点击打开面板时按需采样，打开后不再每 2 秒刷新系统指标；关闭时不采样
- 保留时钟走秒和开合动画；清理内存或清空废纸篓后会更新操作结果
- 纯 AppKit，无 WebKit
- macOS 26 及以上使用玻璃面板：20pt 圆角与外层裁切保持一致，底部留白收紧，避免角落残边。

```bash
./build.sh
cp -R build/SysBar.app ~/Applications/
open ~/Applications/SysBar.app
```

右键图标可退出。
