#include "fanotify_watch.h"
#include "inotify_watch.h"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <vector>

namespace {

using rtpath::ChangeWatch;
using rtpath::Fd;
namespace fs = std::filesystem;

void require(bool success, const char* message) {
    if (!success) throw std::runtime_error(std::string(message) + ": " + strerror(errno));
}

Fd directory(const std::string& path) {
    Fd fd(open(path.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    require(fd.get() >= 0, "open directory");
    return fd;
}

void create(const std::string& path) {
    Fd fd(open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600));
    require(fd.get() >= 0 && write(fd.get(), "a", 1) == 1, "write test file");
}

void ready(ChangeWatch& watch) {
    for (int attempt = 0; !watch.drain() && watch.error() == 0; ++attempt) {
        require(attempt < 32, "event stream failed to drain");
    }
}

void compare(ChangeWatch& watch, const std::set<std::string>& expected) {
    ready(watch);
    if (watch.error() != 0) throw std::runtime_error(watch.operation());
    const auto received = watch.takePending();
    if (received != expected) {
        for (const auto& path : received) std::fprintf(stderr, "received [%s]\n", path.c_str());
        throw std::runtime_error("unexpected set of paths");
    }
}

void test(const std::string& base) {
    const auto scope = base + "/scope";
    const auto cachePath = base + "/cache";
    const auto other = base + "/scope-other";
    fs::create_directories(scope + "/left");
    fs::create_directory(scope + "/right");
    fs::create_directory(cachePath);
    fs::create_directory(other);
    auto root = directory(scope);
    auto cache = directory(cachePath);
    auto left = directory(scope + "/left");
    auto right = directory(scope + "/right");
    struct stat indexDir {};
    require(fstat(left.get(), &indexDir) == 0, "stat fake index directory");
    std::string reason;
    auto fan = rtpath::FanotifyWatch::start(root.get(), cache.get(), indexDir, reason);
    if (!fan) throw std::runtime_error("fanotify probe: " + reason);
    rtpath::InotifyWatch ino;
    require(ino.add("", root.get(), false), "watch scope");
    require(ino.add("left", left.get(), true), "watch left");
    require(ino.add("right", right.get(), false), "watch right");

    const auto l = scope + "/left/";
    const auto r = scope + "/right/";
    create(l + "file");
    create(l + "root-index.sqlite-wal");
    create(r + "root-index.sqlite-wal");
    create(other + "/out");
    require(rename((l + "file").c_str(), (r + "renamed").c_str()) == 0, "move inside scope");
    fs::create_directory(l + "tree");
    create(l + "tree/child");
    require(rename((l + "tree").c_str(), (r + "tree").c_str()) == 0, "move directory inside scope");
    require(rename((other + "/out").c_str(), (l + "in").c_str()) == 0, "move into scope");
    require(rename((r + "renamed").c_str(), (other + "/moved").c_str()) == 0, "move out of scope");
    create(r + "gone");
    require(unlink((r + "gone").c_str()) == 0, "delete file");
    const std::set<std::string> expected {
        "left/file", "left/in", "left/tree", "right/gone", "right/renamed", "right/root-index.sqlite-wal", "right/tree",
    };
    auto fanExpected = expected;
    // Filesystem marks already see activity in new subtrees before enumeration.
    fanExpected.insert("right/tree/child");
    compare(*fan, fanExpected);
    compare(ino, expected);
    create(other + "/outside-only");
    compare(*fan, {});
    compare(ino, {});

    auto timing = [&](ChangeWatch& watch, ChangeWatch& otherWatch) {
        std::vector<double> samples;
        for (int i = 0; i < 100; ++i) {
            const auto started = std::chrono::steady_clock::now();
            create(r + "write");
            compare(watch, {"right/write"});
            samples.push_back(std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - started).count());
            compare(otherWatch, {"right/write"});
        }
        std::sort(samples.begin(), samples.end());
        return samples[94];
    };
    const auto fanP95 = timing(*fan, ino);
    const auto inoP95 = timing(ino, *fan);
    std::printf("path reconciliation passed; marks/watches %zu/%zu; producer through drain P95 %.2f/%.2f us (fanotify/inotify)\n",
                fan->registered(), ino.registered(), fanP95, inoP95);

    // Outside events still fill the kernel's filesystem queue, but they never enter the path queue.
    for (int i = 0; i < 20000; ++i) create(other + "/overflow-" + std::to_string(i));
    ready(*fan);
    require(fan->error() == ENOBUFS && std::string_view(fan->operation()) == "fanotify kernel queue overflow",
            "detect kernel overflow");
    compare(ino, {});
    std::puts("real fanotify queue overflow passed");
}

}  // namespace

int main(int argc, char** argv) {
    const bool init = getpid() == 1;
    int result = 0;
    std::string base;
    try {
        if (init) {
            require(mkdir("/proc", 0755) == 0 || errno == EEXIST, "create /proc");
            require(mount("proc", "/proc", "proc", 0, nullptr) == 0, "mount /proc");
            require(mkdir("/tmp", 0755) == 0 || errno == EEXIST, "create /tmp");
            require(mount("tmpfs", "/tmp", "tmpfs", 0, nullptr) == 0, "mount tmpfs");
        }
        base = std::string(argc > 1 ? argv[1] : "/tmp") + "/rtpath-fanotify-XXXXXX";
        if (!mkdtemp(base.data())) {
            base.clear();
            require(false, "create test root");
        }
        test(base);
        std::puts("FANOTIFY_NATIVE_PASS");
    } catch (const std::exception& failure) {
        std::fprintf(stderr, "FANOTIFY_NATIVE_FAIL: %s\n", failure.what());
        result = 1;
    }
    if (!base.empty()) fs::remove_all(base);
    std::fflush(nullptr);
    if (init) reboot(RB_POWER_OFF);
    return result;
}
