#pragma once

#include "fd.h"

#include <cstdint>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <unordered_map>

namespace rtpath {

class InotifyWatch {
public:
    InotifyWatch();

    int fd() const { return fd_.get(); }
    int error() const { return error_; }
    const char* operation() const { return operation_; }
    int registrationError() const { return registrationError_; }
    std::size_t registered() const { return paths_.size(); }
    std::size_t failures() const { return failed_.size(); }
    std::uint64_t sequence() const { return sequence_; }
    bool hasPending() const { return !pending_.empty() || !moves_.empty(); }

    bool add(const std::string& path, int directory);
    void forget(const std::string& path, bool keepDirectory = false);
    std::optional<std::string> nextFailed(const std::string& after) const;
    void dirty(std::string path);
    bool drain();
    void gap(const char* operation, int error);
    std::set<std::string> takePending();

private:
    void remove(int descriptor);
    void event(int descriptor, std::uint32_t mask, std::uint32_t cookie, const char* name);

    Fd fd_;
    std::map<std::string, int> paths_;
    std::unordered_map<int, std::string> descriptors_;
    std::set<std::string> failed_;
    std::set<std::string> pending_;
    std::unordered_map<std::uint32_t, std::string> moves_;
    std::size_t pendingBytes_ = 0;
    std::uint64_t sequence_ = 0;
    int error_ = 0;
    int registrationError_ = 0;
    const char* operation_ = nullptr;
};

}  // namespace rtpath
