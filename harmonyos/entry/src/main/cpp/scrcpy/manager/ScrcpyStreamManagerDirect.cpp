#include "ScrcpyStreamManager.h"

#include "adb/channel/TcpChannel.h"

#include <hilog/log.h>
#include <stdexcept>
#include <string>
#include <vector>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "StreamManager"
#define LOG_DOMAIN 0x3200

// 直连模式（阶段一：局域网）。
//
// 安卓侧的 Shizuku 镜像桥起了 scrcpy-server，并把它的 abstract socket
// 转成两个 loopback/TCP 端口暴露出来，所以这里不需要任何 adb 会话：
// 直接连 video/control 两个 TCP 端口，把它当成 AdbChannel 交给原有的
// 收流线程即可（createByteStream 优先使用 channel 而非 adb stream）。
//
// 顺序是硬性的：scrcpy-server 先 accept video 再 accept audio/control，
// 桥也按同样顺序配对，所以视频必须先连成功，控制再连。
//
// 返回值（有意避开 napi 层已占用的 -1 / -3）：
//   DIRECT_ERR_BAD_TARGET / DIRECT_ERR_VIDEO / DIRECT_ERR_CONTROL
int32_t ScrcpyStreamManager::startDirect(const std::string& host, uint16_t videoPort, uint16_t controlPort,
                                         const Config& config, StreamEventCallback callback,
                                         const std::string& pin) {
    if (running_.load()) {
        OH_LOG_WARN(LOG_APP, "[StreamManager] Already running, stop first");
        stop();
    }

    adb_ = nullptr;
    config_ = config;
    config_.reverse = false;
    eventCallback_ = callback;
    videoStream_ = nullptr;
    audioStream_ = nullptr;
    controlStream_ = nullptr;

    if (host.empty() || videoPort == 0 || controlPort == 0) {
        OH_LOG_ERROR(LOG_APP, "[StreamManager] Direct start needs host + both ports (host='%{public}s' "
                              "video=%{public}u control=%{public}u)",
                      host.c_str(), videoPort, controlPort);
        adb_ = nullptr;
        return DIRECT_ERR_BAD_TARGET;
    }

    try {
        videoChannel_ = new TcpChannel(host, videoPort);
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "[StreamManager] Direct video connect failed: %{public}s", e.what());
        releaseLocalTunnels();
        adb_ = nullptr;
        return DIRECT_ERR_VIDEO;
    }

    try {
        controlChannel_ = new TcpChannel(host, controlPort);
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "[StreamManager] Direct control connect failed: %{public}s", e.what());
        closeLocalTunnels();
        releaseLocalTunnels();
        adb_ = nullptr;
        return DIRECT_ERR_CONTROL;
    }

    // Mac 被控端在推流/收控制之前要求两条连接各发一段 PIN 前缀
    // （1 字节长度 + UTF-8）。PIN 为空时协议与安卓镜像桥完全一致。
    if (!pin.empty()) {
        std::vector<uint8_t> prefix;
        prefix.push_back(static_cast<uint8_t>(pin.size() & 0xFF));
        prefix.insert(prefix.end(), pin.begin(), pin.end());
        try {
            videoChannel_->write(prefix.data(), prefix.size());
            controlChannel_->write(prefix.data(), prefix.size());
        } catch (const std::exception& e) {
            OH_LOG_ERROR(LOG_APP, "[StreamManager] Direct PIN send failed: %{public}s", e.what());
            closeLocalTunnels();
            releaseLocalTunnels();
            adb_ = nullptr;
            return DIRECT_ERR_VIDEO;
        }
    }

    running_.store(true);
    videoReaderDone_.store(false);
    audioReaderDone_.store(false);
    // 清掉上一轮残留的控制包（drainQueue 是 Lifecycle.cpp 的文件内私有辅助函数）
    std::vector<uint8_t> stale;
    while (controlReliableQueue_.try_dequeue(stale)) {
    }
    initPacketPools();

    videoThread_ = std::thread(&ScrcpyStreamManager::videoThreadFunc, this);
    controlThread_ = std::thread(&ScrcpyStreamManager::controlThreadFunc, this);
    controlSendThread_ = std::thread(&ScrcpyStreamManager::controlSendThreadFunc, this);

    OH_LOG_INFO(LOG_APP, "[StreamManager] Direct streams started host=%{public}s video=%{public}u control=%{public}u",
                host.c_str(), videoPort, controlPort);
    return 0;
}
