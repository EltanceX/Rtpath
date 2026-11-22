#include <jni.h>

#include <array>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <memory>
#include <poll.h>
#include <string>
#include <string_view>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {

constexpr char kSeed[] = "seed.txt";
constexpr std::string_view kMarker = "rtpath\n";
constexpr char kCreated[] = "created.txt";
constexpr char kRenamed[] = "renamed.txt";

#if defined(__aarch64__)
constexpr char kAbi[] = "arm64-v8a";
#elif defined(__x86_64__)
constexpr char kAbi[] = "x86_64";
#else
#error Unexpected RtPath ABI
#endif

class Fd {
public:
    explicit Fd(int fd) : fd_(fd) {}
    ~Fd() {
        if (fd_ >= 0) close(fd_);
    }
    Fd(const Fd&) = delete;
    Fd& operator=(const Fd&) = delete;
    int get() const { return fd_; }

private:
    int fd_;
};

std::string systemError(const char* operation, int error = errno) {
    return std::string(operation) + ": " + std::strerror(error);
}

std::string probeFile(DIR* directory) {
    errno = 0;
    auto* entry = readdir(directory);
    while (entry != nullptr && std::string_view(entry->d_name) != kSeed) {
        entry = readdir(directory);
    }
    if (entry == nullptr) {
        return errno == 0 ? "readdir did not return seed.txt" : systemError("readdir");
    }

    const int directoryFd = dirfd(directory);
    struct stat info {};
    if (fstatat(directoryFd, kSeed, &info, AT_SYMLINK_NOFOLLOW) != 0) {
        return systemError("fstatat");
    }
    if (!S_ISREG(info.st_mode) || info.st_size != static_cast<off_t>(kMarker.size())) {
        return "Unexpected seed file type or size";
    }

    Fd file(openat(directoryFd, kSeed, O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
    if (file.get() < 0) return systemError("openat");
    std::array<char, kMarker.size()> bytes{};
    ssize_t count;
    do {
        count = read(file.get(), bytes.data(), bytes.size());
    } while (count < 0 && errno == EINTR);
    if (count < 0) return systemError("read");
    if (count != static_cast<ssize_t>(bytes.size()) ||
        std::string_view(bytes.data(), bytes.size()) != kMarker) {
        return "Unexpected seed file contents";
    }
    return {};
}

std::string verifyEvents(int fd, int watchedDirectory) {
    pollfd pollTarget{fd, POLLIN, 0};
    const int ready = poll(&pollTarget, 1, 1000);
    if (ready < 0) return systemError("poll inotify");
    if (ready == 0) return "No inotify events arrived";

    alignas(inotify_event) std::array<char, 4096> buffer{};
    const auto count = read(fd, buffer.data(), buffer.size());
    if (count < 0) return systemError("read inotify");

    bool created = false;
    bool closed = false;
    bool deleted = false;
    uint32_t fromCookie = 0;
    uint32_t toCookie = 0;
    const auto end = static_cast<std::size_t>(count);
    for (std::size_t offset = 0; offset < end;) {
        inotify_event event{};
        if (end - offset < sizeof(event)) return "Truncated inotify event";
        std::memcpy(&event, buffer.data() + offset, sizeof(event));
        offset += sizeof(event);
        if (event.len > end - offset) return "Truncated inotify event name";
        if ((event.mask & IN_Q_OVERFLOW) != 0) return "inotify queue overflow";
        const char* name = buffer.data() + offset;
        const std::string_view eventName(name, strnlen(name, event.len));
        offset += event.len;
        if (event.wd != watchedDirectory) continue;

        if (eventName == kCreated) {
            created |= (event.mask & IN_CREATE) != 0;
            closed |= (event.mask & IN_CLOSE_WRITE) != 0;
            if ((event.mask & IN_MOVED_FROM) != 0) fromCookie = event.cookie;
        } else if (eventName == kRenamed) {
            if ((event.mask & IN_MOVED_TO) != 0) toCookie = event.cookie;
            deleted |= (event.mask & IN_DELETE) != 0;
        }
    }

    if (!created || !closed || !deleted || fromCookie == 0 || fromCookie != toCookie) {
        return "Missing create, close-write, matched rename, or delete event";
    }
    return {};
}

std::string probeInotify(const char* path, int directoryFd) {
    Fd notify(inotify_init1(IN_CLOEXEC | IN_NONBLOCK));
    if (notify.get() < 0) return systemError("inotify_init1");

    constexpr uint32_t mask =
        IN_CREATE | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE | IN_ONLYDIR | IN_DONT_FOLLOW;
    const int watch = inotify_add_watch(notify.get(), path, mask);
    if (watch < 0) return systemError("inotify_add_watch");

    {
        Fd file(openat(directoryFd, kCreated, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600));
        if (file.get() < 0) return systemError("create watched file");
        if (write(file.get(), "x", 1) != 1) return systemError("write watched file");
    }
    if (renameat(directoryFd, kCreated, directoryFd, kRenamed) != 0) {
        return systemError("rename watched file");
    }
    if (unlinkat(directoryFd, kRenamed, 0) != 0) return systemError("delete watched file");

    return verifyEvents(notify.get(), watch);
}

}  // namespace

extern "C" JNIEXPORT jobjectArray JNICALL
Java_io_github_eltancex_rtpath_NativeFilesystemProbe_inspect(
    JNIEnv* env, jobject, jbyteArray fixturePath
) {
    const jsize length = env->GetArrayLength(fixturePath);
    std::string path(static_cast<std::size_t>(length), '\0');
    env->GetByteArrayRegion(fixturePath, 0, length, reinterpret_cast<jbyte*>(path.data()));
    if (env->ExceptionCheck()) return nullptr;

    // The Android caller creates a fresh, application-owned fixture for each run.
    std::unique_ptr<DIR, decltype(&closedir)> directory(opendir(path.c_str()), closedir);
    std::string fileError;
    std::string watchError;
    if (directory) {
        fileError = probeFile(directory.get());
        watchError = probeInotify(path.c_str(), dirfd(directory.get()));
    } else {
        fileError = watchError = systemError("open fixture directory");
    }

    const jclass stringClass = env->FindClass("java/lang/String");
    if (stringClass == nullptr) return nullptr;
    const auto report = env->NewObjectArray(3, stringClass, nullptr);
    if (report == nullptr) return nullptr;
    const std::array values{kAbi, fileError.c_str(), watchError.c_str()};
    for (std::size_t index = 0; index < values.size(); index++) {
        const auto value = env->NewStringUTF(values[index]);
        if (value == nullptr) return nullptr;
        env->SetObjectArrayElement(report, index, value);
        env->DeleteLocalRef(value);
        if (env->ExceptionCheck()) return nullptr;
    }
    return report;
}
