// TcpChannel - 基于文件描述符的通道实现
// 不实现网络连接逻辑，fd由ArkTS传入
#include "adb/channel/TcpChannel.h"
#include <cerrno>
#include <cstring>
#include <unistd.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netdb.h> // for getaddrinfo
#include <poll.h>
#include <stdexcept>
#include <chrono>
#include <thread>
#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "TcpChannel"

namespace {
void tuneTcpDisconnectDetection(int fd) {
    int keepAlive = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, reinterpret_cast<const char*>(&keepAlive),
                   sizeof(keepAlive)) != 0) {
        OH_LOG_WARN(LOG_APP, "TcpChannel: failed to set SO_KEEPALIVE on fd=%{public}d errno=%{public}d",
                    fd, errno);
    }

#ifdef TCP_KEEPIDLE
    int keepIdleSeconds = 3;
    if (setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, reinterpret_cast<const char*>(&keepIdleSeconds),
                   sizeof(keepIdleSeconds)) != 0) {
        OH_LOG_WARN(LOG_APP, "TcpChannel: failed to set TCP_KEEPIDLE on fd=%{public}d errno=%{public}d",
                    fd, errno);
    }
#endif

#ifdef TCP_KEEPINTVL
    int keepIntervalSeconds = 1;
    if (setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, reinterpret_cast<const char*>(&keepIntervalSeconds),
                   sizeof(keepIntervalSeconds)) != 0) {
        OH_LOG_WARN(LOG_APP, "TcpChannel: failed to set TCP_KEEPINTVL on fd=%{public}d errno=%{public}d",
                    fd, errno);
    }
#endif

#ifdef TCP_KEEPCNT
    int keepCount = 3;
    if (setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, reinterpret_cast<const char*>(&keepCount),
                   sizeof(keepCount)) != 0) {
        OH_LOG_WARN(LOG_APP, "TcpChannel: failed to set TCP_KEEPCNT on fd=%{public}d errno=%{public}d",
                    fd, errno);
    }
#endif

#ifdef TCP_USER_TIMEOUT
    int userTimeoutMs = 3000;
    if (setsockopt(fd, IPPROTO_TCP, TCP_USER_TIMEOUT, reinterpret_cast<const char*>(&userTimeoutMs),
                   sizeof(userTimeoutMs)) != 0) {
        OH_LOG_WARN(LOG_APP, "TcpChannel: failed to set TCP_USER_TIMEOUT on fd=%{public}d errno=%{public}d",
                    fd, errno);
    }
#endif
}

int pollRetryOnEintr(struct pollfd* pfd, nfds_t nfds, int timeoutMs) {
    if (timeoutMs < 0) {
        while (true) {
            int ret = poll(pfd, nfds, -1);
            if (ret < 0 && errno == EINTR) {
                continue;
            }
            return ret;
        }
    }

    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    while (true) {
        auto now = std::chrono::steady_clock::now();
        if (now >= deadline) {
            return 0;
        }
        int remainingMs = static_cast<int>(
            std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count()
        );

        int ret = poll(pfd, nfds, remainingMs);
        if (ret < 0 && errno == EINTR) {
            continue;
        }
        return ret;
    }
}
}

TcpChannel::TcpChannel(int fd) : fd_(fd) {
    if (fd_ < 0) {
        throw std::invalid_argument("Invalid fd");
    }
    // ArkTS TCPSocket sets the fd to non-blocking mode for its event loop.
    // We need blocking I/O for synchronous read()/write(), so clear O_NONBLOCK.
    int flags = fcntl(fd_, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(fd_, F_SETFL, flags & ~O_NONBLOCK);
        OH_LOG_INFO(LOG_APP, "TcpChannel: set fd=%{public}d to blocking mode (was flags=0x%{public}x)", fd_, flags);
    }
    int nodelay = 1;
    if (setsockopt(fd_, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&nodelay),
                   sizeof(nodelay)) != 0) {
        OH_LOG_WARN(LOG_APP, "TcpChannel: failed to set TCP_NODELAY on fd=%{public}d errno=%{public}d",
                    fd_, errno);
    }
    tuneTcpDisconnectDetection(fd_);
    buffer_.resize(BUFFER_SIZE);
    OH_LOG_INFO(LOG_APP, "TcpChannel: created with fd=%{public}d", fd_);
}

namespace {
constexpr int MAX_CONNECT_RETRIES = 3;
constexpr int CONNECT_RETRY_DELAY_MS = 500;

int tryNonBlockingConnect(int fd, const struct sockaddr* addr, socklen_t addrlen,
                          int connectTimeoutMs, std::string& outError) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) {
        outError = "fcntl F_GETFL failed: " + std::string(strerror(errno));
        return -1;
    }
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    int rc = connect(fd, addr, addrlen);

    if (rc == 0) {
        fcntl(fd, F_SETFL, flags);
        return 0;
    }

    if (rc < 0 && errno != EINPROGRESS) {
        outError = "connect immediate fail: " + std::string(strerror(errno));
        return -1;
    }

    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = POLLOUT;

    int pollRet = pollRetryOnEintr(&pfd, 1, connectTimeoutMs);

    if (pollRet <= 0) {
        if (pollRet == 0) {
            outError = "connect timeout (" + std::to_string(connectTimeoutMs) + "ms)";
        } else {
            outError = "poll error: errno=" + std::to_string(errno);
        }
        return -1;
    }

    int sockError = 0;
    socklen_t sockErrorLen = sizeof(sockError);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &sockError, &sockErrorLen) < 0) {
        outError = "getsockopt SO_ERROR failed: errno=" + std::to_string(errno);
        return -1;
    }

    if (sockError != 0) {
        outError = std::string(strerror(sockError)) + " (" + std::to_string(sockError) + ")";
        if ((pfd.revents & POLLERR) != 0) outError += " [POLLERR]";
        if ((pfd.revents & POLLHUP) != 0) outError += " [POLLHUP]";
        return -1;
    }

    fcntl(fd, F_SETFL, flags);
    return 0;
}
}

namespace {
constexpr int MAX_RESOLVE_RETRIES = 4;
constexpr int RESOLVE_RETRY_DELAY_MS = 200;

// Fill `out` for an address that is already numeric. Returns false for hostnames
// so the caller falls back to the resolver.
bool parseIpLiteral(const std::string& host, int port, struct sockaddr_storage& out,
                    socklen_t& outLen) {
    struct sockaddr_in v4;
    std::memset(&v4, 0, sizeof(v4));
    if (inet_pton(AF_INET, host.c_str(), &v4.sin_addr) == 1) {
        v4.sin_family = AF_INET;
        v4.sin_port = htons(static_cast<uint16_t>(port));
        std::memcpy(&out, &v4, sizeof(v4));
        outLen = sizeof(v4);
        return true;
    }

    struct sockaddr_in6 v6;
    std::memset(&v6, 0, sizeof(v6));
    if (inet_pton(AF_INET6, host.c_str(), &v6.sin6_addr) == 1) {
        v6.sin6_family = AF_INET6;
        v6.sin6_port = htons(static_cast<uint16_t>(port));
        std::memcpy(&out, &v6, sizeof(v6));
        outLen = sizeof(v6);
        return true;
    }
    return false;
}
}

TcpChannel::TcpChannel(const std::string& host, int port) {
    fd_ = -1;
    buffer_.resize(BUFFER_SIZE);

    const std::string portStr = std::to_string(port);

    auto connectWithRetries = [&](const struct sockaddr* addr, socklen_t addrLen,
                                  std::string& lastError) -> bool {
        for (int retry = 0; retry < MAX_CONNECT_RETRIES; retry++) {
            if (retry > 0) {
                OH_LOG_INFO(LOG_APP, "TcpChannel: Retry %{public}d/%{public}d after %{public}d ms...",
                            retry, MAX_CONNECT_RETRIES - 1, CONNECT_RETRY_DELAY_MS);
                std::this_thread::sleep_for(std::chrono::milliseconds(CONNECT_RETRY_DELAY_MS));
            }

            fd_ = ::socket(addr->sa_family, SOCK_STREAM, 0);
            if (fd_ < 0) {
                lastError = "socket: " + std::string(strerror(errno));
                continue;
            }

            std::string errorMsg;
            // Use a shorter timeout per attempt to allow retries
            int perAttemptTimeoutMs = (retry == MAX_CONNECT_RETRIES - 1) ? 30000 : 6000;
            if (tryNonBlockingConnect(fd_, addr, addrLen, perAttemptTimeoutMs, errorMsg) == 0) {
                int nodelay = 1;
                if (setsockopt(fd_, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&nodelay),
                               sizeof(nodelay)) != 0) {
                    OH_LOG_WARN(LOG_APP, "TcpChannel: failed to set TCP_NODELAY on fd=%{public}d errno=%{public}d",
                                fd_, errno);
                }
                tuneTcpDisconnectDetection(fd_);
                OH_LOG_INFO(LOG_APP, "TcpChannel: connected fd=%{public}d", fd_);
                return true;
            }

            OH_LOG_ERROR(LOG_APP, "TcpChannel: Connect attempt %{public}d failed: %{public}s",
                         retry + 1, errorMsg.c_str());
            ::close(fd_);
            fd_ = -1;
            lastError = errorMsg;
        }
        return false;
    };

    std::string lastError;

    // Numeric addresses must never touch the resolver. HarmonyOS's getaddrinfo
    // can fail with EAI_AGAIN ("Try again") for a plain IPv4 literal whenever
    // the system resolver is momentarily unavailable, which broke LAN direct
    // connections that need no DNS at all.
    struct sockaddr_storage literal;
    socklen_t literalLen = 0;
    if (parseIpLiteral(host, port, literal, literalLen)) {
        OH_LOG_INFO(LOG_APP, "TcpChannel: Connecting to literal %{public}s:%{public}s...",
                    host.c_str(), portStr.c_str());
        if (connectWithRetries(reinterpret_cast<const struct sockaddr*>(&literal), literalLen,
                               lastError)) {
            return;
        }
        throw std::runtime_error("Failed to connect to " + host + ":" + portStr +
                                 " after " + std::to_string(MAX_CONNECT_RETRIES) +
                                 " retries (last error: " + lastError + ")");
    }

    struct addrinfo hints, *res = nullptr;
    std::memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    OH_LOG_INFO(LOG_APP, "TcpChannel: Resolving %{public}s:%{public}s...", host.c_str(), portStr.c_str());

    int status = 0;
    for (int attempt = 0; attempt < MAX_RESOLVE_RETRIES; attempt++) {
        if (attempt > 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(RESOLVE_RETRY_DELAY_MS));
        }
        status = getaddrinfo(host.c_str(), portStr.c_str(), &hints, &res);
        if (status == 0) {
            break;
        }
        OH_LOG_WARN(LOG_APP, "TcpChannel: Resolve attempt %{public}d failed: %{public}s",
                    attempt + 1, gai_strerror(status));
        if (status != EAI_AGAIN) {
            break;
        }
        res = nullptr;
    }
    if (status != 0) {
        throw std::runtime_error("getaddrinfo failed: " + std::string(gai_strerror(status)));
    }

    for (struct addrinfo* p = res; p != nullptr; p = p->ai_next) {
        if (connectWithRetries(p->ai_addr, p->ai_addrlen, lastError)) {
            freeaddrinfo(res);
            return;
        }
    }

    freeaddrinfo(res);

    throw std::runtime_error("Failed to connect to " + host + ":" + portStr +
                             " after " + std::to_string(MAX_CONNECT_RETRIES) +
                             " retries (last error: " + lastError + ")");
}

TcpChannel::~TcpChannel() {
    close();
}

void TcpChannel::write(const uint8_t* data, size_t len) {
    if (closed_.load()) {
        throw std::runtime_error("TcpChannel: write on closed channel");
    }

    size_t offset = 0;
    while (offset < len) {
        // Use send with MSG_NOSIGNAL to avoid SIGPIPE if the socket is closed by peer
        ssize_t n = ::send(fd_, data + offset, len - offset, MSG_NOSIGNAL);
        if (n <= 0) {
            // If error is EPIPE, it means connection closed, handled as runtime_error
            throw std::runtime_error("TcpChannel: write failed (broken pipe or closed)");
        }
        offset += static_cast<size_t>(n);
    }
}

void TcpChannel::read(uint8_t* buf, size_t len) {
    readWithTimeout(buf, len, -1);
}

void TcpChannel::readWithTimeout(uint8_t* buf, size_t len, int timeoutMs) {
    if (closed_.load()) {
        throw std::runtime_error("TcpChannel: read on closed channel");
    }

    size_t offset = 0;
    while (offset < len) {
        // 1. Try reading from buffer
        size_t available = bufferTail_ - bufferHead_;
        if (available > 0) {
            size_t toCopy = std::min(available, len - offset);
            std::memcpy(buf + offset, buffer_.data() + bufferHead_, toCopy);
            bufferHead_ += toCopy;
            offset += toCopy;
            if (offset == len) break;
        }

        // 2. Buffer empty. Needs more data.
        size_t needed = len - offset;
        
        // Optimization: if needed size >= BUFFER_SIZE, read directly to user buffer
        if (needed >= BUFFER_SIZE) {
             if (timeoutMs >= 0) {
                 struct pollfd pfd;
                 pfd.fd = fd_;
                 pfd.events = POLLIN;
                 int ret = pollRetryOnEintr(&pfd, 1, timeoutMs);
                 if (ret <= 0) {
                     if (ret == 0) throw std::runtime_error("TcpChannel: read timeout");
                     OH_LOG_ERROR(LOG_APP, "TcpChannel: poll failed errno=%{public}d", errno);
                     throw std::runtime_error("TcpChannel: poll failed");
                 }
                 if ((pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                     OH_LOG_ERROR(LOG_APP, "TcpChannel: poll failed revents=0x%{public}x", pfd.revents);
                     throw std::runtime_error("TcpChannel: poll failed");
                 }
             }
             ssize_t n = ::read(fd_, buf + offset, needed);
             if (n == 0) {
                 OH_LOG_INFO(LOG_APP, "TcpChannel: peer closed connection");
                 throw std::runtime_error("TcpChannel: connection closed by peer");
             }
             if (n < 0) {
                 OH_LOG_ERROR(LOG_APP, "TcpChannel: read failed errno=%{public}d", errno);
                 throw std::runtime_error("TcpChannel: read failed or connection closed");
             }
             offset += static_cast<size_t>(n);
        } else {
             // Fill buffer
             fillBuffer(timeoutMs);
        }
    }
}

void TcpChannel::fillBuffer(int timeoutMs) {
    bufferHead_ = 0;
    bufferTail_ = 0;
    
    if (timeoutMs >= 0) {
         struct pollfd pfd;
         pfd.fd = fd_;
         pfd.events = POLLIN;
         int ret = pollRetryOnEintr(&pfd, 1, timeoutMs);
         if (ret <= 0) {
             if (ret == 0) throw std::runtime_error("TcpChannel: read timeout");
             OH_LOG_ERROR(LOG_APP, "TcpChannel: poll failed errno=%{public}d", errno);
             throw std::runtime_error("TcpChannel: poll failed");
         }
         if ((pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
             OH_LOG_ERROR(LOG_APP, "TcpChannel: poll failed revents=0x%{public}x", pfd.revents);
             throw std::runtime_error("TcpChannel: poll failed");
         }
    }
    
    ssize_t n = ::read(fd_, buffer_.data(), BUFFER_SIZE);
    if (n == 0) {
        OH_LOG_INFO(LOG_APP, "TcpChannel: peer closed connection");
        throw std::runtime_error("TcpChannel: connection closed by peer");
    }
    if (n < 0) {
        OH_LOG_ERROR(LOG_APP, "TcpChannel: fillBuffer failed errno=%{public}d", errno);
        throw std::runtime_error("TcpChannel: read failed or connection closed");
    }
    bufferTail_ = static_cast<size_t>(n);
}

void TcpChannel::close() {
    bool expected = false;
    if (closed_.compare_exchange_strong(expected, true)) {
        OH_LOG_INFO(LOG_APP, "TcpChannel: closing fd=%{public}d", fd_);
        if (fd_ >= 0) {
            // Shutdown both read and write to force unblock any pending read/write operations
            ::shutdown(fd_, SHUT_RDWR);
            ::close(fd_);
            fd_ = -1;
        }
    }
}

bool TcpChannel::isClosed() const {
    return closed_.load();
}

int TcpChannel::releaseFd() {
    int fd = fd_;
    fd_ = -1;
    closed_.store(true);
    bufferHead_ = 0;
    bufferTail_ = 0;
    return fd;
}
