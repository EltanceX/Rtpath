cmake_minimum_required(VERSION 3.22.1)
project(rtpath_probe LANGUAGES CXX)

add_library(rtpath_probe SHARED filesystem_probe.cpp scanner.cpp inotify_watch.cpp)
target_compile_features(rtpath_probe PRIVATE cxx_std_20)
target_compile_options(rtpath_probe PRIVATE -Wall -Wextra -Werror)
