#pragma once

#include "change_watch.h"
#include "fd.h"

#include <sys/stat.h>

#include <array>
#include <memory>

namespace rtpath {

class FanotifyWatch final : public ChangeWatch {
public:
    // Both descriptors are borrowed. The fixture must be an app-owned directory on the target mount.
    static std::unique_ptr<FanotifyWatch> start(int root, int fixture, const struct stat& indexDirectory,
                                                std::string& reason);
    int fd() const override { return group_.get(); }
    bool drain() override;
    std::size_t registered() const override { return 1; }

private:
    FanotifyWatch(Fd group, int root, std::string path, const struct stat& indexDirectory,
                   std::array<unsigned char, 8> fsid)
        : group_(std::move(group)), root_(root), path_(std::move(path)), indexDirectory_(indexDirectory), fsid_(fsid) {}

    const char* pendingOverflow() const override { return "fanotify pending paths overflow"; }
    Fd group_;
    int root_;
    std::string path_;
    struct stat indexDirectory_;
    std::array<unsigned char, 8> fsid_;
};

}  // namespace rtpath
