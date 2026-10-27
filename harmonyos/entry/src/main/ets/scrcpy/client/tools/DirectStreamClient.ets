// Direct LAN stream client (阶段一：Shizuku 镜像桥).
//
// Unlike NativeStreamClient this opens no adb session at all: the Android side
// already runs scrcpy-server through its Shizuku UserService (shell UID 2000)
// and exposes the server's two abstract sockets as plain TCP ports, so we only
// hand host/videoPort/controlPort to the native direct-mode starter.
//
// Touch injection stays in C++ (XComponent callbacks). The only control
// message this class sends itself is the initial screen-wake key.

import { NativeStreamListener } from './NativeStreamClient';
import { ControlPacket } from './ControlPacket';
import * as libscrcpy from 'libscrcpy_native.so';
import { LoggerClientStream } from '../../helper/Logger';

type NativeEventCallback = (type: string, data: string) => void;

export class DirectStreamClient {
  private listener?: NativeStreamListener;
  private stopped: boolean = false;
  private sessionId: number = 0;

  constructor(listener?: NativeStreamListener) {
    this.listener = listener;
  }

  // Connect to the bridge-exported video/control ports and start decoding.
  // The native side connects video first, then control, matching the
  // scrcpy-server accept order.
  //
  // `startApp` non-empty switches the session to virtual-display mode: the
  // Android side runs scrcpy-server with `new_display`, and we push a
  // TYPE_START_APP control message so that app is launched on the new virtual
  // display — the phone's own screen keeps showing whatever the user is doing.
  async start(
    host: string,
    videoPort: number,
    controlPort: number,
    surfaceId: string,
    videoFrameRate: number,
    startApp: string = '',
    pin: string = '',
    nativeTouch: boolean = true
  ): Promise<void> {
    this.stopped = false;
    const session = ++this.sessionId;
    if (host.length === 0 || videoPort <= 0 || controlPort <= 0) {
      throw new Error('镜像桥地址无效（请确认安卓端已准备镜像）');
    }
    if (surfaceId.length === 0) {
      throw new Error('渲染表面未就绪');
    }

    const result: number = await libscrcpy.nativeStartDirectStreams(
      host,
      videoPort,
      controlPort,
      surfaceId,
      48000,
      2,
      this.createNativeEventCallback(),
      videoFrameRate,
      pin
    );
    if (session !== this.sessionId) {
      libscrcpy.nativeStopStreams();
      return;
    }
    if (result !== 0) {
      throw new Error(DirectStreamClient.describeStartFailure(result));
    }
    // Must be set after a successful start: the native starter resets its
    // device state, and the Mac page injects hover/right-click/scroll itself.
    libscrcpy.nativeSetNativeTouchForwarding(nativeTouch);
    if (startApp.length > 0) {
      this.startAppOnVirtualDisplay(startApp);
    } else if (nativeTouch) {
      // A Mac host is not an Android screen; the wake key is meaningless there.
      this.wakeUpDevice();
    }
  }

  /**
   * 把目标 app 启动到安卓端新建的虚拟显示上。
   *
   * 服务端只认这条 START_APP 控制消息（launch options 里没有对应参数），
   * 落到虚拟显示后手机自己的屏幕不显示该 app。
   * 虚拟显示模式下**不能**再发唤醒键，那会点亮用户自己的手机屏幕。
   */
  private startAppOnVirtualDisplay(packageName: string): void {
    try {
      const packet = ControlPacket.createStartApp(packageName);
      if (packet === null) {
        LoggerClientStream.error('[DirectStreamClient] 非法包名，未启动:', packageName);
        return;
      }
      libscrcpy.nativeSendControl(packet);
    } catch (e) {
      LoggerClientStream.error('[DirectStreamClient] startApp failed:', e);
    }
  }

  /**
   * 发送任意一条控制消息。
   *
   * 触摸由 C++ 层自己处理，但键盘、滚动、剪贴板等由页面生成 —— 尤其是远控
   * Mac 时，页面要用这块区域当触控板/虚拟键盘，必须能自己拼包。
   */
  sendControlPacket(packet: ArrayBuffer): boolean {
    if (this.stopped) {
      return false;
    }
    try {
      return libscrcpy.nativeSendControl(packet);
    } catch (e) {
      LoggerClientStream.error('[DirectStreamClient] sendControlPacket failed:', e);
      return false;
    }
  }

  /**
   * 向安卓端注入一次返回键（对应页面上悬浮球的单击）。
   *
   * 走 TYPE_BACK_OR_SCREEN_ON：服务端把它当作返回键的按键动作处理，效果等同
   * 按安卓的返回键，作用在画面上当前显示的那个 app 上。
   * createBackKey 返回 DOWN + UP 一对消息 —— 按键必须成对，只发 DOWN 不生效。
   */
  sendBackKey(): void {
    try {
      for (const packet of ControlPacket.createBackKey()) {
        libscrcpy.nativeSendControl(packet);
      }
    } catch (e) {
      LoggerClientStream.error('[DirectStreamClient] sendBackKey failed:', e);
    }
  }

  /**
   * 点亮安卓屏幕。
   *
   * 息屏状态下系统会把屏幕内容整块熄灭，镜像抓到的是纯黑（锁屏解锁页也看不到）。
   * 用一条 KEYCODE_WAKEUP 键对走输入注入唤醒屏幕，等同按了一下电源键；
   * 屏幕本来就亮着时该按键无副作用。
   */
  private wakeUpDevice(): void {
    try {
      for (const packet of ControlPacket.createWakeUpKey()) {
        libscrcpy.nativeSendControl(packet);
      }
    } catch (e) {
      LoggerClientStream.error('[DirectStreamClient] wakeUpDevice failed:', e);
    }
  }

  stop(): void {
    this.stopped = true;
    this.sessionId++;
    void this.stopNative();
  }

  private async stopNative(): Promise<void> {
    libscrcpy.nativeSetNativeTouchForwarding(true);
    try {
      await libscrcpy.nativeStopStreamsAsync();
    } catch (e) {
      LoggerClientStream.error('[DirectStreamClient] nativeStopStreamsAsync failed:', e);
    }
  }

  private createNativeEventCallback(): NativeEventCallback {
    return (type: string, data: string): void => {
      if (this.stopped) {
        return;
      }
      if (!this.listener) {
        return;
      }
      switch (type) {
        case 'video_config':
        case 'video_size_changed':
          try {
            interface VideoConfig { width: number; height: number; }
            const config = JSON.parse(data) as VideoConfig;
            this.listener.onVideoConfig(config.width, config.height);
          } catch (e) {
            LoggerClientStream.error('[DirectStreamClient] Parse video config failed:', JSON.stringify(e));
          }
          break;
        case 'first_frame':
          if (this.listener.onFirstFrame) {
            this.listener.onFirstFrame();
          }
          break;
        case 'clipboard':
          this.listener.onClipboard(data);
          break;
        case 'disconnected':
          this.listener.onDisconnect('Server Disconnected');
          break;
        case 'error':
          this.listener.onError(data);
          break;
      }
    };
  }

  private static describeStartFailure(code: number): string {
    if (code === -3) {
      return '视频组件未注册，请返回后重新进入镜像页。';
    }
    if (code === -10) {
      return '镜像桥地址不完整，请重新开始镜像。';
    }
    if (code === -11) {
      return '无法连接安卓端视频端口，请确认本机已加入安卓热点。';
    }
    if (code === -12) {
      return '无法连接安卓端控制端口，请确认安卓端镜像服务仍在运行。';
    }
    return `原生直连启动失败（错误码 ${code}）`;
  }
}
