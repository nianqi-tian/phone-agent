# iOS 18 移植说明

最低系统改为 iOS 18.0，面向 iPhone XR。iOS 26/27 仍走原来的新 API。

## iOS 18 上可用

- 操控手机、助手对话、BLE 鼠标键盘、校准、任务队列、Live Activity
- 整屏捕获：ReplayKit 广播上传扩展，经本机回环 TCP 把 JPEG 帧送给 App
- 语音听写：`SFSpeechRecognizer` 本机识别（iOS 26+ 仍优先 SpeechAnalyzer）
- 文件音频转写：同样回退到 `SFSpeechRecognizer`
- 动作画中画：用 `AVSampleBufferDisplayLayer.enqueue` 更新画面

## 被降级或隐藏

- Liquid Glass：iOS 26 以下改用 material / bordered 按钮，功能保留
- SpeechAnalyzer 实时转写：iOS 26 以下用旧版听写
- AlarmKit 闹钟：iOS 26 以下工具会提示需要更新系统
- App Intents 的 modes / execution targets：旧系统用默认前台行为
- 屏幕捕获：iOS 27 以下不用 SCStream，改用整屏广播

## 整屏广播怎么用

1. 打开「共享手机画面」。
2. 点「开始整屏广播」（系统红点按钮叠在上面）。
3. 在系统界面选择开始直播。状态栏出现红点后，App 会显示整屏画面。
4. 结束时在 App 点停止，或从状态栏关掉直播。

广播扩展 bundle id：`com.benbenqi.phoneagent.broadcast`。App 在 `127.0.0.1:18765` 收帧，无 App Group。
