#include "inotify_watch.h"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <sys/inotify.h>

#ifdef RTPATH_TEST_HOST
#include <jni.h>
#include <atomic>

namespace {
std::atomic<int> testWatchCap{0};
std::atomic<int> testPendingCap{0};
}

extern "C" JNIEXPORT void JNICALL
Java_io_github_eltancex_rtpath_RecoveryTestLimits_configure(JNIEnv*, jobject, jint watches, jint pending) {
    testWatchCap = watches;
    testPendingCap = pending;
}
#endif

namespace rtpath {
namespace {

constexpr std::size_t maxPending = 8192;
constexpr std::size_t maxPendingBytes = 4 * 1024 * 1024;
constexpr std::uint32_t events = IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO |
    IN_MODIFY | IN_CLOSE_WRITE | IN_ATTRIB | IN_DELETE_SELF | IN_MOVE_SELF;

std::size_t pendingLimit() {
#ifdef RTPATH_TEST_HOST
    const auto testLimit = testPendingCap.load();
    if (testLimit > 0) return static_cast<std::size_t>(testLimit);
#endif
    return maxPending;
}

}  // namespace

InotifyWatch::InotifyWatch() : fd_(inotify_init1(IN_NONBLOCK | IN_CLOEXEC)) {
    if (fd() < 0) gap("inotify_init1", errno);
}

bool InotifyWatch::add(const std::string& path, int directory) {
#ifdef RTPATH_TEST_HOST
    const auto testLimit = testWatchCap.load();
    if (testLimit > 0 && !paths_.contains(path) && paths_.size() >= static_cast<std::size_t>(testLimit)) {
        registrationError_ = ENOSPC;
        failed_.insert(path);
        return false;
    }
#endif
    // The procfs link names the open directory, even if its pathname changes.
    char target[64];
    std::snprintf(target, sizeof(target), "/proc/self/fd/%d", directory);
    const int descriptor = inotify_add_watch(fd(), target, events | IN_ONLYDIR | IN_EXCL_UNLINK);
    if (descriptor < 0) {
        registrationError_ = errno;
        failed_.insert(path);
        return false;
    }

    if (const auto old = paths_.find(path); old != paths_.end() && old->second != descriptor) {
        remove(old->second);
    }
    if (const auto old = descriptors_.find(descriptor); old != descriptors_.end() && old->second != path) {
        paths_.erase(old->second);
    }
    paths_[path] = descriptor;
    descriptors_[descriptor] = path;
    failed_.erase(path);
    return true;
}

void InotifyWatch::remove(int descriptor) {
    const auto it = descriptors_.find(descriptor);
    if (it == descriptors_.end()) return;
    paths_.erase(it->second);
    descriptors_.erase(it);
    inotify_rm_watch(fd(), descriptor);
}

std::optional<std::string> InotifyWatch::nextFailed(const std::string& after) const {
    auto it = failed_.upper_bound(after);
    if (it == failed_.end()) it = failed_.begin();
    if (it == failed_.end()) return std::nullopt;
    return *it;
}

void InotifyWatch::forget(const std::string& path, bool keepDirectory) {
    const auto prefix = path + "/";
    if (!keepDirectory) {
        if (const auto it = paths_.find(path); it != paths_.end()) remove(it->second);
    }
    unsigned removed = 0;
    for (auto it = paths_.lower_bound(prefix); it != paths_.end() && it->first.starts_with(prefix);) {
        const auto descriptor = (it++)->second;
        remove(descriptor);
        if (++removed % 512 == 0 && error_ == 0) {
            // rm_watch itself queues IN_IGNORED. Drain periodically on large subtrees.
            drain();
            it = paths_.lower_bound(prefix);
        }
    }
    failed_.erase(path);
    for (auto it = failed_.lower_bound(prefix); it != failed_.end() && it->starts_with(prefix);) {
        it = failed_.erase(it);
    }
}

void InotifyWatch::gap(const char* operation, int error) {
    if (error_ != 0) return;
    operation_ = operation;
    error_ = error;
}

void InotifyWatch::dirty(std::string path) {
    const auto [it, inserted] = pending_.insert(std::move(path));
    if (inserted) pendingBytes_ += it->size();
    if (pending_.size() + moves_.size() > pendingLimit() || pendingBytes_ > maxPendingBytes) {
        gap("inotify pending paths overflow", ENOBUFS);
    }
}

void InotifyWatch::event(int descriptor, std::uint32_t mask, std::uint32_t cookie, const char* name) {
    ++sequence_;
    if (mask & IN_Q_OVERFLOW) {
        gap("inotify kernel queue overflow", ENOBUFS);
        return;
    }
    const auto it = descriptors_.find(descriptor);
    if (it == descriptors_.end()) return;
    const auto& parent = it->second;
    if ((mask & IN_UNMOUNT) || (parent.empty() && (mask & (IN_MOVE_SELF | IN_DELETE_SELF | IN_IGNORED)))) {
        gap("inotify scope moved, deleted or unmounted", ESTALE);
        return;
    }
    if (mask & IN_IGNORED) {
        dirty(parent);
        paths_.erase(parent);
        descriptors_.erase(it);
        return;
    }
    if (*name == '\0') {
        if (!parent.empty() && (mask & (IN_DELETE_SELF | IN_ATTRIB))) dirty(parent);
        return;
    }

    auto path = parent.empty() ? std::string(name) : parent + "/" + name;
    if (cookie != 0 && (mask & IN_MOVED_FROM)) {
        pendingBytes_ += path.size();
        const auto [_, inserted] = moves_.try_emplace(cookie, path);
        if (inserted) {
            if (moves_.size() + pending_.size() > pendingLimit() || pendingBytes_ > maxPendingBytes) {
                gap("inotify pending moves overflow", ENOBUFS);
            }
            return;
        }
        pendingBytes_ -= path.size();
    }
    if (cookie != 0 && (mask & IN_MOVED_TO)) {
        if (const auto source = moves_.find(cookie); source != moves_.end()) {
            auto previous = std::move(source->second);
            pendingBytes_ -= previous.size();
            moves_.erase(source);
            dirty(std::move(previous));
        }
    }
    dirty(std::move(path));
}

bool InotifyWatch::drain() {
    alignas(inotify_event) char buffer[32 * 1024];
    // Yield on continuous input so cancellation and SQLite commits can progress.
    for (unsigned attempt = 0; attempt < 32 && error_ == 0; ++attempt) {
        const auto length = read(fd(), buffer, sizeof(buffer));
        if (length < 0 && errno == EINTR) continue;
        if (length < 0 && errno == EAGAIN) return true;
        if (length <= 0) {
            gap("read inotify", length == 0 ? EIO : errno);
            return false;
        }
        for (std::size_t offset = 0; offset < static_cast<std::size_t>(length) && error_ == 0;) {
            const auto remaining = static_cast<std::size_t>(length) - offset;
            const auto* entry = reinterpret_cast<const inotify_event*>(buffer + offset);
            if (remaining < sizeof(*entry) || entry->len > remaining - sizeof(*entry) ||
                (entry->len != 0 && std::memchr(entry->name, '\0', entry->len) == nullptr)) {
                gap("inotify event format", EPROTO);
                return false;
            }
            event(entry->wd, entry->mask, entry->cookie, entry->len == 0 ? "" : entry->name);
            offset += sizeof(*entry) + entry->len;
        }
    }
    return false;
}

std::set<std::string> InotifyWatch::takePending() {
    for (auto& [cookie, path] : moves_) pending_.insert(std::move(path));
    moves_.clear();
    pendingBytes_ = 0;
    return std::exchange(pending_, {});
}

}  // namespace rtpath
