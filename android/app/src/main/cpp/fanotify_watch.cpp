#include "fanotify_watch.h"
#include "index_files.h"

#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <linux/fanotify.h>
#include <poll.h>
#include <string_view>
#include <sys/syscall.h>
#include <sys/vfs.h>

namespace rtpath {
namespace {

constexpr std::uint64_t changeMask = FAN_CREATE | FAN_DELETE | FAN_RENAME |
    FAN_MODIFY | FAN_CLOSE_WRITE | FAN_ATTRIB | FAN_ONDIR;
constexpr int dirFlags = O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;

struct FileHandle {
    std::uint32_t size = 0;
    std::int32_t type = 0;
    std::array<unsigned char, 128> data;
};

struct Endpoint {
    FileHandle parent;
    std::string_view name;
    std::array<unsigned char, 8> fsid;
};

struct Event {
    std::uint64_t mask;
    std::optional<Endpoint> oldOrSingle;
    std::optional<Endpoint> movedTo;
};

std::string errorText(const char* operation, int error) {
    return std::string(operation) + " errno=" + std::to_string(error) + " (" + strerror(error) + ")";
}

Fd createGroup(int root, std::string& reason) {
    Fd group(static_cast<int>(syscall(__NR_fanotify_init,
        FAN_CLOEXEC | FAN_NONBLOCK | FAN_CLASS_NOTIF | FAN_REPORT_DFID_NAME, O_RDONLY | O_CLOEXEC)));
    if (group.get() < 0) {
        reason = errorText("fanotify_init", errno);
        return group;
    }
    if (syscall(__NR_fanotify_mark, group.get(), FAN_MARK_ADD | FAN_MARK_FILESYSTEM, changeMask, root, nullptr) != 0) {
        reason = errorText("FAN_MARK_FILESYSTEM + FAN_RENAME", errno);
        return Fd();
    }
    return group;
}

std::optional<std::string> fdPath(int fd) {
    char link[64];
    std::snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
    char value[4096];
    const auto count = readlink(link, value, sizeof(value));
    if (count < 0) return {};
    if (count == 0 || count == sizeof(value) || value[0] != '/') {
        errno = ENAMETOOLONG;
        return {};
    }
    return std::string(value, count);
}

bool sameDirectory(const struct stat& left, const struct stat& right) {
    return left.st_dev == right.st_dev && left.st_ino == right.st_ino;
}

bool parseEndpoint(const unsigned char* record, std::size_t len, Endpoint& endpoint) {
    constexpr auto start = offsetof(fanotify_event_info_fid, handle);
    constexpr auto payload = start + offsetof(FileHandle, data);
    if (len <= payload) return false;
    std::memcpy(endpoint.fsid.data(), record + offsetof(fanotify_event_info_fid, fsid), endpoint.fsid.size());
    std::memcpy(&endpoint.parent.size, record + start, sizeof(endpoint.parent.size));
    std::memcpy(&endpoint.parent.type, record + start + sizeof(endpoint.parent.size), sizeof(endpoint.parent.type));
    const auto size = endpoint.parent.size;
    if (size == 0 || size % 4 != 0 || size > endpoint.parent.data.size() || size >= len - payload) return false;
    std::memcpy(endpoint.parent.data.data(), record + payload, size);
    const auto* name = reinterpret_cast<const char*>(record + payload + size);
    const auto available = len - payload - size;
    const auto length = strnlen(name, available);
    if (length == 0 || length == available || length > 255) return false;
    endpoint.name = {name, length};
    return endpoint.name != ".." && endpoint.name.find('/') == std::string_view::npos;
}

bool parseEvent(const unsigned char* data, std::size_t size, std::size_t start, Event& event) {
    const bool rename = (event.mask & FAN_RENAME) != 0;
    while (start < size) {
        fanotify_event_info_header header {};
        if (size - start < sizeof(header)) return false;
        std::memcpy(&header, data + start, sizeof(header));
        if (header.len < sizeof(header) || header.len > size - start) return false;
        auto* endpoint = &event.oldOrSingle;
        switch (header.info_type) {
            case FAN_EVENT_INFO_TYPE_DFID_NAME:
                if (rename) return false;
                break;
            case FAN_EVENT_INFO_TYPE_NEW_DFID_NAME:
                endpoint = &event.movedTo;
                [[fallthrough]];
            case FAN_EVENT_INFO_TYPE_OLD_DFID_NAME:
                if (!rename) return false;
                break;
            default:
                start += header.len;
                continue;
        }
        if (*endpoint || !parseEndpoint(data + start, header.len, endpoint->emplace())) return false;
        start += header.len;
    }
    if (!event.oldOrSingle || (rename && !event.movedTo)) return false;
    if (event.oldOrSingle->name == "." && (event.mask & (FAN_CREATE | FAN_DELETE | FAN_RENAME))) return false;
    return !event.movedTo || event.movedTo->name != ".";
}

template <typename Receive>
int readEvents(int group, pid_t filter, Receive receive) {
    unsigned char data[32 * 1024];
    const auto length = read(group, data, sizeof(data));
    if (length < 0) return errno;
    if (length == 0) return EIO;
    const auto total = static_cast<std::size_t>(length);
    for (std::size_t offset = 0; offset < total;) {
        fanotify_event_metadata metadata {};
        if (total - offset < sizeof(metadata)) return EPROTO;
        std::memcpy(&metadata, data + offset, sizeof(metadata));
        Fd eventFd(metadata.fd);
        if (metadata.vers != FANOTIFY_METADATA_VERSION || metadata.metadata_len < sizeof(metadata) ||
            metadata.event_len < metadata.metadata_len || metadata.event_len > total - offset) return EPROTO;
        if (metadata.mask & FAN_Q_OVERFLOW) return ENOBUFS;
        if (filter == 0 || metadata.pid == filter) {
            Event event{metadata.mask, {}, {}};
            if (!parseEvent(data + offset, metadata.event_len, metadata.metadata_len, event)) return EPROTO;
            if (!receive(event)) return ECANCELED;
        }
        offset += metadata.event_len;
    }
    return 0;
}

// A positive result describes a parent in the pinned root. A zero result is outside
// the scope or names a directory already deleted. Other results require a fresh baseline.
int resolve(int mount, int root, std::string_view scope, const Endpoint& endpoint, std::string& relative,
            struct stat& info) {
    Fd parent(static_cast<int>(syscall(__NR_open_by_handle_at, mount, &endpoint.parent, dirFlags)));
    if (parent.get() < 0 || fstat(parent.get(), &info) != 0) return -errno;
    if (info.st_nlink == 0) return 0;
    const auto absolute = fdPath(parent.get());
    if (!absolute) return -errno;
    if (*absolute != scope) {
        if (!absolute->starts_with(scope)) return 0;
        if (scope != "/" && (*absolute)[scope.size()] != '/') return 0;
        relative = absolute->substr(scope.size() + (scope != "/"));
    }
    const auto name = relative.empty() ? "." : relative.c_str();
    Fd anchored(openat(root, name, dirFlags));
    struct stat reopened {};
    if (anchored.get() < 0 || fstat(anchored.get(), &reopened) != 0) return -errno;
    if (!sameDirectory(reopened, info)) return -ESTALE;
    return 1;
}

std::optional<std::array<unsigned char, 8>> filesystemId(int fd) {
    struct statfs info {};
    std::array<unsigned char, 8> id;
    static_assert(sizeof(info.f_fsid) == sizeof(id));
    if (fstatfs(fd, &info) != 0) return {};
    std::memcpy(id.data(), &info.f_fsid, id.size());
    return id;
}

class Fixture {
public:
    explicit Fixture(int cache) : cache_(cache) {
        static std::atomic<unsigned> next{0};
        // Only the process that creates this private directory ever cleans it up.
        for (unsigned attempt = 0; attempt < 8; ++attempt) {
            name_ = ".rtpath-fanotify-" + std::to_string(getpid()) + "-" + std::to_string(next++);
            if (mkdirat(cache_, name_.c_str(), 0700) == 0) {
                created_ = true;
                fd_ = Fd(openat(cache_, name_.c_str(), dirFlags));
                if (fd() >= 0) {
                    struct stat info {};
                    if (fstat(fd(), &info) != 0 || info.st_uid != geteuid() || (info.st_mode & 0777) != 0700) {
                        fd_ = Fd();
                        errno = EACCES;
                    }
                }
                return;
            }
            if (errno != EEXIST) return;
        }
    }
    ~Fixture() {
        if (!created_) return;
        if (fd() >= 0) {
            unlinkat(fd(), "from/entry", 0);
            unlinkat(fd(), "to/entry", 0);
            unlinkat(fd(), "from/tree", AT_REMOVEDIR);
            unlinkat(fd(), "to/tree", AT_REMOVEDIR);
            unlinkat(fd(), "from", AT_REMOVEDIR);
            unlinkat(fd(), "to", AT_REMOVEDIR);
        }
        unlinkat(cache_, name_.c_str(), AT_REMOVEDIR);
    }
    int fd() const { return fd_.get(); }

private:
    int cache_;
    std::string name_;
    bool created_ = false;
    Fd fd_;
};

int exercise(int group, int mount, int cache, const std::array<unsigned char, 8>& fsid) {
    Fixture fixture(cache);
    if (fixture.fd() < 0) return errno;
    const auto path = fdPath(fixture.fd());
    if (!path) return errno;
    if (mkdirat(fixture.fd(), "from", 0700) != 0 || mkdirat(fixture.fd(), "to", 0700) != 0) return errno;
    {
        Fd file(openat(fixture.fd(), "from/entry", O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600));
        if (file.get() < 0 || write(file.get(), "x", 1) != 1 || fchmod(file.get(), 0400) != 0) return errno;
    }
    if (renameat(fixture.fd(), "from/entry", fixture.fd(), "to/entry") != 0 ||
        unlinkat(fixture.fd(), "to/entry", 0) != 0 ||
        mkdirat(fixture.fd(), "from/tree", 0700) != 0 ||
        renameat(fixture.fd(), "from/tree", fixture.fd(), "to/tree") != 0) return errno;

    constexpr auto expected = FAN_CREATE | FAN_DELETE | FAN_MODIFY | FAN_CLOSE_WRITE | FAN_RENAME | FAN_ATTRIB;
    std::uint64_t seen = 0;
    bool directoryMove = false;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
    while (seen != expected || !directoryMove) {
        const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
            deadline - std::chrono::steady_clock::now()).count();
        if (remaining <= 0) return ETIMEDOUT;
        pollfd ready{group, POLLIN, 0};
        const auto result = poll(&ready, 1, static_cast<int>(remaining));
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) return errno;
        if (result == 0) return ETIMEDOUT;
        int resolutionError = 0;
        const auto error = readEvents(group, getpid(), [&](const Event& event) {
            std::string from;
            struct stat info {};
            const auto& old = *event.oldOrSingle;
            if (old.fsid != fsid) {
                resolutionError = EXDEV;
                return false;
            }
            const auto located = resolve(mount, fixture.fd(), *path, old, from, info);
            if (located < 0) {
                resolutionError = -located;
                return false;
            }
            if (located == 0) return true;
            if (event.movedTo) {
                const auto& moved = *event.movedTo;
                std::string to;
                if (moved.fsid != fsid) {
                    resolutionError = EXDEV;
                    return false;
                }
                const auto destination = resolve(mount, fixture.fd(), *path, moved, to, info);
                if (destination != 1) {
                    resolutionError = destination < 0 ? -destination : EXDEV;
                    return false;
                }
                if (from == "from" && to == "to" && old.name == moved.name) {
                    if (old.name == "entry") seen |= FAN_RENAME;
                    if (old.name == "tree") directoryMove = (event.mask & FAN_ONDIR) != 0;
                }
            } else if (old.name == "entry") {
                if (from == "from") seen |= event.mask & (expected & ~FAN_DELETE & ~FAN_RENAME);
                if (from == "to") seen |= event.mask & FAN_DELETE;
            }
            return true;
        });
        if (resolutionError != 0) return resolutionError;
        if (error != 0 && error != EAGAIN && error != EINTR) return error;
    }
    return 0;
}

}  // namespace

std::unique_ptr<FanotifyWatch> FanotifyWatch::start(int root, int fixture, const struct stat& indexDirectory,
                                                   std::string& reason) {
    auto probeGroup = createGroup(root, reason);
    if (probeGroup.get() < 0) return {};
    if (fixture < 0) {
        reason = "no app cache on target mount";
        return {};
    }
    const auto path = fdPath(root);
    if (!path) {
        reason = errorText("read fanotify scope path", errno);
        return {};
    }
    const auto fsid = filesystemId(root);
    if (!fsid) {
        reason = errorText("read fanotify filesystem ID", errno);
        return {};
    }
    if (const auto error = exercise(probeGroup.get(), root, fixture, *fsid); error != 0) {
        reason = errorText("fanotify FID/name fixture", error);
        return {};
    }
    probeGroup = Fd();
    auto group = createGroup(root, reason);
    if (group.get() < 0) return {};
    return std::unique_ptr<FanotifyWatch>(new FanotifyWatch(std::move(group), root, *path, indexDirectory, *fsid));
}

bool FanotifyWatch::drain() {
    for (unsigned attempt = 0; attempt < 32 && error_ == 0; ++attempt) {
        const auto error = readEvents(fd(), 0, [&](const Event& event) {
            ++sequence_;
            for (const Endpoint* endpoint : {&*event.oldOrSingle, event.movedTo ? &*event.movedTo : nullptr}) {
                if (!endpoint) continue;
                std::string path;
                struct stat info {};
                if (endpoint->fsid != fsid_) {
                    gap("fanotify filesystem changed", ESTALE);
                    return false;
                }
                const auto located = resolve(root_, root_, path_, *endpoint, path, info);
                if (located < 0) {
                    gap("fanotify resolve directory handle", -located);
                    return false;
                }
                if (located == 0 || (sameDirectory(info, indexDirectory_) && isIndexFile(endpoint->name))) continue;
                if (endpoint->name != ".") {
                    if (!path.empty()) path += '/';
                    path += endpoint->name;
                }
                dirty(std::move(path));
            }
            return error_ == 0;
        });
        if (error == EINTR) continue;
        if (error == EAGAIN) return true;
        if (error != 0) {
            gap(error == ENOBUFS ? "fanotify kernel queue overflow" : "fanotify read or event format", error);
            return false;
        }
    }
    return false;
}

}  // namespace rtpath
