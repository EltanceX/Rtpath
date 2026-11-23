#pragma once

#include "change_watch.h"
#include "fd.h"

#include <cstdint>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <unordered_map>

namespace rtpath {

class InotifyWatch final : public ChangeWatch {
public:
    InotifyWatch();

    int fd() const override { return fd_.get(); }
    int registrationError() const override { return registrationError_; }
    std::size_t registered() const override { return paths_.size(); }
    std::size_t failures() const override { return failed_.size(); }
    bool hasPending() const override { return ChangeWatch::hasPending() || !moves_.empty(); }

    bool add(const std::string& path, int directory, bool containsIndexFiles) override;
    void forget(const std::string& path, bool keepDirectory) override;
    std::optional<std::string> nextFailed(const std::string& after) const override;
    bool drain() override;
    std::set<std::string> takePending() override;

private:
    std::size_t extraPending() const override { return moves_.size(); }
    const char* pendingOverflow() const override { return "inotify pending paths overflow"; }

    struct WatchedDirectory {
        std::string path;
        bool containsIndexFiles;
    };

    void remove(int descriptor);
    void event(int descriptor, std::uint32_t mask, std::uint32_t cookie, const char* name);

    Fd fd_;
    std::map<std::string, int> paths_;
    std::unordered_map<int, WatchedDirectory> descriptors_;
    std::set<std::string> failed_;
    std::unordered_map<std::uint32_t, std::string> moves_;
    int registrationError_ = 0;
};

}  // namespace rtpath
