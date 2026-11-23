#pragma once

#include <initializer_list>
#include <string_view>

namespace rtpath {

inline bool isIndexFile(std::string_view name) {
    for (const std::string_view database : {"ordinary-index.sqlite", "root-index.sqlite"}) {
        if (!name.starts_with(database)) continue;
        const auto suffix = name.substr(database.size());
        return suffix.empty() || suffix == "-wal" || suffix == "-shm" || suffix == "-journal";
    }
    return false;
}

}  // namespace rtpath
