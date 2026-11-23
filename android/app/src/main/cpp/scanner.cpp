#include "fd.h"
#include "index_files.h"
#include "inotify_watch.h"

#include <android/api-level.h>
#include <jni.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <linux/fanotify.h>
#include <limits>
#include <linux/stat.h>
#include <memory>
#include <poll.h>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/vfs.h>
#include <type_traits>
#include <vector>

namespace {

using rtpath::Fd;
using Directory = std::unique_ptr<DIR, decltype(&closedir)>;
constexpr int directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
constexpr std::size_t batchSize = 512;
constexpr std::size_t maxDepth = 512;
constexpr std::uint64_t maxEntries = 2'000'000;
constexpr std::uint32_t fuseMagic = 0x65735546;
enum Outcome : jint { complete = 0, cancelled = 1, failed = 2 };
enum Change : jint { removed = 0, metadataOnly = 1, subtree = 2 };

bool readStatx(int parent, const char* name, int flags, unsigned mask, struct statx& info) {
    // Android 10 does not expose statx in its app ABI.
    static const bool available = android_get_device_api_level() >= 30;
    return available && syscall(__NR_statx, parent, name, flags, mask, &info) == 0 &&
           (info.stx_mask & mask) == mask;
}

std::string bytes(JNIEnv* env, jbyteArray value) {
    const auto length = env->GetArrayLength(value);
    std::string result(length, '\0');
    if (length > 0) {
        env->GetByteArrayRegion(value, 0, length, reinterpret_cast<jbyte*>(result.data()));
    }
    return result;
}

std::uint64_t fdMountId(int fd) {
    struct statx info {};
    if (readStatx(fd, "", AT_EMPTY_PATH | AT_SYMLINK_NOFOLLOW, STATX_MNT_ID, info) &&
        info.stx_mnt_id != 0) {
        return info.stx_mnt_id;
    }

    char path[64];
    std::snprintf(path, sizeof(path), "/proc/self/fdinfo/%d", fd);
    std::unique_ptr<FILE, decltype(&fclose)> input(std::fopen(path, "re"), fclose);
    if (!input) return 0;
    unsigned long long mount = 0;
    char line[128];
    while (std::fgets(line, sizeof(line), input.get())) {
        if (std::sscanf(line, "mnt_id: %llu", &mount) == 1) return mount;
    }
    return 0;
}

bool sameFile(const struct stat& left, const struct stat& right) {
    return left.st_dev == right.st_dev && left.st_ino == right.st_ino &&
           (left.st_mode & S_IFMT) == (right.st_mode & S_IFMT);
}

bool sameTime(const timespec& left, const timespec& right) {
    return left.tv_sec == right.tv_sec && left.tv_nsec == right.tv_nsec;
}

struct Metadata {
    struct stat info {};
    std::uint64_t mount = 0;
};

bool metadataAt(int parent, const char* name, Metadata& result) {
    struct statx info {};
    constexpr unsigned basic = STATX_TYPE | STATX_INO | STATX_SIZE | STATX_MTIME;
    constexpr int flags = AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT;
    if (readStatx(parent, name, flags, basic | STATX_MNT_ID, info) &&
        info.stx_mnt_id != 0 && info.stx_size <= INT64_MAX) {
        result.info.st_dev = makedev(info.stx_dev_major, info.stx_dev_minor);
        result.info.st_ino = info.stx_ino;
        result.info.st_mode = info.stx_mode;
        result.info.st_size = static_cast<off_t>(info.stx_size);
        result.info.st_mtim = {info.stx_mtime.tv_sec, info.stx_mtime.tv_nsec};
        result.mount = info.stx_mnt_id;
        return true;
    }

    // O_PATH identifies the object and its mount without following a symlink.
    // An older kernel can supply the mount ID through fdinfo instead of statx.
    Fd file(openat(parent, name, O_PATH | O_NOFOLLOW | O_CLOEXEC));
    if (file.get() < 0 || fstat(file.get(), &result.info) != 0) return false;
    result.mount = fdMountId(file.get());
    if (result.mount == 0) {
        errno = ENOTSUP;
        return false;
    }
    return true;
}

Fd openRoot(const std::string& base, std::string_view relative) {
    if (base.empty() || base.front() != '/' || base.find('\0') != std::string::npos ||
        relative.find('\0') != std::string_view::npos) {
        errno = EINVAL;
        return Fd();
    }
    Fd directory(open(base.c_str(), directoryFlags));
    while (directory.get() >= 0 && !relative.empty()) {
        const auto slash = relative.find('/');
        const std::string component(relative.substr(0, slash));
        if (component.empty() || component == "." || component == "..") {
            errno = EINVAL;
            return Fd();
        }
        directory = Fd(openat(directory.get(), component.c_str(), directoryFlags));
        if (slash == std::string_view::npos) break;
        relative.remove_prefix(slash + 1);
    }
    return directory;
}

const char* filesystemName(long magic) {
    switch (static_cast<std::uint32_t>(magic)) {
        case 0xf2f52010: return "f2fs";
        case fuseMagic: return "fuse";
        case 0xef53: return "ext4";
        case 0x01021994: return "tmpfs";
        case 0x794c7630: return "overlay";
        default: return "filesystem";
    }
}

std::string probeError(const char* operation, int error) {
    return std::string(operation) + " errno=" + std::to_string(error) + " (" + std::strerror(error) + ")";
}

// Match a named directory-entry event rather than any traffic on the filesystem.
std::string_view eventName(const unsigned char* record, std::size_t size, std::size_t start) {
    constexpr auto base = offsetof(fanotify_event_info_fid, handle);
    // The Linux file_handle header has two 32-bit fields before its bytes.
    constexpr auto handleHeader = sizeof(std::uint32_t) + sizeof(std::int32_t);
    while (start + sizeof(fanotify_event_info_header) <= size) {
        fanotify_event_info_header info{};
        std::memcpy(&info, record + start, sizeof(info));
        if (info.len < sizeof(info) || info.len > size - start) break;
        if (info.info_type == FAN_EVENT_INFO_TYPE_DFID_NAME && info.len >= base + handleHeader) {
            unsigned int handleBytes = 0;
            std::memcpy(&handleBytes, record + start + base, sizeof(handleBytes));
            const auto header = base + handleHeader;
            if (handleBytes < info.len - header) {
                const auto* name = reinterpret_cast<const char*>(record + start + header + handleBytes);
                const auto available = info.len - header - handleBytes;
                const auto length = strnlen(name, available);
                if (length < available) return {name, length};
            }
        }
        start += info.len;
    }
    return {};
}

std::string exerciseFanotify(int group, int directory) {
    static std::atomic<unsigned> next{0};
    const auto prefix = ".rtpath-fanotify-" + std::to_string(getpid()) + "-" + std::to_string(next++);
    const auto original = prefix + "-create";
    const auto renamed = prefix + "-rename";
    if (mkdirat(directory, prefix.c_str(), 0700) != 0) return probeError("mkdirat fixture", errno);
    {
        Fd fixture(openat(directory, prefix.c_str(), directoryFlags));
        int error = 0;
        if (fixture.get() < 0) {
            error = errno;
        } else {
            Fd marker(openat(fixture.get(), original.c_str(), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600));
            if (marker.get() < 0 || renameat(fixture.get(), original.c_str(), fixture.get(), renamed.c_str()) != 0 ||
                unlinkat(fixture.get(), renamed.c_str(), 0) != 0) {
                error = errno;
                unlinkat(fixture.get(), original.c_str(), 0);
                unlinkat(fixture.get(), renamed.c_str(), 0);
            }
        }
        if (unlinkat(directory, prefix.c_str(), AT_REMOVEDIR) != 0 && error == 0) error = errno;
        if (error != 0) return probeError("event fixture", error);
    }
    constexpr auto expected = FAN_CREATE | FAN_DELETE | FAN_MOVED_FROM | FAN_MOVED_TO;
    std::uint64_t found = 0;
    bool overflow = false;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
    unsigned char data[16 * 1024];
    while (found != expected && !overflow) {
        const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
            deadline - std::chrono::steady_clock::now()).count();
        if (remaining <= 0) break;
        pollfd ready{group, POLLIN, 0};
        const auto status = poll(&ready, 1, static_cast<int>(remaining));
        if (status < 0 && errno == EINTR) continue;
        if (status < 0) return probeError("poll fanotify", errno);
        if (status == 0) break;
        const auto length = read(group, data, sizeof(data));
        if (length < 0 && (errno == EAGAIN || errno == EINTR)) continue;
        if (length < 0) return probeError("read fanotify", errno);
        if (length == 0) break;
        const auto total = static_cast<std::size_t>(length);
        std::size_t offset = 0;
        while (offset + sizeof(fanotify_event_metadata) <= total) {
            fanotify_event_metadata event{};
            std::memcpy(&event, data + offset, sizeof(event));
            if (event.vers != FANOTIFY_METADATA_VERSION || event.metadata_len < sizeof(event) ||
                event.event_len < event.metadata_len || event.event_len > total - offset) {
                return "fanotify event format unsupported";
            }
            Fd eventFd(event.fd);
            overflow |= (event.mask & FAN_Q_OVERFLOW) != 0;
            const auto name = eventName(data + offset, event.event_len, event.metadata_len);
            if (name == original) found |= event.mask & (FAN_CREATE | FAN_MOVED_FROM);
            if (name == renamed) found |= event.mask & (FAN_DELETE | FAN_MOVED_TO);
            offset += event.event_len;
        }
    }
    if (overflow) return "fanotify queue overflow";
    std::string result = "verified names:";
    if (found & FAN_CREATE) result += " CREATE";
    if (found & FAN_MOVED_FROM) result += " MOVED_FROM";
    if (found & FAN_MOVED_TO) result += " MOVED_TO";
    if (found & FAN_DELETE) result += " DELETE";
    if (found != expected) result += " (incomplete)";
    return result;
}

std::string inspectDirectory(const std::string& absolute, bool mark, bool exercise) {
    if (absolute.empty() || absolute.front() != '/') return probeError("open directory", EINVAL);
    const bool root = geteuid() == 0;
    // Match each scanner's entry path. The ordinary UID may traverse a parent
    // without permission to open that parent for listing.
    const auto directory = root ? openRoot("/", std::string_view(absolute).substr(1))
                                : openRoot(absolute, "");
    if (directory.get() < 0) return probeError("open directory", errno);
    struct statfs info {};
    if (fstatfs(directory.get(), &info) != 0) return probeError("fstatfs", errno);
    char type[24];
    std::snprintf(type, sizeof(type), "0x%x", static_cast<unsigned>(info.f_type));
    std::string result = std::string(filesystemName(info.f_type)) + " " + type +
                         " · mount " + std::to_string(fdMountId(directory.get())) + " · readable";
    if (!mark || !root) return result;

    const Fd group(static_cast<int>(syscall(__NR_fanotify_init,
        FAN_CLOEXEC | FAN_NONBLOCK | FAN_CLASS_NOTIF | FAN_REPORT_FID | FAN_REPORT_DFID_NAME,
        O_RDONLY | O_CLOEXEC)));
    if (group.get() < 0) return result + " · " + probeError("fanotify_init", errno);
    constexpr std::uint64_t mask = FAN_CREATE | FAN_DELETE | FAN_MOVED_FROM | FAN_MOVED_TO;
    if (syscall(__NR_fanotify_mark, group.get(), FAN_MARK_ADD | FAN_MARK_FILESYSTEM,
                mask, directory.get(), nullptr) != 0) {
        return result + " · " + probeError("FAN_MARK_FILESYSTEM", errno);
    }
    result += " · FAN_MARK_FILESYSTEM + DFID_NAME";
    return exercise ? result + " · " + exerciseFanotify(group.get(), directory.get())
                    : result + " · mark only";
}

std::uint8_t kind(mode_t mode) {
    if (S_ISREG(mode)) return 0;
    if (S_ISDIR(mode)) return 1;
    if (S_ISLNK(mode)) return 2;
    return 3;
}

std::int64_t modifiedMillis(const timespec& time) {
    const auto millis = static_cast<__int128>(time.tv_sec) * 1000 + time.tv_nsec / 1'000'000;
    if (millis > INT64_MAX) return INT64_MAX;
    if (millis < INT64_MIN) return INT64_MIN;
    return static_cast<std::int64_t>(millis);
}

class Scanner {
public:
    Scanner(JNIEnv* env, jobject receiver) : env_(env), receiver_(receiver) {
        const auto type = env_->GetObjectClass(receiver_);
        if (!type) return;
        batch_ = env_->GetMethodID(type, "onBatch", "([B)V");
        if (!batch_) return;
        problem_ = env_->GetMethodID(type, "onProblem", "(Ljava/lang/String;I)V");
        if (!problem_) return;
        isCancelled_ = env_->GetMethodID(type, "isCancelled", "()Z");
        if (!isCancelled_) return;
        startChanges_ = env_->GetMethodID(type, "onChanges", "()V");
        if (!startChanges_) return;
        path_ = env_->GetMethodID(type, "onPath", "([BI)V");
        if (!path_) return;
        checkpoint_ = env_->GetMethodID(type, "onCheckpoint", "(ZZIIIJ)V");
        if (!checkpoint_) return;
        identity_ = env_->GetMethodID(type, "onIdentity", "(JJJ)V");
        if (!identity_) return;
        repair_ = env_->GetMethodID(type, "onRepair", "([BJJJ)V");
        if (!repair_) return;
        gap_ = env_->GetMethodID(type, "onGap", "(Ljava/lang/String;I)V");
        buffer_.reserve(batchSize * 96);
    }

    Outcome scan(const std::string& base, const std::string& relative, const std::string& indexDirectory,
                 std::uint64_t expectedMount, std::uint64_t expectedDevice, std::uint64_t expectedInode) {
        if (!gap_ || env_->ExceptionCheck()) return failed;
        if (stopping()) return cancelled;

        // Resolve the application's database directory in this process's mount view.
        // /data/data and /data/user/0 can name the same directory through different mounts.
        if (stat(indexDirectory.c_str(), &indexDirectory_) != 0) {
            issue("identify index directory", errno);
            return failed;
        }
        root_ = openRoot(base, relative);
        if (root_.get() < 0 || fstat(root_.get(), &rootInfo_) != 0) {
            issue("open root", errno);
            return failed;
        }
        mount_ = fdMountId(root_.get());
        if (mount_ == 0) {
            issue("root mount identity", ENOTSUP);
            return failed;
        }
        if (expectedMount != 0 && (mount_ != expectedMount || rootInfo_.st_dev != expectedDevice ||
                                  rootInfo_.st_ino != expectedInode)) {
            watch_.gap("inotify scope identity changed", ESTALE);
            return watchFailed();
        }
        env_->CallVoidMethod(receiver_, identity_, static_cast<jlong>(mount_),
            static_cast<jlong>(rootInfo_.st_dev), static_cast<jlong>(rootInfo_.st_ino));
        if (env_->ExceptionCheck()) return failed;
        struct statfs filesystem {};
        fuse_ = fstatfs(root_.get(), &filesystem) == 0 &&
            static_cast<std::uint32_t>(filesystem.f_type) == fuseMagic;
        const auto result = walk(Fd(openat(root_.get(), ".", directoryFlags)), rootInfo_, "");
        if (result != complete) return result;
        if (watch_.fd() < 0) {
            if (!checkpoint(true)) return cancelled;
            return watchFailed();
        }

        // The baseline remains private until the events produced during enumeration
        // have been reconciled. Continuous churn can be retried with the old index intact.
        for (int round = 0;; ++round) {
            if (stopping()) return cancelled;
            const bool drained = watch_.drain();
            if (watch_.error() != 0) return watchFailed();
            if (!checkRoot(base, relative)) return watchFailed();
            if (drained && !watch_.hasPending()) break;
            if (round == 16) {
                watch_.gap("inotify baseline did not settle", EBUSY);
                return watchFailed();
            }
            if (watch_.hasPending() &&
                (!reconcile() || watch_.error() != 0 || !checkpoint(false))) return interrupted();
        }
        if (!checkpoint(true)) return interrupted();

        auto verifyAt = std::chrono::steady_clock::now() + std::chrono::seconds(1);
        auto retryAt = std::chrono::steady_clock::now() + std::chrono::seconds(2);
        std::string previousRetry;
        while (!stopping()) {
            pollfd ready{watch_.fd(), POLLIN, 0};
            const int result = poll(&ready, 1, watch_.hasPending() ? 0 : 150);
            if (result < 0 && errno == EINTR) continue;
            if (result < 0 || (ready.revents & (POLLERR | POLLHUP | POLLNVAL))) {
                watch_.gap("poll inotify", result < 0 ? errno : EIO);
                break;
            }
            if (result > 0 || watch_.hasPending()) {
                // Keep both sides of a move and an editor's temporary writes in one commit.
                watch_.drain();
                if (watch_.hasPending() && watch_.error() == 0) {
                    poll(nullptr, 0, 25);
                    watch_.drain();
                }
                if (watch_.error() != 0 || !checkRoot(base, relative)) break;
                if (watch_.hasPending()) {
                    if (!reconcile() || watch_.error() != 0 || !checkRoot(base, relative) ||
                        !checkpoint(false)) return interrupted();
                }
            }
            if (std::chrono::steady_clock::now() >= verifyAt) {
                if (!checkRoot(base, relative)) break;
                if (fuse_ && !checkpoint(false)) return interrupted();
                verifyAt = std::chrono::steady_clock::now() + std::chrono::seconds(1);
            }
            if (std::chrono::steady_clock::now() >= retryAt) {
                if (!retryWatch(previousRetry, base, relative)) return interrupted();
                retryAt = std::chrono::steady_clock::now() + std::chrono::seconds(2);
            }
        }
        return watch_.error() != 0 ? watchFailed() : cancelled;
    }

private:
    struct Frame {
        Directory directory;
        std::uint64_t id;
        struct stat info;
        std::string path;
        bool watched;
        bool containsIndexFiles;
    };

    Outcome walk(Fd start, const struct stat& info, std::string path) {
        entries_ = 0;
        directories_ = 0;
        depthOffset_ = path.empty() ? 0 : 1 + std::count(path.begin(), path.end(), '/');
        if (start.get() < 0 || !pushDirectory(std::move(start), 1, info, std::move(path))) {
            issue("fdopendir scan directory", errno);
            return failed;
        }
        append(0, "", info);
        while (!stack_.empty()) {
            if (stopping()) return cancelled;
            if (watch_.fd() >= 0 && watch_.error() != 0) return watchFailed();
            auto& frame = stack_.back();
            const int parent = dirfd(frame.directory.get());
            errno = 0;
            const auto item = readdir(frame.directory.get());
            if (!item) {
                if (errno != 0) {
                    issue("readdir", errno);
                } else if (!frame.watched) {
                    struct stat after {};
                    if (fstat(parent, &after) != 0) {
                        issue("fstat directory", errno);
                    } else if (!sameTime(frame.info.st_mtim, after.st_mtim) ||
                               !sameTime(frame.info.st_ctim, after.st_ctim)) {
                        issue("directory changed during scan", ESTALE);
                    }
                }
                stack_.pop_back();
                continue;
            }

            const std::string_view name(item->d_name);
            if (name == "." || name == "..") continue;
            if (entries_ >= maxEntries) {
                issue("entry limit", 0);
                break;
            }
            scanChild(parent, frame, item->d_name);
            if (pending_ >= batchSize) {
                if (watch_.fd() >= 0) watch_.drain();
                if (!flush()) return failed;
            }
        }
        if (stopping()) return cancelled;
        return flush() ? complete : failed;
    }

    bool stopping() {
        return env_->ExceptionCheck() || env_->CallBooleanMethod(receiver_, isCancelled_);
    }

    void issue(const char* operation, int error) {
        report(problem_, operation, error);
    }

    void report(jmethodID callback, const char* operation, int error) {
        if (env_->ExceptionCheck()) return;
        const auto message = env_->NewStringUTF(operation);
        if (!message) return;
        env_->CallVoidMethod(receiver_, callback, message, static_cast<jint>(error));
        env_->DeleteLocalRef(message);
    }

    Outcome watchFailed() {
        report(gap_, watch_.operation(), watch_.error());
        return failed;
    }

    Outcome interrupted() {
        if (watch_.error() != 0) return watchFailed();
        return stopping() ? cancelled : failed;
    }

    bool checkpoint(bool baseline) {
        if (stopping()) return false;
        env_->CallVoidMethod(receiver_, checkpoint_, static_cast<jboolean>(baseline), static_cast<jboolean>(fuse_),
            static_cast<jint>(watch_.registered()), static_cast<jint>(watch_.failures()),
            static_cast<jint>(watch_.registrationError()), static_cast<jlong>(watch_.sequence()));
        return !env_->ExceptionCheck();
    }

    bool checkRoot(const std::string& base, const std::string& relative) {
        Fd root = openRoot(base, relative);
        struct stat info {};
        if (root.get() >= 0 && fstat(root.get(), &info) == 0 &&
            sameFile(info, rootInfo_) && fdMountId(root.get()) == mount_) return true;
        watch_.gap("inotify scope identity changed", ESTALE);
        return false;
    }

    bool pushDirectory(Fd directory, std::uint64_t id, const struct stat& info, std::string path) {
        Directory stream(fdopendir(directory.get()), closedir);
        if (!stream) return false;
        const bool containsIndexFiles = sameFile(indexDirectory_, info);
        const bool watched = watch_.fd() >= 0 && watch_.add(path, directory.get(), containsIndexFiles);
        directory.release();
        stack_.push_back({std::move(stream), id, info, std::move(path), watched, containsIndexFiles});
        ++directories_;
        return true;
    }

    static std::string join(const std::string& parent, const char* name) {
        return parent.empty() ? std::string(name) : parent + "/" + name;
    }

    static bool disappeared(int error) {
        return error == ENOENT || error == ENOTDIR || error == ELOOP || error == ESTALE;
    }

    void scanChild(int parent, const Frame& frame, const char* name) {
        if (frame.containsIndexFiles && rtpath::isIndexFile(name)) return;
        Metadata metadata;
        const auto retry = [&](const char* operation, int error) {
            if (frame.watched && disappeared(error)) watch_.dirty(join(frame.path, name));
            else issue(operation, error);
        };
        if (!metadataAt(parent, name, metadata)) {
            retry("read entry metadata", errno);
            return;
        }
        if (metadata.mount != mount_) {
            issue("mount boundary", 0);
            return;
        }
        append(frame.id, name, metadata.info);
        if (!S_ISDIR(metadata.info.st_mode)) return;
        if (depthOffset_ + stack_.size() >= maxDepth) {
            issue("directory depth limit", 0);
            return;
        }

        Fd child(openat(parent, name, directoryFlags));
        struct stat opened {};
        if (child.get() < 0 || fstat(child.get(), &opened) != 0) {
            retry("open child directory", errno);
            return;
        }
        if (!sameFile(opened, metadata.info) || fdMountId(child.get()) != mount_) {
            retry("directory replaced or remounted", ESTALE);
            return;
        }
        if (!pushDirectory(std::move(child), entries_, opened, join(frame.path, name))) {
            issue("fdopendir child", errno);
        }
    }

    // Resolve every component from the pinned root. A directory event can
    // outlive its pathname, so it cannot authorize following a link or mount.
    Fd openParent(std::string_view path, bool repairing = false) {
        Fd parent(openat(root_.get(), ".", directoryFlags));
        if (parent.get() < 0) {
            watch_.gap("reopen inotify scope", errno);
            return parent;
        }
        for (std::size_t start = 0; start < path.size();) {
            const auto slash = path.find('/', start);
            const std::string name(path.substr(start, slash == path.npos ? slash : slash - start));
            Fd child(openat(parent.get(), name.c_str(), directoryFlags));
            if (child.get() < 0) {
                if (disappeared(errno)) watch_.dirty(std::string(path.substr(0, slash)));
                else if (!repairing || errno != EACCES) watch_.gap("open inotify parent", errno);
                return Fd();
            }
            if (fdMountId(child.get()) != mount_) {
                watch_.gap("inotify mount boundary changed", ESTALE);
                return Fd();
            }
            parent = std::move(child);
            if (slash == path.npos) break;
            start = slash + 1;
        }
        return parent;
    }

    bool emitPath(const std::string& path, Change change) {
        const auto value = env_->NewByteArray(static_cast<jsize>(path.size()));
        if (!value) return false;
        if (!path.empty()) {
            env_->SetByteArrayRegion(value, 0, static_cast<jsize>(path.size()),
                reinterpret_cast<const jbyte*>(path.data()));
        }
        if (!env_->ExceptionCheck()) env_->CallVoidMethod(receiver_, path_, value, static_cast<jint>(change));
        env_->DeleteLocalRef(value);
        return !env_->ExceptionCheck();
    }

    bool retryWatch(std::string& previous, const std::string& base, const std::string& relative) {
        const auto candidate = watch_.nextFailed(previous);
        if (!candidate || stopping()) return true;
        const auto& path = *candidate;
        previous = path;
        if (path.empty()) {
            if (!checkRoot(base, relative)) return false;
            if (!watch_.add(path, root_.get(), sameFile(indexDirectory_, rootInfo_))) return true;
            watch_.gap("inotify scope watch restored", ENODATA);
            return false;
        }
        const auto slash = path.rfind('/');
        const auto parentPath = slash == path.npos ? std::string_view{} : std::string_view(path).substr(0, slash);
        auto parent = openParent(parentPath, true);
        if (parent.get() < 0) return watch_.error() == 0;
        const auto* name = path.c_str() + (slash == path.npos ? 0 : slash + 1);

        Fd directory(openat(parent.get(), name, directoryFlags));
        if (directory.get() < 0) {
            if (disappeared(errno)) watch_.dirty(path);
            return watch_.error() == 0;
        }
        struct stat info {};
        if (fstat(directory.get(), &info) != 0) return true;
        if (fdMountId(directory.get()) != mount_) {
            watch_.gap("inotify entry remounted", ESTALE);
            return false;
        }
        if (!watch_.add(path, directory.get(), sameFile(indexDirectory_, info))) return true;

        const auto began = std::chrono::steady_clock::now();
        watch_.forget(path, true);
        env_->CallVoidMethod(receiver_, startChanges_);
        if (!emitPath(path, subtree) || walk(std::move(directory), info, path) != complete ||
            watch_.error() != 0 || !checkRoot(base, relative)) return false;
        const auto value = env_->NewByteArray(static_cast<jsize>(path.size()));
        if (!value) return false;
        env_->SetByteArrayRegion(value, 0, static_cast<jsize>(path.size()), reinterpret_cast<const jbyte*>(path.data()));
        const auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - began).count();
        if (!env_->ExceptionCheck()) env_->CallVoidMethod(receiver_, repair_, value,
            static_cast<jlong>(directories_), static_cast<jlong>(entries_), static_cast<jlong>(millis));
        env_->DeleteLocalRef(value);
        return checkpoint(false);
    }

    bool refresh(const std::string& path, bool metadata) {
        const auto slash = path.rfind('/');
        const auto base = slash == path.npos ? std::string_view{} : std::string_view(path).substr(0, slash);
        auto parent = openParent(base);
        if (parent.get() < 0) return watch_.error() == 0;
        const auto* name = path.empty() ? "." : path.c_str() + (slash == path.npos ? 0 : slash + 1);
        if (rtpath::isIndexFile(name)) {
            struct stat info {};
            if (fstat(parent.get(), &info) != 0) {
                watch_.gap("read inotify parent metadata", errno);
                return false;
            }
            if (sameFile(indexDirectory_, info)) return true;
        }
        Metadata current;
        if (!metadataAt(parent.get(), name, current)) {
            const int error = errno;
            if (!disappeared(error)) {
                watch_.gap("read inotify entry metadata", error);
                return false;
            }
            if (metadata) return true;
            watch_.forget(path);
            return emitPath(path, removed);
        }
        if (current.mount != mount_) {
            watch_.gap("inotify entry remounted", ESTALE);
            return false;
        }

        if (metadata || !S_ISDIR(current.info.st_mode)) {
            if (!metadata) watch_.forget(path);
            if (!emitPath(path, metadataOnly)) return false;
            entries_ = 0;
            append(0, "", current.info);
            return flush();
        }

        Fd directory(openat(parent.get(), name, directoryFlags));
        struct stat opened {};
        if (directory.get() < 0 || fstat(directory.get(), &opened) != 0) {
            const int error = errno;
            if (!disappeared(error)) {
                watch_.gap("open inotify child", error);
                return false;
            }
            watch_.dirty(path);
            return true;
        }
        if (!sameFile(opened, current.info) || fdMountId(directory.get()) != mount_) {
            watch_.dirty(path);
            return true;
        }
        watch_.forget(path);
        return emitPath(path, subtree) && walk(std::move(directory), opened, path) == complete;
    }

    bool reconcile() {
        const auto paths = watch_.takePending();
        std::set<std::string> parents;
        env_->CallVoidMethod(receiver_, startChanges_);
        for (const auto& path : paths) {
            if (stopping()) return false;
            bool covered = false;
            for (auto slash = path.find('/'); slash != path.npos; slash = path.find('/', slash + 1)) {
                if (paths.contains(path.substr(0, slash))) {
                    covered = true;
                    break;
                }
            }
            if (covered) continue;
            if (!refresh(path, false)) return false;
            const auto slash = path.rfind('/');
            parents.insert(slash == path.npos ? "" : path.substr(0, slash));
        }
        for (const auto& parent : parents) {
            if (stopping() || !refresh(parent, true)) return false;
        }
        return true;
    }

    // Each little-endian record contains IDs, kind, size, mtime and the original name bytes.
    void append(std::uint64_t parentId, std::string_view name, const struct stat& info) {
        const auto type = kind(info.st_mode);
        writeNumber(++entries_);
        writeNumber(parentId);
        writeNumber(type);
        writeNumber<std::int64_t>(type == 0 || type == 2 ? info.st_size : -1);
        writeNumber(modifiedMillis(info.st_mtim));
        writeNumber(static_cast<std::uint16_t>(name.size()));
        buffer_.insert(buffer_.end(), name.begin(), name.end());
        ++pending_;
    }

    template <typename T>
    void writeNumber(T value) {
        const auto bits = static_cast<std::make_unsigned_t<T>>(value);
        for (std::size_t i = 0; i < sizeof(T); ++i) {
            buffer_.push_back(static_cast<jbyte>(bits >> (i * 8)));
        }
    }

    bool flush() {
        if (env_->ExceptionCheck()) return false;
        if (buffer_.empty()) return true;

        const auto length = static_cast<jsize>(buffer_.size());
        const auto batch = env_->NewByteArray(length);
        if (!batch) return false;
        env_->SetByteArrayRegion(batch, 0, length, buffer_.data());
        if (!env_->ExceptionCheck()) env_->CallVoidMethod(receiver_, batch_, batch);
        env_->DeleteLocalRef(batch);
        buffer_.clear();
        pending_ = 0;
        return !env_->ExceptionCheck();
    }

    JNIEnv* env_;
    jobject receiver_;
    jmethodID batch_ = nullptr;
    jmethodID problem_ = nullptr;
    jmethodID isCancelled_ = nullptr;
    jmethodID startChanges_ = nullptr;
    jmethodID path_ = nullptr;
    jmethodID checkpoint_ = nullptr;
    jmethodID identity_ = nullptr;
    jmethodID repair_ = nullptr;
    jmethodID gap_ = nullptr;
    std::vector<jbyte> buffer_;
    std::vector<Frame> stack_;
    std::size_t pending_ = 0;
    std::size_t depthOffset_ = 0;
    std::uint64_t entries_ = 0;
    std::uint64_t directories_ = 0;
    std::uint64_t mount_ = 0;
    bool fuse_ = false;
    Fd root_;
    struct stat rootInfo_ {};
    struct stat indexDirectory_ {};
    rtpath::InotifyWatch watch_;
};

}  // namespace

extern "C" JNIEXPORT jint JNICALL
Java_io_github_eltancex_rtpath_scan_NativeScanner_walk(
    JNIEnv* env, jobject, jbyteArray basePath, jbyteArray relativePath, jbyteArray indexDirectoryPath,
    jlong expectedMount, jlong expectedDevice, jlong expectedInode, jobject receiver
) {
    try {
        const auto base = bytes(env, basePath);
        if (env->ExceptionCheck()) return failed;
        const auto relative = bytes(env, relativePath);
        if (env->ExceptionCheck()) return failed;
        const auto indexDirectory = bytes(env, indexDirectoryPath);
        if (env->ExceptionCheck()) return failed;
        return Scanner(env, receiver).scan(base, relative, indexDirectory, expectedMount, expectedDevice, expectedInode);
    } catch (const std::bad_alloc&) {
        const auto exception = env->FindClass("java/lang/OutOfMemoryError");
        if (exception) env->ThrowNew(exception, "Could not allocate native scanner memory");
        return failed;
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_io_github_eltancex_rtpath_scan_NativeScanner_inspectDirectory(
    JNIEnv* env, jobject, jbyteArray absolutePath, jboolean mark, jboolean exercise
) {
    try {
        const auto absolute = bytes(env, absolutePath);
        if (env->ExceptionCheck()) return nullptr;
        const auto result = inspectDirectory(absolute, mark, exercise);
        return env->NewStringUTF(result.c_str());
    } catch (const std::bad_alloc&) {
        const auto exception = env->FindClass("java/lang/OutOfMemoryError");
        if (exception) env->ThrowNew(exception, "Could not allocate scanner diagnostics");
        return nullptr;
    }
}
