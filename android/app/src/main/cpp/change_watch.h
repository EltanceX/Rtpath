#pragma once

#include <cstdint>
#include <optional>
#include <set>
#include <string>

namespace rtpath {

class ChangeWatch {
public:
    virtual ~ChangeWatch() = default;
    virtual int fd() const = 0;
    virtual bool drain() = 0;
    virtual std::size_t registered() const = 0;
    virtual bool add(const std::string&, int, bool) { return true; }
    virtual void forget(const std::string&, bool = false) {}
    virtual std::size_t failures() const { return 0; }
    virtual int registrationError() const { return 0; }
    virtual std::optional<std::string> nextFailed(const std::string&) const { return {}; }
    virtual bool hasPending() const { return !pending_.empty(); }
    virtual std::set<std::string> takePending();

    int error() const { return error_; }
    const char* operation() const { return operation_; }
    std::uint64_t sequence() const { return sequence_; }
    void dirty(std::string path);
    void gap(const char* operation, int error);

protected:
    virtual std::size_t extraPending() const { return 0; }
    virtual const char* pendingOverflow() const = 0;
    void checkPendingLimit();
    std::set<std::string> pending_;
    std::size_t pendingBytes_ = 0;
    std::uint64_t sequence_ = 0;
    int error_ = 0;
private:
    const char* operation_ = nullptr;
};

}  // namespace rtpath
