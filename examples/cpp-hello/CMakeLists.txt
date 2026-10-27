cmake_minimum_required(VERSION 3.16)
project(cpp-hello VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(greeter INTERFACE)
target_include_directories(greeter INTERFACE ${CMAKE_CURRENT_SOURCE_DIR}/include)

add_executable(cpp-hello src/main.cpp)
target_link_libraries(cpp-hello PRIVATE greeter)
target_compile_definitions(cpp-hello PRIVATE HELLO_VERSION="${PROJECT_VERSION}")

enable_testing()
add_executable(greeter_test tests/greeter_test.cpp)
target_link_libraries(greeter_test PRIVATE greeter)
add_test(NAME greeter_test COMMAND greeter_test)
