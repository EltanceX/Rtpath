#pragma once

#include <unistd.h>

#include <utility>

namespace rtpath {

class Fd {
public:
    explicit Fd(int value = -1) : value_(value) {}
    ~Fd() {
        if (value_ >= 0) close(value_);
    }

    Fd(const Fd&) = delete;
    Fd& operator=(const Fd&) = delete;

    Fd(Fd&& other) noexcept : value_(other.release()) {}
    Fd& operator=(Fd&& other) noexcept {
        Fd previous(std::exchange(value_, other.release()));
        return *this;
    }

    int get() const { return value_; }
    int release() { return std::exchange(value_, -1); }

private:
    int value_;
};

}  // namespace rtpath
